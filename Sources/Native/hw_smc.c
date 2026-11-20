// Unified in-process AppleSMC client:
// 1. Fast cached read-only sensor telemetry (CPU/GPU die temps, fan RPM, total system power).
// 2. Safe key read/write + crash guard for optional thermal fan boost.
#include "hw_smc.h"

#include <IOKit/IOKitLib.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_keydata_t;
_Static_assert(sizeof(smc_keydata_t) == 80, "AppleSMC expects an 80-byte SMCKeyData_t");

enum { kSMCUserClient = 2, kCmdRead = 5, kCmdWrite = 6, kCmdGetKeyByIndex = 8, kCmdKeyInfo = 9 };

#define FOURCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))
#define T_FLT  FOURCC('f', 'l', 't', ' ')
#define T_FPE2 FOURCC('f', 'p', 'e', '2')
#define T_UI8  FOURCC('u', 'i', '8', ' ')
#define T_UI16 FOURCC('u', 'i', '1', '6')
#define T_UI32 FOURCC('u', 'i', '3', '2')
#define T_FLAG FOURCC('f', 'l', 'a', 'g')
#define T_SP78 FOURCC('s', 'p', '7', '8')

static io_connect_t g_conn = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    uint32_t code;
    uint32_t size;
    uint32_t type;
} smc_cached_key_t;

#define MAX_TEMP_KEYS 48
#define MAX_FANS 8

static int g_sensors_probed = 0;
static smc_cached_key_t g_cpu_temp_keys[MAX_TEMP_KEYS];
static int g_cpu_temp_count = 0;
static smc_cached_key_t g_gpu_temp_keys[MAX_TEMP_KEYS];
static int g_gpu_temp_count = 0;
static smc_cached_key_t g_fan_cur_keys[MAX_FANS];
static int g_fan_max_rpm_cache[MAX_FANS];
static int g_fan_count = 0;
static smc_cached_key_t g_power_key = {0, 0, 0};

// Keep at most `max_keep` evenly-spaced sensors across all discovered diodes
// so each tick takes ~2 ms instead of ~8 ms while matching full-die average within ~0.1 C.
static int compact_keys(smc_cached_key_t *keys, int count, int max_keep) {
    if (count <= max_keep || max_keep <= 0) return count;
    smc_cached_key_t tmp[MAX_TEMP_KEYS];
    for (int i = 0; i < max_keep; i++) {
        int idx = (i * (count - 1)) / (max_keep - 1);
        tmp[i] = keys[idx];
    }
    memcpy(keys, tmp, (size_t)max_keep * sizeof(smc_cached_key_t));
    return max_keep;
}

static int key_code(const char *key, uint32_t *out) {
    if (!key || strlen(key) != 4) return HW_SMC_ERR_ARG;
    *out = FOURCC(key[0], key[1], key[2], key[3]);
    return 0;
}

static int call_unlocked(smc_keydata_t *in, smc_keydata_t *out) {
    if (!g_conn) return HW_SMC_ERR_CLOSED;
    size_t outSize = sizeof(*out);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, kSMCUserClient, in, sizeof(*in), out, &outSize);
    if (kr != KERN_SUCCESS) return (int)kr;
    if (out->result != 0) return HW_SMC_ERR_SMC | out->result;
    return 0;
}

static int open_unlocked(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return HW_SMC_ERR_CLOSED;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) {
        g_conn = 0;
        return (int)kr;
    }
    return 0;
}

static int key_info_unlocked(uint32_t code, uint32_t *size, uint32_t *type) {
    smc_keydata_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = code;
    in.data8 = kCmdKeyInfo;
    int r = call_unlocked(&in, &out);
    if (r) return r;
    *size = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    return 0;
}

static int decode_bytes(const uint8_t *b, uint32_t size, uint32_t type, double *value) {
    if (type == T_FLT && size == 4) {
        float f; memcpy(&f, b, 4);
        *value = (double)f;
    } else if (type == T_FPE2 && size == 2) {
        *value = (double)(((uint32_t)b[0] << 8) | b[1]) / 4.0;
    } else if (type == T_SP78 && size == 2) {
        *value = (double)(int16_t)(((uint16_t)b[0] << 8) | b[1]) / 256.0;
    } else if ((type == T_UI8 || type == T_FLAG) && size == 1) {
        *value = (double)b[0];
    } else if (type == T_UI16 && size == 2) {
        *value = (double)(((uint32_t)b[0] << 8) | b[1]);
    } else if (type == T_UI32 && size == 4) {
        *value = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]);
    } else {
        return HW_SMC_ERR_TYPE;
    }
    return 0;
}

static int read_cached_unlocked(uint32_t code, uint32_t size, uint32_t type, double *value) {
    if (size == 0 || size > 32) return HW_SMC_ERR_TYPE;
    smc_keydata_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = code;
    in.keyInfo.dataSize = size;
    in.data8 = kCmdRead;
    int r = call_unlocked(&in, &out);
    if (r) return r;
    return decode_bytes(out.bytes, size, type, value);
}

static int read_number_unlocked(const char *key, double *value) {
    uint32_t code, size, type;
    int r = key_code(key, &code);
    if (r) return r;
    if ((r = key_info_unlocked(code, &size, &type))) return r;
    return read_cached_unlocked(code, size, type, value);
}

static int write_number_unlocked(const char *key, double value) {
    uint32_t code, size, type;
    int r = key_code(key, &code);
    if (r) return r;
    if (!(value >= 0) || value > 65535) return HW_SMC_ERR_ARG;
    if (key[0] == 'F' && key[2] == 'T' && key[3] == 'g' && value < 500) return HW_SMC_ERR_ARG;
    if ((r = key_info_unlocked(code, &size, &type))) return r;
    smc_keydata_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = code;
    in.keyInfo.dataSize = size;
    in.data8 = kCmdWrite;
    uint8_t *b = in.bytes;
    if (type == T_FLT && size == 4) {
        float f = (float)value; memcpy(b, &f, 4);
    } else if (type == T_FPE2 && size == 2) {
        uint32_t v = (uint32_t)(value * 4.0 + 0.5);
        if (v > 0xFFFF) v = 0xFFFF;
        b[0] = (uint8_t)(v >> 8); b[1] = (uint8_t)v;
    } else if ((type == T_UI8 || type == T_FLAG) && size == 1) {
        if (value > 255) return HW_SMC_ERR_ARG;
        b[0] = (uint8_t)value;
    } else if (type == T_UI16 && size == 2) {
        uint32_t v = (uint32_t)value;
        b[0] = (uint8_t)(v >> 8); b[1] = (uint8_t)v;
    } else {
        return HW_SMC_ERR_TYPE;
    }
    return call_unlocked(&in, &out);
}

static void probe_sensors_unlocked(void) {
    if (g_sensors_probed) return;
    g_sensors_probed = 1;
    g_cpu_temp_count = 0;
    g_gpu_temp_count = 0;
    g_fan_count = 0;
    g_power_key.code = 0;

    // 1. Fans
    double fnum = 0;
    if (read_number_unlocked("FNum", &fnum) == 0 && fnum >= 1 && fnum <= MAX_FANS) {
        int n = (int)fnum;
        for (int i = 0; i < n; i++) {
            char ac[5] = {'F', (char)('0' + i), 'A', 'c', 0};
            char mx[5] = {'F', (char)('0' + i), 'M', 'x', 0};
            uint32_t code, sz, dt;
            if (key_code(ac, &code) == 0 && key_info_unlocked(code, &sz, &dt) == 0) {
                g_fan_cur_keys[g_fan_count] = (smc_cached_key_t){code, sz, dt};
                double mxv = 0;
                g_fan_max_rpm_cache[g_fan_count] = (read_number_unlocked(mx, &mxv) == 0 && mxv > 0) ? (int)llround(mxv) : 0;
                g_fan_count++;
            }
        }
    }

    // 2. Total system power (PSTR primary, PDTR fallback)
    const char *pwr_candidates[] = {"PSTR", "PDTR"};
    for (int i = 0; i < 2; i++) {
        uint32_t code, sz, dt;
        double v = 0;
        if (key_code(pwr_candidates[i], &code) == 0 &&
            key_info_unlocked(code, &sz, &dt) == 0 &&
            read_cached_unlocked(code, sz, dt, &v) == 0 &&
            isfinite(v) && v >= 0.0 && v < 500.0) {
            g_power_key = (smc_cached_key_t){code, sz, dt};
            break;
        }
    }

    // 3. Enumerate #KEY once to discover live Apple Silicon CPU/GPU thermal diodes
    double key_total = 0;
    if (read_number_unlocked("#KEY", &key_total) == 0 && key_total > 0 && key_total < 8192) {
        uint32_t cnt = (uint32_t)key_total;
        for (uint32_t i = 0; i < cnt; i++) {
            smc_keydata_t in, out;
            memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
            in.data8 = kCmdGetKeyByIndex;
            in.data32 = i;
            if (call_unlocked(&in, &out) != 0) continue;
            uint32_t k = out.key;
            char c0 = (char)(k >> 24), c1 = (char)(k >> 16);
            if (c0 != 'T') continue;
            int is_cpu = (c1 == 'p' || c1 == 'e');
            int is_gpu = (c1 == 'g');
            if (!is_cpu && !is_gpu) continue;
            if (is_cpu && g_cpu_temp_count >= MAX_TEMP_KEYS) continue;
            if (is_gpu && g_gpu_temp_count >= MAX_TEMP_KEYS) continue;

            uint32_t sz = 0, dt = 0;
            if (key_info_unlocked(k, &sz, &dt) != 0) continue;
            if (dt != T_FLT && dt != T_SP78) continue;

            double v = 0;
            if (read_cached_unlocked(k, sz, dt, &v) != 0) continue;
            if (!isfinite(v) || v <= 5.0 || v >= 125.0) continue;

            if (is_cpu) {
                g_cpu_temp_keys[g_cpu_temp_count++] = (smc_cached_key_t){k, sz, dt};
            } else {
                g_gpu_temp_keys[g_gpu_temp_count++] = (smc_cached_key_t){k, sz, dt};
            }
        }
    }

    // 4. Fallback static keys (older M1/M2 or Intel Macs if enumeration yielded none)
    if (g_cpu_temp_count == 0) {
        const char *fallback_cpu[] = {"Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                                      "Te05", "Te0L", "Te0P", "Te0S", "TC0P", "TC0D", "TC0E", "TC0F"};
        for (size_t i = 0; i < sizeof(fallback_cpu) / sizeof(fallback_cpu[0]); i++) {
            uint32_t code, sz, dt;
            double v = 0;
            if (key_code(fallback_cpu[i], &code) == 0 &&
                key_info_unlocked(code, &sz, &dt) == 0 &&
                read_cached_unlocked(code, sz, dt, &v) == 0 &&
                isfinite(v) && v > 5.0 && v < 125.0 &&
                g_cpu_temp_count < MAX_TEMP_KEYS) {
                g_cpu_temp_keys[g_cpu_temp_count++] = (smc_cached_key_t){code, sz, dt};
            }
        }
    }
    if (g_gpu_temp_count == 0) {
        const char *fallback_gpu[] = {"Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j", "TG0P", "TG0D"};
        for (size_t i = 0; i < sizeof(fallback_gpu) / sizeof(fallback_gpu[0]); i++) {
            uint32_t code, sz, dt;
            double v = 0;
            if (key_code(fallback_gpu[i], &code) == 0 &&
                key_info_unlocked(code, &sz, &dt) == 0 &&
                read_cached_unlocked(code, sz, dt, &v) == 0 &&
                isfinite(v) && v > 5.0 && v < 125.0 &&
                g_gpu_temp_count < MAX_TEMP_KEYS) {
                g_gpu_temp_keys[g_gpu_temp_count++] = (smc_cached_key_t){code, sz, dt};
            }
        }
    }

    g_cpu_temp_count = compact_keys(g_cpu_temp_keys, g_cpu_temp_count, 8);
    g_gpu_temp_count = compact_keys(g_gpu_temp_keys, g_gpu_temp_count, 6);
}

int hw_smc_read_sensors(hw_smc_sensors_t *out) {
    if (!out) return HW_SMC_ERR_ARG;
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&g_lock);
    int r = open_unlocked();
    if (r != 0) {
        pthread_mutex_unlock(&g_lock);
        return r;
    }
    probe_sensors_unlocked();

    double sum = 0;
    int valid = 0;
    for (int i = 0; i < g_cpu_temp_count; i++) {
        double v = 0;
        if (read_cached_unlocked(g_cpu_temp_keys[i].code, g_cpu_temp_keys[i].size, g_cpu_temp_keys[i].type, &v) == 0 &&
            isfinite(v) && v > 5.0 && v < 130.0) {
            sum += v;
            valid++;
        }
    }
    if (valid > 0) {
        out->has_cpu_temp = 1;
        out->cpu_temp_c = sum / valid;
    }

    sum = 0;
    valid = 0;
    for (int i = 0; i < g_gpu_temp_count; i++) {
        double v = 0;
        if (read_cached_unlocked(g_gpu_temp_keys[i].code, g_gpu_temp_keys[i].size, g_gpu_temp_keys[i].type, &v) == 0 &&
            isfinite(v) && v > 5.0 && v < 130.0) {
            sum += v;
            valid++;
        }
    }
    if (valid > 0) {
        out->has_gpu_temp = 1;
        out->gpu_temp_c = sum / valid;
    }

    out->fan_count = g_fan_count;
    int best_rpm = -1;
    int best_max = 0;
    for (int i = 0; i < g_fan_count; i++) {
        double v = 0;
        if (read_cached_unlocked(g_fan_cur_keys[i].code, g_fan_cur_keys[i].size, g_fan_cur_keys[i].type, &v) == 0 &&
            isfinite(v) && v >= 0 && v < 20000) {
            int rpm = (int)llround(v);
            if (rpm > best_rpm) best_rpm = rpm;
        }
        if (g_fan_max_rpm_cache[i] > best_max) best_max = g_fan_max_rpm_cache[i];
    }
    if (best_rpm >= 0) {
        out->has_fan_rpm = 1;
        out->fan_rpm = best_rpm;
        out->fan_max_rpm = best_max;
    }

    if (g_power_key.code != 0) {
        double p = 0;
        if (read_cached_unlocked(g_power_key.code, g_power_key.size, g_power_key.type, &p) == 0 &&
            isfinite(p) && p >= 0.0 && p < 500.0) {
            out->has_sys_power = 1;
            out->sys_power_w = p;
        }
    }

    pthread_mutex_unlock(&g_lock);
    return 0;
}

int hw_smc_open(void) {
    pthread_mutex_lock(&g_lock);
    int r = open_unlocked();
    pthread_mutex_unlock(&g_lock);
    return r;
}

void hw_smc_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) {
        IOServiceClose(g_conn);
        g_conn = 0;
    }
    g_sensors_probed = 0;
    pthread_mutex_unlock(&g_lock);
}

int hw_smc_key_info(const char *key, uint32_t *size, uint32_t *type) {
    uint32_t code;
    int r = key_code(key, &code);
    if (r) return r;
    pthread_mutex_lock(&g_lock);
    r = key_info_unlocked(code, size, type);
    pthread_mutex_unlock(&g_lock);
    return r;
}

int hw_smc_read_number(const char *key, double *out) {
    pthread_mutex_lock(&g_lock);
    int r = read_number_unlocked(key, out);
    pthread_mutex_unlock(&g_lock);
    return r;
}

int hw_smc_write_number(const char *key, double value) {
    pthread_mutex_lock(&g_lock);
    int r = write_number_unlocked(key, value);
    pthread_mutex_unlock(&g_lock);
    return r;
}

// MARK: - Crash guard (installed only when fan boost is actually writable)

static volatile sig_atomic_t g_armed = 0;
static char g_mode_keys[8][5];
static int g_mode_count = 0;
static int g_clear_ftst = 0;
static int g_legacy_fs = 0;

void hw_smc_guard_configure(const char *mode_keys, int count, int clear_ftst, int legacy_fs) {
    pthread_mutex_lock(&g_lock);
    if (count < 0) count = 0;
    if (count > 8) count = 8;
    size_t len = mode_keys ? strlen(mode_keys) : 0;
    if ((size_t)count * 4 > len) count = (int)(len / 4);
    for (int i = 0; i < count; i++) {
        memcpy(g_mode_keys[i], mode_keys + i * 4, 4);
        g_mode_keys[i][4] = 0;
    }
    g_mode_count = count;
    g_clear_ftst = clear_ftst;
    g_legacy_fs = legacy_fs;
    pthread_mutex_unlock(&g_lock);
}

void hw_smc_guard_arm(int armed) { g_armed = armed ? 1 : 0; }

static void guard_restore_unlocked(void) {
    if (!g_armed) return;
    if (g_legacy_fs) {
        write_number_unlocked("FS! ", 0);
    } else {
        for (int i = 0; i < g_mode_count; i++) write_number_unlocked(g_mode_keys[i], 0);
    }
    if (g_clear_ftst) write_number_unlocked("Ftst", 0);
    g_armed = 0;
}

void hw_smc_guard_restore(void) {
    pthread_mutex_lock(&g_lock);
    guard_restore_unlocked();
    pthread_mutex_unlock(&g_lock);
}

static const int kCrashSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
#define N_CRASH_SIGNALS (int)(sizeof(kCrashSignals) / sizeof(kCrashSignals[0]))
static struct sigaction g_prev[N_CRASH_SIGNALS];

static void crash_handler(int sig) {
    if (g_armed) {
        int locked = pthread_mutex_trylock(&g_lock) == 0;
        guard_restore_unlocked();
        if (locked) pthread_mutex_unlock(&g_lock);
    }
    for (int i = 0; i < N_CRASH_SIGNALS; i++) {
        if (kCrashSignals[i] == sig) { sigaction(sig, &g_prev[i], NULL); break; }
    }
    raise(sig);
}

void hw_smc_install_crash_handlers(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_ONSTACK;
    for (int i = 0; i < N_CRASH_SIGNALS; i++) sigaction(kCrashSignals[i], &sa, &g_prev[i]);
}

// In-process AppleSMC access for thermal fan boost. Protocol after public research
// (agoodkind/macos-smc-fan, smcFanControl): IOConnectCallStructMethod selector 2 with an
// 80-byte SMCKeyData_t; command 9 = key info, 5 = read, 6 = write.
#include "hw_smc.h"

#include <IOKit/IOKitLib.h>
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

enum { kSMCUserClient = 2, kCmdRead = 5, kCmdWrite = 6, kCmdKeyInfo = 9 };

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

static int read_number_unlocked(const char *key, double *value) {
    uint32_t code, size, type;
    int r = key_code(key, &code);
    if (r) return r;
    if ((r = key_info_unlocked(code, &size, &type))) return r;
    if (size == 0 || size > 32) return HW_SMC_ERR_TYPE;
    smc_keydata_t in, out;
    memset(&in, 0, sizeof(in)); memset(&out, 0, sizeof(out));
    in.key = code;
    in.keyInfo.dataSize = size;
    in.data8 = kCmdRead;
    if ((r = call_unlocked(&in, &out))) return r;
    const uint8_t *b = out.bytes;
    if (type == T_FLT && size == 4) {
        float f; memcpy(&f, b, 4);  // little-endian on Apple Silicon (and x86)
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

static int write_number_unlocked(const char *key, double value) {
    uint32_t code, size, type;
    int r = key_code(key, &code);
    if (r) return r;
    if (!(value >= 0) || value > 65535) return HW_SMC_ERR_ARG;  // also rejects NaN
    // Defense in depth: a fan target ("F?Tg") is never written as 0 / near-stop
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

int hw_smc_open(void) {
    pthread_mutex_lock(&g_lock);
    int r = 0;
    if (!g_conn) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!svc) {
            r = HW_SMC_ERR_CLOSED;
        } else {
            kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
            IOObjectRelease(svc);
            if (kr != KERN_SUCCESS) { g_conn = 0; r = (int)kr; }
        }
    }
    pthread_mutex_unlock(&g_lock);
    return r;
}

void hw_smc_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
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

// MARK: - Crash guard

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
    // Last resort before the process dies: hand fans back to the system. If the crashing
    // thread holds the lock we go ahead anyway — a stuck forced fan is the worse outcome.
    int locked = pthread_mutex_trylock(&g_lock) == 0;
    guard_restore_unlocked();
    if (locked) pthread_mutex_unlock(&g_lock);
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

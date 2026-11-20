// Persistent zero-sleep in-process IOReport sampler via dyld shared cache libIOReport.dylib.
// Reads GPU active residency, CPU E/P/S tier active residencies (including 3-tier Apple M6),
// and Energy Model wattage without spawning any external process.
#include "hw_ioreport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <string.h>

typedef CFDictionaryRef (*ior_copy_group_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*ior_merge_t)(CFMutableDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFTypeRef (*ior_create_sub_t)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*ior_create_samples_t)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*ior_create_delta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ior_get_str_t)(CFDictionaryRef);
typedef uint8_t (*ior_get_fmt_t)(CFDictionaryRef);
typedef int32_t (*ior_state_cnt_t)(CFDictionaryRef);
typedef CFStringRef (*ior_state_name_t)(CFDictionaryRef, int32_t);
typedef int64_t (*ior_state_res_t)(CFDictionaryRef, int32_t);
typedef int64_t (*ior_simple_int_t)(CFDictionaryRef, int32_t);

static pthread_mutex_t g_ior_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_ior_inited = 0;
static int g_ior_ok = 0;

static ior_copy_group_t fn_copy_group = NULL;
static ior_merge_t fn_merge = NULL;
static ior_create_sub_t fn_create_sub = NULL;
static ior_create_samples_t fn_create_samples = NULL;
static ior_create_delta_t fn_create_delta = NULL;
static ior_get_str_t fn_get_group = NULL;
static ior_get_str_t fn_get_sub = NULL;
static ior_get_str_t fn_get_name = NULL;
static ior_get_str_t fn_get_unit = NULL;
static ior_get_fmt_t fn_get_fmt = NULL;
static ior_state_cnt_t fn_state_cnt = NULL;
static ior_state_name_t fn_state_name = NULL;
static ior_state_res_t fn_state_res = NULL;
static ior_simple_int_t fn_simple_int = NULL;

static CFTypeRef g_sub = NULL;
static CFMutableDictionaryRef g_sub_chans = NULL;
static CFDictionaryRef g_prev_sample = NULL;
static uint64_t g_prev_ns = 0;
static mach_timebase_info_data_t g_ior_tb = {1, 1};

static uint64_t monotonic_ns(void) {
    return (uint64_t)(((__uint128_t)mach_continuous_time() * g_ior_tb.numer) / g_ior_tb.denom);
}

static int cfstr_to_buf(CFStringRef s, char *buf, size_t cap) {
    if (!s || cap == 0) {
        if (cap > 0) buf[0] = '\0';
        return 0;
    }
    if (CFStringGetCString(s, buf, (CFIndex)cap, kCFStringEncodingUTF8)) return 1;
    buf[0] = '\0';
    return 0;
}

static void init_unlocked(void) {
    if (g_ior_inited) return;
    g_ior_inited = 1;
    mach_timebase_info(&g_ior_tb);
    if (g_ior_tb.denom == 0) { g_ior_tb.numer = 1; g_ior_tb.denom = 1; }

    void *h = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!h) return;

    fn_copy_group    = (ior_copy_group_t)dlsym(h, "IOReportCopyChannelsInGroup");
    fn_merge         = (ior_merge_t)dlsym(h, "IOReportMergeChannels");
    fn_create_sub    = (ior_create_sub_t)dlsym(h, "IOReportCreateSubscription");
    fn_create_samples= (ior_create_samples_t)dlsym(h, "IOReportCreateSamples");
    fn_create_delta  = (ior_create_delta_t)dlsym(h, "IOReportCreateSamplesDelta");
    fn_get_group     = (ior_get_str_t)dlsym(h, "IOReportChannelGetGroup");
    fn_get_sub       = (ior_get_str_t)dlsym(h, "IOReportChannelGetSubGroup");
    fn_get_name      = (ior_get_str_t)dlsym(h, "IOReportChannelGetChannelName");
    fn_get_unit      = (ior_get_str_t)dlsym(h, "IOReportChannelGetUnitLabel");
    fn_get_fmt       = (ior_get_fmt_t)dlsym(h, "IOReportChannelGetFormat");
    fn_state_cnt     = (ior_state_cnt_t)dlsym(h, "IOReportStateGetCount");
    fn_state_name    = (ior_state_name_t)dlsym(h, "IOReportStateGetNameForIndex");
    fn_state_res     = (ior_state_res_t)dlsym(h, "IOReportStateGetResidency");
    fn_simple_int    = (ior_simple_int_t)dlsym(h, "IOReportSimpleGetIntegerValue");

    if (!fn_copy_group || !fn_merge || !fn_create_sub || !fn_create_samples ||
        !fn_create_delta || !fn_get_group || !fn_get_sub || !fn_get_name ||
        !fn_get_unit || !fn_get_fmt || !fn_state_cnt || !fn_state_name ||
        !fn_state_res || !fn_simple_int) {
        return;
    }

    CFDictionaryRef c_cpu = fn_copy_group(CFSTR("CPU Stats"), NULL, 0, 0, 0);
    CFDictionaryRef c_gpu = fn_copy_group(CFSTR("GPU Stats"), NULL, 0, 0, 0);
    CFDictionaryRef c_eng = fn_copy_group(CFSTR("Energy Model"), NULL, 0, 0, 0);

    CFMutableDictionaryRef all = NULL;
    if (c_cpu) {
        all = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, c_cpu);
        CFRelease(c_cpu);
    } else if (c_gpu) {
        all = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, c_gpu);
        CFRelease(c_gpu);
        c_gpu = NULL;
    } else if (c_eng) {
        all = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, c_eng);
        CFRelease(c_eng);
        c_eng = NULL;
    }
    if (!all) return;

    if (c_gpu) { fn_merge(all, c_gpu, NULL); CFRelease(c_gpu); }
    if (c_eng) { fn_merge(all, c_eng, NULL); CFRelease(c_eng); }

    g_sub = fn_create_sub(NULL, all, &g_sub_chans, 0, NULL);
    CFRelease(all);
    if (!g_sub || !g_sub_chans) {
        if (g_sub) { CFRelease(g_sub); g_sub = NULL; }
        if (g_sub_chans) { CFRelease(g_sub_chans); g_sub_chans = NULL; }
        return;
    }
    g_ior_ok = 1;
}

static double state_active_ratio(CFDictionaryRef ch) {
    int32_t sc = fn_state_cnt(ch);
    if (sc <= 0) return -1.0;
    int64_t idle = 0, active = 0;
    char sname[32];
    for (int32_t i = 0; i < sc; i++) {
        int64_t r = fn_state_res(ch, i);
        if (r <= 0) continue;
        cfstr_to_buf(fn_state_name(ch, i), sname, sizeof(sname));
        if (strcmp(sname, "IDLE") == 0 || strcmp(sname, "OFF") == 0 || strcmp(sname, "DOWN") == 0) {
            idle += r;
        } else {
            active += r;
        }
    }
    int64_t total = idle + active;
    if (total <= 0) return -1.0;
    return (double)active / (double)total;
}

static double energy_to_watts(int64_t raw, const char *unit, double dt_sec) {
    if (raw < 0 || dt_sec <= 0.0) return -1.0;
    double scale = 0.0;
    if (strcmp(unit, "nJ") == 0) scale = 1e-9;
    else if (strcmp(unit, "uJ") == 0) scale = 1e-6;
    else if (strcmp(unit, "mJ") == 0) scale = 1e-3;
    else if (strcmp(unit, "J") == 0) scale = 1.0;
    else return -1.0;
    double w = ((double)raw * scale) / dt_sec;
    return (isfinite(w) && w >= 0.0 && w < 500.0) ? w : -1.0;
}

int hw_ioreport_available(void) {
    pthread_mutex_lock(&g_ior_lock);
    init_unlocked();
    int ok = g_ior_ok;
    pthread_mutex_unlock(&g_ior_lock);
    return ok;
}

int hw_ioreport_sample(hw_ioreport_sample_t *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    pthread_mutex_lock(&g_ior_lock);
    init_unlocked();
    if (!g_ior_ok) {
        pthread_mutex_unlock(&g_ior_lock);
        return -1;
    }

    uint64_t now_ns = monotonic_ns();
    CFDictionaryRef cur = fn_create_samples(g_sub, g_sub_chans, NULL);
    if (!cur) {
        pthread_mutex_unlock(&g_ior_lock);
        return -1;
    }

    if (!g_prev_sample) {
        g_prev_sample = cur;
        g_prev_ns = now_ns;
        pthread_mutex_unlock(&g_ior_lock);
        return 0; // baseline seeded; out->valid = 0
    }

    double dt_sec = (now_ns > g_prev_ns) ? (double)(now_ns - g_prev_ns) / 1e9 : 0.0;
    if (dt_sec < 0.05) {
        CFRelease(cur);
        pthread_mutex_unlock(&g_ior_lock);
        return 0;
    }
    if (dt_sec > 30.0) {
        CFRelease(g_prev_sample);
        g_prev_sample = cur;
        g_prev_ns = now_ns;
        pthread_mutex_unlock(&g_ior_lock);
        return 0;
    }

    CFDictionaryRef delta = fn_create_delta(g_prev_sample, cur, NULL);
    CFRelease(g_prev_sample);
    g_prev_sample = cur;
    g_prev_ns = now_ns;

    if (!delta) {
        pthread_mutex_unlock(&g_ior_lock);
        return -1;
    }

    CFArrayRef chans = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (chans && CFGetTypeID(chans) == CFArrayGetTypeID()) {
        CFIndex n = CFArrayGetCount(chans);
        double e_sum = 0, m_sum = 0, p_sum = 0;
        int e_cnt = 0, m_cnt = 0, p_cnt = 0;
        char grp[64], sub[64], name[64], unit[16];

        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(chans, i);
            if (!ch) continue;
            uint8_t fmt = fn_get_fmt(ch);
            cfstr_to_buf(fn_get_group(ch), grp, sizeof(grp));
            cfstr_to_buf(fn_get_sub(ch), sub, sizeof(sub));
            cfstr_to_buf(fn_get_name(ch), name, sizeof(name));

            if (fmt == 2 && strcmp(grp, "GPU Stats") == 0 &&
                strcmp(sub, "GPU Performance States") == 0 &&
                strcmp(name, "GPUPH") == 0) {
                double ratio = state_active_ratio(ch);
                if (ratio >= 0.0) {
                    out->has_gpu = 1;
                    out->gpu_active = ratio;
                }
            } else if (fmt == 2 && strcmp(grp, "CPU Stats") == 0 &&
                       strcmp(sub, "CPU Core Performance States") == 0) {
                double ratio = state_active_ratio(ch);
                if (ratio >= 0.0) {
                    if (strstr(name, "ECPU")) {
                        e_sum += ratio; e_cnt++;
                    } else if (strstr(name, "MCPU")) {
                        m_sum += ratio; m_cnt++;
                    } else if (strstr(name, "PCPU")) {
                        p_sum += ratio; p_cnt++;
                    }
                }
            } else if (fmt == 1 && strcmp(grp, "Energy Model") == 0) {
                cfstr_to_buf(fn_get_unit(ch), unit, sizeof(unit));
                int64_t raw = fn_simple_int(ch, 0);
                double w = energy_to_watts(raw, unit, dt_sec);
                if (w >= 0.0) {
                    if (strcmp(name, "GPU Energy") == 0) {
                        out->has_gpu_power = 1;
                        out->gpu_power_w = w;
                    } else if (strcmp(name, "CPU Energy") == 0) {
                        out->has_cpu_power = 1;
                        out->cpu_power_w = w;
                    } else if (strstr(name, "ANE") != NULL) {
                        out->has_ane_power = 1;
                        out->ane_power_w += w;
                    }
                }
            }
        }

        if (e_cnt > 0 || m_cnt > 0 || p_cnt > 0) {
            out->has_cpu_tiers = 1;
            out->cpu_e = e_cnt > 0 ? (e_sum / e_cnt) : 0.0;
            if (m_cnt > 0) {
                // 3-tier Apple Silicon (e.g. M6: ECPU=E, MCPU=P, PCPU=S)
                out->has_super = 1;
                out->cpu_p = m_sum / m_cnt;
                out->cpu_s = p_cnt > 0 ? (p_sum / p_cnt) : 0.0;
            } else {
                // 2-tier Apple Silicon (M1..M5: ECPU=E, PCPU=P)
                out->has_super = 0;
                out->cpu_p = p_cnt > 0 ? (p_sum / p_cnt) : 0.0;
                out->cpu_s = 0.0;
            }
        }
        out->valid = (out->has_gpu || out->has_cpu_tiers || out->has_gpu_power || out->has_cpu_power);
    }

    CFRelease(delta);
    pthread_mutex_unlock(&g_ior_lock);
    return 0;
}

void hw_ioreport_reset(void) {
    pthread_mutex_lock(&g_ior_lock);
    if (g_prev_sample) {
        CFRelease(g_prev_sample);
        g_prev_sample = NULL;
    }
    g_prev_ns = 0;
    pthread_mutex_unlock(&g_ior_lock);
}

void hw_ioreport_close(void) {
    pthread_mutex_lock(&g_ior_lock);
    if (g_prev_sample) { CFRelease(g_prev_sample); g_prev_sample = NULL; }
    if (g_sub_chans) { CFRelease(g_sub_chans); g_sub_chans = NULL; }
    if (g_sub) { CFRelease(g_sub); g_sub = NULL; }
    g_ior_ok = 0;
    g_ior_inited = 0;
    pthread_mutex_unlock(&g_ior_lock);
}

// Fake AppleSMC behind the IOKit calls hw_smc.c makes, so the real C encoder, the policy and
// FanBoostController can be exercised on Linux. Behaviour follows agoodkind/macos-smc-fan:
//   M4: F%dMd, Ftst present; mode is 3 (system) and mode writes fail with 0x82 until Ftst=1,
//       then keep failing for ~3 s; Ftst=0 hands fans back (mode 3).
//   M5: F%dmd (lowercase), no Ftst, direct mode writes succeed.
#include "IOKit/IOKitLib.h"
#include "fake_smc.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} smc_keydata_t;

#define FOURCC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))
#define T_FLT FOURCC('f', 'l', 't', ' ')
#define T_UI8 FOURCC('u', 'i', '8', ' ')

typedef struct { char name[5]; uint32_t type, size; uint8_t bytes[32]; } fkey;
static fkey g_keys[64];
static int g_nkeys, g_model, g_denied, g_writes, g_countdown;
static double g_min_tg = 1e9;
static FILE *g_log;

const mach_port_t kIOMainPortDefault = 0;
CFMutableDictionaryRef IOServiceMatching(const char *name) { (void)name; return (void *)1; }
io_service_t IOServiceGetMatchingService(mach_port_t p, CFDictionaryRef m) { (void)p; (void)m; return 7; }
kern_return_t IOServiceOpen(io_service_t s, task_port_t t, uint32_t ty, io_connect_t *c) { (void)s; (void)t; (void)ty; *c = 9; return 0; }
kern_return_t IOServiceClose(io_connect_t c) { (void)c; return 0; }
kern_return_t IOObjectRelease(io_object_t o) { (void)o; return 0; }
task_port_t mach_task_self(void) { return 1; }
uid_t geteuid(void) { return 0; }  // pretend root so the writable path is exercised

static fkey *find(const char *name) {
    for (int i = 0; i < g_nkeys; i++) if (!strncmp(g_keys[i].name, name, 4)) return &g_keys[i];
    return NULL;
}
static double getv(fkey *k) {
    if (k->type == T_FLT) { float f; memcpy(&f, k->bytes, 4); return f; }
    return k->bytes[0];
}
static void setv(fkey *k, double v) {
    if (k->type == T_FLT) { float f = (float)v; memcpy(k->bytes, &f, 4); }
    else k->bytes[0] = (uint8_t)v;
}
static void add(const char *name, uint32_t type, double v) {
    fkey *k = &g_keys[g_nkeys++];
    memset(k, 0, sizeof(*k)); memcpy(k->name, name, 4);
    k->type = type; k->size = type == T_FLT ? 4 : 1;
    setv(k, v);
}

void fake_smc_reset(int model) {
    g_nkeys = 0; g_model = model; g_denied = 0; g_writes = 0; g_countdown = 0; g_min_tg = 1e9;
    if (!g_log && getenv("FAKE_SMC_LOG")) g_log = fopen(getenv("FAKE_SMC_LOG"), "w");
    if (model == FAKE_FANLESS) { add("FNum", T_UI8, 0); return; }
    add("FNum", T_UI8, 2);
    const char m = model == FAKE_M5 ? 'm' : 'M';
    for (int i = 0; i < 2; i++) {
        char k[5];
        snprintf(k, 5, "F%dMn", i); add(k, T_FLT, 1200);
        snprintf(k, 5, "F%dMx", i); add(k, T_FLT, 5800);
        snprintf(k, 5, "F%dAc", i); add(k, T_FLT, 1500);
        snprintf(k, 5, "F%dTg", i); add(k, T_FLT, 1500);
        snprintf(k, 5, "F%d%cd", i, m); add(k, T_UI8, 3);
    }
    if (model == FAKE_M4) add("Ftst", T_UI8, 0);
}
void fake_smc_set_denied(int d) { g_denied = d; }
double fake_smc_get(const char *key) { fkey *k = find(key); return k ? getv(k) : NAN; }
void fake_smc_set(const char *key, double v) { fkey *k = find(key); if (k) setv(k, v); }
int fake_smc_write_count(void) { return g_writes; }
double fake_smc_min_target_written(void) { return g_min_tg; }

static int is_mode(const char *n) { return n[0] == 'F' && (n[2] == 'M' || n[2] == 'm') && n[3] == 'd'; }

kern_return_t IOConnectCallStructMethod(mach_port_t c, uint32_t sel, const void *inS, size_t inN, void *outS, size_t *outN) {
    (void)c;
    if (sel != 2 || inN != sizeof(smc_keydata_t) || *outN != sizeof(smc_keydata_t)) return (kern_return_t)0xe00002c2;
    const smc_keydata_t *in = inS; smc_keydata_t *out = outS;
    memset(out, 0, sizeof(*out));
    char name[5] = { (char)(in->key >> 24), (char)(in->key >> 16), (char)(in->key >> 8), (char)in->key, 0 };
    fkey *k = find(name);
    if (!k) { out->result = 0x84; return 0; }
    switch (in->data8) {
    case 9: out->keyInfo.dataSize = k->size; out->keyInfo.dataType = k->type; return 0;
    case 5:
        if (in->keyInfo.dataSize != k->size) { out->result = 0x87; return 0; }
        memcpy(out->bytes, k->bytes, k->size); return 0;
    case 6: {
        if (g_denied) return (kern_return_t)0xe00002c1;
        if (in->keyInfo.dataSize != k->size) { out->result = 0x87; return 0; }
        fkey tmp = *k; memcpy(tmp.bytes, in->bytes, k->size);
        double v = getv(&tmp);
        g_writes++;
        if (g_log) { fprintf(g_log, "%s=%g\n", name, v); fflush(g_log); }
        fkey *ftst = find("Ftst");
        if (is_mode(name) && g_model == FAKE_M4) {
            if (!ftst || getv(ftst) != 1) { out->result = 0x82; return 0; }   // thermalmonitord holds mode 3
            if (v == 1 && g_countdown > 0) { g_countdown--; out->result = 0x82; return 0; }
        }
        if (name[2] == 'T' && name[3] == 'g' && v < g_min_tg) g_min_tg = v;
        setv(k, v);
        if (!strcmp(name, "Ftst")) {
            if (v == 1) g_countdown = 30;  // ~3 s of 100 ms retries
            else for (int i = 0; i < g_nkeys; i++) if (is_mode(g_keys[i].name)) setv(&g_keys[i], 3);
        }
        return 0;
    }
    default: out->result = 0x82; return 0;
    }
}

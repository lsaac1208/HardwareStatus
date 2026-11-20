#ifndef HW_IOREPORT_H
#define HW_IOREPORT_H

#include <stdint.h>

typedef struct {
    int valid;
    int has_gpu;
    double gpu_active;      // 0.0 ... 1.0
    int has_cpu_tiers;
    int has_super;          // 1 on 3-tier chips like Apple M6 (E + P + S)
    double cpu_e;           // 0.0 ... 1.0
    double cpu_p;           // 0.0 ... 1.0
    double cpu_s;           // 0.0 ... 1.0
    int has_cpu_power;
    double cpu_power_w;
    int has_gpu_power;
    double gpu_power_w;
    int has_ane_power;
    double ane_power_w;
} hw_ioreport_sample_t;

// Returns 1 if libIOReport loaded and subscribed, 0 if unavailable.
int hw_ioreport_available(void);

// Takes an instantaneous delta since the previous call (no sleep, no subprocesses).
// First call seeds the baseline and sets out->valid = 0.
int hw_ioreport_sample(hw_ioreport_sample_t *out);

// Clears baseline sample (call on wake from sleep so delta never spans sleep).
void hw_ioreport_reset(void);

// Releases subscription and samples on app termination.
void hw_ioreport_close(void);

#endif

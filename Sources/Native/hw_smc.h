#ifndef HW_SMC_H
#define HW_SMC_H

#include <stdint.h>

#define HW_SMC_ERR_CLOSED (-1001)
#define HW_SMC_ERR_ARG    (-1002)
#define HW_SMC_ERR_TYPE   (-1003)
#define HW_SMC_ERR_SMC    0x1000

typedef struct {
    int has_cpu_temp;
    double cpu_temp_c;
    int has_gpu_temp;
    double gpu_temp_c;
    int fan_count;
    int has_fan_rpm;
    int fan_rpm;
    int fan_max_rpm;
    int has_sys_power;
    double sys_power_w;
} hw_smc_sensors_t;

int hw_smc_open(void);
void hw_smc_close(void);
int hw_smc_key_info(const char *key, uint32_t *size, uint32_t *type);
int hw_smc_read_number(const char *key, double *out);
int hw_smc_write_number(const char *key, double value);

// Fast-path cached in-process sensor reader (CPU/GPU temp, fans, total system power).
// Enumerates #KEY once and caches key metadata; subsequent reads issue kCmdRead directly.
int hw_smc_read_sensors(hw_smc_sensors_t *out);

// Crash guard: restores automatic fan control from fatal signal handlers if armed.
void hw_smc_guard_configure(const char *mode_keys, int count, int clear_ftst, int legacy_fs);
void hw_smc_guard_arm(int armed);
void hw_smc_guard_restore(void);
void hw_smc_install_crash_handlers(void);

#endif

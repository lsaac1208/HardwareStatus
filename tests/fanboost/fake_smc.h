// Test-only controls for fake_smc.c (Linux harness; see run.sh)
#include <stdint.h>
enum { FAKE_M4 = 0, FAKE_M5 = 1, FAKE_FANLESS = 2 };
void fake_smc_reset(int model);
void fake_smc_set_denied(int denied);
double fake_smc_get(const char *key);   // NaN if missing
void fake_smc_set(const char *key, double value);
int fake_smc_write_count(void);
double fake_smc_min_target_written(void);  // lowest F?Tg ever written (1e9 if none)

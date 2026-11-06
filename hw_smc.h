#include <stdint.h>

// Minimal in-process AppleSMC client (no daemon / helper). All calls are serialized
// internally; return 0 on success, otherwise an IOKit kern_return_t (e.g. 0xe00002c1
// kIOReturnNotPrivileged) or HW_SMC_ERR_SMC | <SMC result byte> (0x84 = key not found).
#define HW_SMC_ERR_SMC     0x10000
#define HW_SMC_ERR_TYPE    0x20000   // key exists but its data type isn't supported
#define HW_SMC_ERR_CLOSED  0x30000   // hw_smc_open() not called / failed
#define HW_SMC_ERR_ARG     0x40000

int hw_smc_open(void);
void hw_smc_close(void);
/// Data size / 4-char type code of a key (type packed big-endian, e.g. 'flt ').
int hw_smc_key_info(const char *key, uint32_t *size, uint32_t *type);
/// Decode flt / fpe2 / ui8 / ui16 / ui32 / flag / sp78 into a double.
int hw_smc_read_number(const char *key, double *out);
/// Encode `value` in the key's own type (looked up first) and write it.
int hw_smc_write_number(const char *key, double value);

/// Crash guard: while armed, fatal signals (SIGSEGV/BUS/ILL/FPE/ABRT/TRAP) and
/// hw_smc_guard_restore() write every registered mode key back to 0 (automatic),
/// optionally clear Ftst, then the signal is re-raised with the previous handler.
/// `mode_keys` = up to 8 four-char keys concatenated (e.g. "F0MdF1Md"); `legacy_fs` = 1
/// writes "FS! " = 0 instead (Intel bitmask). Call before the first fan write.
void hw_smc_guard_configure(const char *mode_keys, int count, int clear_ftst, int legacy_fs);
void hw_smc_guard_arm(int armed);
/// Best-effort synchronous restore using the guard configuration (no-op when disarmed).
void hw_smc_guard_restore(void);
void hw_smc_install_crash_handlers(void);

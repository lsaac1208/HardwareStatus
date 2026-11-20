#ifndef HW_PROC_H
#define HW_PROC_H

#include <stdint.h>

#define HW_NET_MAX_IFACES 32

typedef struct {
    uint64_t phys_footprint;
    uint64_t user_ns;
    uint64_t system_ns;
    uint64_t start_ns;
} hw_proc_sample_t;

typedef struct {
    char name[32];
    uint64_t in_bytes;
    uint64_t out_bytes;
} hw_net_iface_t;

typedef struct {
    int count;
    hw_net_iface_t ifaces[HW_NET_MAX_IFACES];
} hw_net_sample_t;

// Single-syscall process sample: phys_footprint + timebase-corrected CPU ns + start time ns.
// Returns 0 on success, -1 on failure (e.g. EPERM or exited pid).
int hw_proc_sample(int32_t pid, hw_proc_sample_t *out);

// Legacy helper kept for compatibility.
uint64_t hw_phys_footprint(int32_t pid);

// 64-bit physical network interface counters via sysctl(IFMIB_IFDATA).
// Filters out virtual/tunnel/bridge interfaces (utun*, awdl*, llw*, bridge*, anpi*, ap*, lo*)
// so VPN/TUN traffic is never double-counted. Returns 0 on success, -1 on failure.
int hw_net_sample(hw_net_sample_t *out);

// Real macOS kernel memory pressure level: 1 = normal, 2 = warn, 4 = critical, 0 = unavailable.
int hw_memory_pressure_level(void);

#endif

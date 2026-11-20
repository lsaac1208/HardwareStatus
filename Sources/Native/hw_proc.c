#include "hw_proc.h"

#include <libproc.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_mib.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

static mach_timebase_info_data_t g_tb = {1, 1};
static pthread_once_t g_tb_once = PTHREAD_ONCE_INIT;

static void init_timebase(void) {
    mach_timebase_info(&g_tb);
    if (g_tb.denom == 0) {
        g_tb.numer = 1;
        g_tb.denom = 1;
    }
}

static inline uint64_t mach_ticks_to_ns(uint64_t ticks) {
    pthread_once(&g_tb_once, init_timebase);
    return (uint64_t)(((__uint128_t)ticks * g_tb.numer) / g_tb.denom);
}

int hw_proc_sample(int32_t pid, hw_proc_sample_t *out) {
    if (!out || pid <= 0) return -1;
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) {
        return -1;
    }
    out->phys_footprint = ri.ri_phys_footprint;
    out->user_ns = mach_ticks_to_ns(ri.ri_user_time);
    out->system_ns = mach_ticks_to_ns(ri.ri_system_time);
    out->start_ns = mach_ticks_to_ns(ri.ri_proc_start_abstime);
    return 0;
}

uint64_t hw_phys_footprint(int32_t pid) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0) {
        return ri.ri_phys_footprint;
    }
    return 0;
}

// Keep only physical NICs (en* = Wi-Fi / Ethernet / USB / Thunderbolt NIC, pdp_ip* = cellular)
// to prevent double-counting traffic across TUN/VPN (utun*), AirDrop (awdl*), bridge*, etc.
static int is_physical_iface(const char *name) {
    if (!name || !name[0]) return 0;
    if (name[0] == 'e' && name[1] == 'n' && name[2] >= '0' && name[2] <= '9') return 1;
    if (strncmp(name, "pdp_ip", 6) == 0 && name[6] >= '0' && name[6] <= '9') return 1;
    return 0;
}

int hw_net_sample(hw_net_sample_t *out) {
    if (!out) return -1;
    out->count = 0;

    struct if_nameindex *list = if_nameindex();
    if (!list) return -1;

    for (struct if_nameindex *p = list; p->if_index != 0 && p->if_name != NULL; p++) {
        if (!is_physical_iface(p->if_name)) continue;
        if (out->count >= HW_NET_MAX_IFACES) break;

        int mib[6] = {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, (int)p->if_index, IFDATA_GENERAL};
        struct ifmibdata ifmd;
        size_t len = sizeof(ifmd);
        if (sysctl(mib, 6, &ifmd, &len, NULL, 0) != 0) continue;

        int flags = ifmd.ifmd_flags;
        if (!(flags & IFF_UP) || !(flags & IFF_RUNNING) || (flags & IFF_LOOPBACK)) continue;

        hw_net_iface_t *dst = &out->ifaces[out->count++];
        memset(dst->name, 0, sizeof(dst->name));
        strncpy(dst->name, p->if_name, sizeof(dst->name) - 1);
        dst->in_bytes = ifmd.ifmd_data.ifi_ibytes;
        dst->out_bytes = ifmd.ifmd_data.ifi_obytes;
    }

    if_freenameindex(list);
    return 0;
}

int hw_memory_pressure_level(void) {
    int level = 0;
    size_t sz = sizeof(level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &sz, NULL, 0) == 0) {
        return level;
    }
    return 0;
}

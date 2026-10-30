#include <libproc.h>
#include <stdint.h>
#include <string.h>

uint64_t hw_phys_footprint(int pid) {
    struct rusage_info_v4 info;
    memset(&info, 0, sizeof(info));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) {
        return 0;
    }
    return info.ri_phys_footprint;
}

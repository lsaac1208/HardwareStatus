// Linux-only stub for syntax checking hw_smc.c (signatures as in macOS SDK)
#include <stdint.h>
#include <stddef.h>
typedef int kern_return_t; typedef unsigned int mach_port_t; typedef mach_port_t io_object_t, io_service_t, io_connect_t, task_port_t;
#define KERN_SUCCESS 0
extern const mach_port_t kIOMainPortDefault;
typedef const void *CFDictionaryRef; typedef CFDictionaryRef CFMutableDictionaryRef;
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);
task_port_t mach_task_self(void);
kern_return_t IOConnectCallStructMethod(mach_port_t connection, uint32_t selector, const void *inputStruct, size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt);

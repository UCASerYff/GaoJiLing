#include "NativeMetrics.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/mount.h>
#include <libproc.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <time.h>
#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int gjl_sysctl_string(const char *name, char *out, size_t capacity) {
    if (!capacity) return 0;
    size_t size = capacity - 1;
    memset(out, 0, capacity);
    return sysctlbyname(name, out, &size, NULL, 0) == 0;
}

void gjl_system_snapshot(GJLSystem *out) {
    memset(out, 0, sizeof(*out));
    mach_port_t host = mach_host_self();
    natural_t count = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t info_count = 0;
    if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &info_count) == KERN_SUCCESS) {
        out->core_count = (int)(count < 256 ? count : 256);
        for (int i = 0; i < out->core_count; i++) {
            integer_t *p = info + i * CPU_STATE_MAX;
            out->cores[i] = (GJLCoreTicks){ (uint32_t)p[CPU_STATE_USER], (uint32_t)p[CPU_STATE_SYSTEM], (uint32_t)p[CPU_STATE_IDLE], (uint32_t)p[CPU_STATE_NICE] };
        }
        vm_deallocate(mach_task_self(), (vm_address_t)info, info_count * sizeof(integer_t));
    }
    size_t size = sizeof(out->memory_total);
    sysctlbyname("hw.memsize", &out->memory_total, &size, NULL, 0);
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size = 0;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) == KERN_SUCCESS && host_page_size(host, &page_size) == KERN_SUCCESS && out->memory_total > 0) {
        // App memory (anonymous minus purgeable) + wired + physical compressor.
        uint64_t anonymous = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
        out->memory_used = (anonymous + vm.wire_count + vm.compressor_page_count) * (uint64_t)page_size;
        if (out->memory_used > out->memory_total) out->memory_used = out->memory_total;
        out->memory_compressed = vm.compressor_page_count * (uint64_t)page_size;
        out->memory_valid = 1;
    }
    mach_port_deallocate(mach_task_self(), host);
    struct xsw_usage swap = {0}; size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) out->swap_used = swap.xsu_used;
    size = sizeof(out->pressure_level);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure_level, &size, NULL, 0) != 0) out->pressure_level = 0;
    struct timespec uptime = {0};
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &uptime) == 0) out->uptime = uptime.tv_sec + uptime.tv_nsec / 1e9;
    struct statfs fs = {0};
    if (statfs("/System/Volumes/Data", &fs) != 0) statfs("/", &fs);
    out->disk_free = (uint64_t)fs.f_bavail * fs.f_bsize;
    out->disk_total = (uint64_t)fs.f_blocks * fs.f_bsize;
}

int gjl_network_counters(GJLCounter *out, int capacity) {
    // NET_RT_IFLIST2 exposes 64-bit counters; getifaddrs counters wrap at 4 GiB.
    int mib[] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || !length) return -1;
    char *buffer = malloc(length);
    if (!buffer) return -1;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) { free(buffer); return -1; }
    int count = 0;
    for (char *cursor = buffer; cursor + sizeof(struct if_msghdr) <= buffer + length;) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (!header->ifm_msglen || cursor + header->ifm_msglen > buffer + length) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2) && count < capacity) {
            const struct if_msghdr2 *entry = (struct if_msghdr2 *)cursor;
            char name[IFNAMSIZ] = {0};
            if_indextoname(entry->ifm_index, name);
            // Exclude virtual/tunnel mirrors and AirDrop to avoid double counting.
            if ((entry->ifm_flags & IFF_UP) && !(entry->ifm_flags & IFF_LOOPBACK) && strncmp(name, "en", 2) == 0)
                out[count++] = (GJLCounter){ entry->ifm_index, entry->ifm_data.ifi_ibytes, entry->ifm_data.ifi_obytes };
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return count;
}

static double dictionary_number(CFDictionaryRef dictionary, CFStringRef key) {
    if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) return NAN;
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    double number = NAN;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberDoubleType, &number);
    return number;
}
static double registry_number(io_registry_entry_t entry, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    double number = NAN;
    if (value) { if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberDoubleType, &number); CFRelease(value); }
    return number;
}

int gjl_disk_counters(GJLCounter *out, int capacity) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) != KERN_SUCCESS) return -1;
    int count = 0; io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID() && count < capacity) {
            double read = dictionary_number(stats, CFSTR("Bytes (Read)"));
            double written = dictionary_number(stats, CFSTR("Bytes (Write)"));
            uint64_t identifier = 0;
            if (isfinite(read) && isfinite(written) && IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS)
                out[count++] = (GJLCounter){ identifier, (uint64_t)read, (uint64_t)written };
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

int gjl_process_snapshot(GJLProcess **out, int *total_count) {
    *out = NULL; *total_count = 0;
    int estimate = proc_listallpids(NULL, 0);
    if (estimate <= 0) return -1;
    int capacity = estimate + 256;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    GJLProcess *records = calloc((size_t)capacity, sizeof(GJLProcess));
    if (!pids || !records) { free(pids); free(records); return -1; }
    int count = proc_listallpids(pids, capacity * sizeof(pid_t));
    if (count < 0) { free(pids); free(records); return -1; }
    if (count > capacity) count = capacity;
    mach_timebase_info_data_t timebase = {1, 1};
    mach_timebase_info(&timebase);
    int found = 0;
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0) continue;
        (*total_count)++;
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;
        GJLProcess *p = &records[found];
        p->pid = pids[i]; p->start_time = usage.ri_proc_start_abstime;
        // rusage CPU times are Mach absolute ticks, not nanoseconds (notably on Apple Silicon).
        p->cpu_nanoseconds = (uint64_t)(((__uint128_t)usage.ri_user_time + usage.ri_system_time) * timebase.numer / (timebase.denom ? timebase.denom : 1));
        p->memory_bytes = usage.ri_phys_footprint;
        proc_name(pids[i], p->name, sizeof(p->name));
        proc_pidpath(pids[i], p->path, sizeof(p->path));
        if (!p->name[0]) snprintf(p->name, sizeof(p->name), "PID %d", pids[i]);
        found++;
    }
    free(pids); *out = records; return found;
}
void gjl_free_processes(GJLProcess *processes) { free(processes); }

// Read-only AppleSMC protocol. Layout follows the MIT-licensed Glance SMC reader.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCPower;
typedef struct { uint32_t size, kind; uint8_t attributes; } SMCKeyInfo;
typedef struct { uint32_t key; SMCVersion version; SMCPower power; SMCKeyInfo info; uint8_t result, status, command; uint32_t data; uint8_t bytes[32]; } SMCExchange;
_Static_assert(sizeof(SMCExchange) == 80, "SMC exchange layout");
static uint32_t smc_code(const char *key) { return (uint32_t)(uint8_t)key[0]<<24 | (uint32_t)(uint8_t)key[1]<<16 | (uint32_t)(uint8_t)key[2]<<8 | (uint8_t)key[3]; }
static double smc_number(io_connect_t connection, const char *key) {
    SMCExchange input = {0}, output = {0}; input.key = smc_code(key); input.command = 9; size_t size = sizeof(output);
    if (IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &size) || output.result) return NAN;
    input.info = output.info; input.command = 5; memset(&output, 0, sizeof(output)); size = sizeof(output);
    if (IOConnectCallStructMethod(connection, 2, &input, sizeof(input), &output, &size) || output.result) return NAN;
    const uint8_t *b = output.bytes;
    if (input.info.kind == smc_code("flt ") && input.info.size == 4) { float f; memcpy(&f, b, 4); return f; }
    if (input.info.kind == smc_code("fpe2") && input.info.size == 2) return ((uint16_t)b[0]*256 + b[1])/4.0;
    if (input.info.kind == smc_code("sp78") && input.info.size == 2) return (int16_t)((uint16_t)b[0]*256 + b[1])/256.0;
    if (input.info.kind == smc_code("ui8 ") && input.info.size == 1) return b[0];
    if (input.info.kind == smc_code("ui16") && input.info.size == 2) return (uint16_t)b[0]*256 + b[1];
    return NAN;
}

static double hid_cpu_temperature(void) {
    // Optional private HID entry points: missing symbols simply mean unavailable.
    typedef CFTypeRef (*Create)(CFAllocatorRef);
    typedef void (*Match)(CFTypeRef, CFDictionaryRef);
    typedef CFArrayRef (*Services)(CFTypeRef);
    typedef CFTypeRef (*Property)(CFTypeRef, CFStringRef);
    typedef CFTypeRef (*Event)(CFTypeRef, int64_t, int32_t, int64_t);
    typedef double (*Value)(CFTypeRef, int32_t);
    Create create = (Create)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    Match match = (Match)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
    Services services = (Services)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    Property property = (Property)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    Event event = (Event)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
    Value value = (Value)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    if (!create || !match || !services || !property || !event || !value) return NAN;
    CFTypeRef client = create(kCFAllocatorDefault);
    if (!client) return NAN;
    int page = 0xff00, usage = 5;
    CFNumberRef page_number = CFNumberCreate(NULL, kCFNumberIntType, &page), usage_number = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page_number, usage_number };
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    match(client, matching); CFRelease(matching); CFRelease(page_number); CFRelease(usage_number);
    CFArrayRef sensors = services(client);
    double sum = 0; int found = 0;
    if (sensors) {
        for (CFIndex i = 0; i < CFArrayGetCount(sensors); i++) {
            CFTypeRef sensor = CFArrayGetValueAtIndex(sensors, i);
            CFTypeRef name = property(sensor, CFSTR("Product"));
            char label[256] = {0};
            if (name && CFGetTypeID(name) == CFStringGetTypeID()) CFStringGetCString(name, label, sizeof(label), kCFStringEncodingUTF8);
            if (name) CFRelease(name);
            if (!strstr(label, "CPU") && !strstr(label, "cpu") && !strstr(label, "pACC") && !strstr(label, "eACC")) continue;
            CFTypeRef reading = event(sensor, 15, 0, 0);
            if (reading) { double temperature = value(reading, 15 << 16); if (isfinite(temperature) && temperature > 0 && temperature < 150) { sum += temperature; found++; } CFRelease(reading); }
        }
        CFRelease(sensors);
    }
    CFRelease(client);
    return found ? sum / found : NAN;
}

void gjl_sensor_snapshot(GJLSensors *out) {
    *out = (GJLSensors){ .battery_percent = NAN, .battery_health = NAN, .battery_cycles = -1, .gpu_percent = NAN, .cpu_temperature = NAN, .cpu_power = NAN, .gpu_power = NAN, .fan_rpm = NAN };
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef sources = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (sources) {
        for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
            CFDictionaryRef description = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(sources, i));
            if (!description) continue;
            CFTypeRef type = CFDictionaryGetValue(description, CFSTR(kIOPSTypeKey));
            if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
            double current = dictionary_number(description, CFSTR(kIOPSCurrentCapacityKey));
            double maximum = dictionary_number(description, CFSTR(kIOPSMaxCapacityKey));
            if (current >= 0 && maximum > 0) out->battery_percent = fmin(100, current / maximum * 100);
            CFTypeRef charging = CFDictionaryGetValue(description, CFSTR(kIOPSIsChargingKey));
            out->battery_charging = charging == kCFBooleanTrue;
            break;
        }
        CFRelease(sources);
    }
    if (info) CFRelease(info);
    io_service_t battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (battery) {
        double maximum = registry_number(battery, CFSTR("AppleRawMaxCapacity"));
        if (!isfinite(maximum)) maximum = registry_number(battery, CFSTR("MaxCapacity"));
        double design = registry_number(battery, CFSTR("DesignCapacity"));
        // Recent macOS exposes absolute capacities inside BatteryData, while MaxCapacity is a percentage.
        CFTypeRef battery_data = IORegistryEntryCreateCFProperty(battery, CFSTR("BatteryData"), kCFAllocatorDefault, 0);
        if (battery_data && CFGetTypeID(battery_data) == CFDictionaryGetTypeID()) {
            if (!(maximum > 100)) maximum = dictionary_number(battery_data, CFSTR("NominalChargeCapacity"));
            if (!(maximum > 100)) maximum = dictionary_number(battery_data, CFSTR("FullChargeCapacity"));
            if (!(design > 0)) design = dictionary_number(battery_data, CFSTR("DesignCapacity"));
        }
        if (battery_data) CFRelease(battery_data);
        if (maximum > 0 && design > 0 && maximum > 100) out->battery_health = fmin(100, maximum / design * 100);
        double cycles = registry_number(battery, CFSTR("CycleCount"));
        if (cycles >= 0 && cycles < 100000) out->battery_cycles = (int)cycles;
        IOObjectRelease(battery);
    }
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS) {
        io_service_t accelerator;
        while ((accelerator = IOIteratorNext(iterator))) {
            CFTypeRef stats = IORegistryEntryCreateCFProperty(accelerator, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                double utilization = dictionary_number(stats, CFSTR("Device Utilization %"));
                if (!isfinite(utilization)) utilization = dictionary_number(stats, CFSTR("GPU Activity(%)"));
                if (utilization >= 0 && utilization <= 100) out->gpu_percent = isnan(out->gpu_percent) ? utilization : fmax(out->gpu_percent, utilization);
            }
            if (stats) CFRelease(stats);
            IOObjectRelease(accelerator);
        }
        IOObjectRelease(iterator);
    }
    out->cpu_temperature = hid_cpu_temperature();
    io_service_t smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (smc) {
        io_connect_t connection = 0;
        if (IOServiceOpen(smc, mach_task_self(), 0, &connection) == KERN_SUCCESS) {
            // SMC key semantics cross-checked against exelban/Stats (MIT), Modules/Sensors/values.swift.
            // Only probe CPU keys for the detected chip family; missing keys do not become zero.
            char chip[128] = {0}; gjl_sysctl_string("machdep.cpu.brand_string", chip, sizeof(chip));
            const char *m1[] = { "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b" };
            const char *m2[] = { "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j" };
            const char *m3[] = { "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E" };
            const char *m4[] = { "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e" };
            const char **cpu_keys = NULL; size_t cpu_key_count = 0;
            if (strstr(chip, "Apple M1")) { cpu_keys = m1; cpu_key_count = sizeof(m1)/sizeof(m1[0]); }
            else if (strstr(chip, "Apple M2")) { cpu_keys = m2; cpu_key_count = sizeof(m2)/sizeof(m2[0]); }
            else if (strstr(chip, "Apple M3")) { cpu_keys = m3; cpu_key_count = sizeof(m3)/sizeof(m3[0]); }
            else if (strstr(chip, "Apple M4")) { cpu_keys = m4; cpu_key_count = sizeof(m4)/sizeof(m4[0]); }
            if (!isfinite(out->cpu_temperature) && cpu_keys) {
                double total = 0; int found = 0;
                for (size_t i = 0; i < cpu_key_count; i++) { double t = smc_number(connection, cpu_keys[i]); if (t >= 10 && t < 130) { total += t; found++; } }
                if (found) out->cpu_temperature = total / found;
            }
            const char *keys[] = { "TCAD", "TC0D", "TC0P", "TC0E", "TC0F" };
            if (!isfinite(out->cpu_temperature)) for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
                double t = smc_number(connection, keys[i]);
                if (t > 0 && t < 150) { out->cpu_temperature = t; break; }
            }
            double fans = smc_number(connection, "FNum");
            if (isfinite(fans) && fans >= 1 && fans <= 16) for (int i = 0; i < (int)fans; i++) {
                char key[5]; snprintf(key, sizeof(key), "F%XAc", i);
                double rpm = smc_number(connection, key);
                if (rpm >= 0 && rpm < 30000) out->fan_rpm = isnan(out->fan_rpm) ? rpm : fmax(out->fan_rpm, rpm);
            }
            // PCPC is CPU package power on supported Intel SMCs. Never use total-system power as CPU power.
            double power = smc_number(connection, "PCPC");
            if (power >= 0 && power < 1000) out->cpu_power = power;
            IOServiceClose(connection);
        }
        IOObjectRelease(smc);
    }
}

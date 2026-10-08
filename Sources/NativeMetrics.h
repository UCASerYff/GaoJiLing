#ifndef GAOJILING_NATIVE_METRICS_H
#define GAOJILING_NATIVE_METRICS_H
#include <stdint.h>
#include <stddef.h>

typedef struct { uint32_t user, system, idle, nice; } GJLCoreTicks;
typedef struct {
    int core_count;
    GJLCoreTicks cores[256];
    uint64_t memory_total, memory_used, memory_compressed, swap_used;
    int memory_valid, pressure_level;
    double uptime;
    uint64_t disk_free, disk_total;
} GJLSystem;
typedef struct { uint64_t identifier, received, sent; } GJLCounter;
typedef struct {
    int32_t pid;
    uint64_t start_time, cpu_nanoseconds, memory_bytes;
    char name[256];
    char path[4096];
} GJLProcess;
typedef struct {
    double battery_percent, battery_health;
    int battery_charging, battery_cycles;
    double gpu_percent, cpu_temperature, cpu_power, gpu_power, fan_rpm;
} GJLSensors;
void gjl_system_snapshot(GJLSystem *out);
int gjl_network_counters(GJLCounter *out, int capacity);
int gjl_disk_counters(GJLCounter *out, int capacity);
int gjl_process_snapshot(GJLProcess **out, int *total_count);
void gjl_free_processes(GJLProcess *processes);
void gjl_sensor_snapshot(GJLSensors *out);
int gjl_sysctl_string(const char *name, char *out, size_t capacity);

/* Independent, fresh snapshot for maintenance; does not alter monitor sampling. */
typedef struct {
    uint64_t total, used, free_bytes, file_cache, purgeable, compressed, swap;
    int memory_valid, swap_valid, pressure_level;
} GJLMemoryMaintenance;
int gjl_memory_maintenance_snapshot(GJLMemoryMaintenance *out);
uint64_t gjl_memory_maintenance_relief(void);
/* 1: running, 0: absent, -1: cannot safely establish absence. */
int gjl_application_running(const char *bundle_path, int check_developer_tools);
/* Conservative global check for package managers and compilers, no argv read. */
int gjl_development_tools_running(void);
#endif

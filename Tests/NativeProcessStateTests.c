/* Standalone, targeted native regression. Build into an owned .noindex folder.
 * Only our own bounded fork child is enumerated. No App, GUI, LS or signal
 * other than the read-only signal-0 query is used. */
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>

enum Scenario {
    REAL_CHILD, BSD_DENIED, PATH_DENIED, PROBE_DENIED, PROBE_SHORT,
    WRONG_PID, WRONG_UID, NOT_ZOMBIE, REUSED_PID, CONFIRM_DENIED
};
static enum Scenario scenario;
static pid_t owned_child;
static unsigned int probe_count;
static int fixture_list(uint32_t, uint32_t, void *, int);
static int fixture_info(int, int, uint64_t, void *, int);
static int fixture_path(int, void *, uint32_t);
static int fixture_existence(pid_t, int);

#define proc_listpids fixture_list
#define proc_pidinfo fixture_info
#define proc_pidpath fixture_path
#define kill fixture_existence
#include "../Sources/NativeMetrics.c"
#undef proc_listpids
#undef proc_pidinfo
#undef proc_pidpath
#undef kill

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static int fixture_list(uint32_t type, uint32_t uid, void *buffer, int size) {
    require(type == PROC_UID_ONLY && uid == geteuid() && owned_child > 0, "enumeration is restricted to our child");
    if (buffer) {
        require(size >= (int)sizeof(owned_child), "fixture PID buffer capacity");
        memcpy(buffer, &owned_child, sizeof(owned_child));
    }
    return sizeof(owned_child);
}

static int fixture_info(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    require(pid == owned_child && flavor == PROC_PIDTBSDINFO && (arg == 0 || arg == 1), "only our child's BSD state is queried");
    if (arg == 0 && scenario == BSD_DENIED) { errno = EACCES; return 0; }
    if (arg == 1) {
        ++probe_count;
        if (scenario == PROBE_DENIED || (scenario == CONFIRM_DENIED && probe_count == 2)) { errno = EACCES; return 0; }
    }
    int result = proc_pidinfo(pid, flavor, arg, buffer, size);
    if (arg == 1 && result == sizeof(struct proc_bsdinfo)) {
        struct proc_bsdinfo *info = buffer;
        if (scenario == PROBE_SHORT) return result - 1;
        if (scenario == WRONG_PID) info->pbi_pid++;
        if (scenario == WRONG_UID) info->pbi_uid++;
        if (scenario == NOT_ZOMBIE) info->pbi_status = SRUN;
        if (scenario == REUSED_PID && probe_count == 2) info->pbi_start_tvusec++;
    }
    return result;
}

static int fixture_path(int pid, void *buffer, uint32_t size) {
    require(pid == owned_child, "only our child's executable path is queried");
    if (scenario == PATH_DENIED) { errno = EACCES; return 0; }
    return proc_pidpath(pid, buffer, size);
}

static int fixture_existence(pid_t pid, int signal_number) {
    require(pid == owned_child && signal_number == 0, "only signal 0 is permitted for our child");
    return kill(pid, 0);
}

static void expect(const char *target, enum Scenario next, int result, const char *name) {
    scenario = next;
    probe_count = 0;
    require(gjl_application_running(target, 0) == result, name);
    printf("PASS: %s\n", name);
}

int main(void) {
    char target[PROC_PIDPATHINFO_MAXSIZE] = {0};
    require(proc_pidpath(getpid(), target, sizeof(target)) > 0, "read only this test executable's path");
    char *separator = strrchr(target, '/');
    require(separator != NULL, "test executable parent exists");
    *separator = '\0';
    struct stat directory = {0};
    size_t length = strlen(target);
    require(length >= 8 && strcmp(target + length - 8, ".noindex") == 0 &&
        lstat(target, &directory) == 0 && S_ISDIR(directory.st_mode) &&
        directory.st_uid == geteuid() && (directory.st_mode & 077) == 0,
        "test binary must be inside an owned private .noindex folder");

    int control[2], ready[2];
    require(pipe(control) == 0 && pipe(ready) == 0, "create child-only control pipes");
    owned_child = fork();
    require(owned_child >= 0, "fork our bounded child");
    if (owned_child == 0) {
        close(control[1]); close(ready[0]);
        char value = 'R';
        if (write(ready[1], &value, 1) != 1) _exit(2);
        close(ready[1]);
        struct pollfd descriptor = {control[0], POLLIN | POLLHUP, 0};
        // The child exits on parent EOF or after five seconds, even if a check
        // fails. Its parent can only reap this exact child, never other PIDs.
        (void)poll(&descriptor, 1, 5000);
        close(control[0]);
        _exit(0);
    }
    close(control[0]); close(ready[1]);
    struct pollfd ready_descriptor = {ready[0], POLLIN, 0};
    char value = 0;
    require(poll(&ready_descriptor, 1, 2000) > 0 && read(ready[0], &value, 1) == 1 && value == 'R', "child reached its bounded wait");
    close(ready[0]);

    expect(target, REAL_CHILD, 1, "active owned target is running");
    expect(target, BSD_DENIED, -1, "live BSD permission failure stays unknown");
    expect(target, PATH_DENIED, -1, "live executable-path failure stays unknown");

    close(control[1]); // Normal EOF exit, not a termination signal.
    struct proc_bsdinfo zombie = {0};
    int observed = 0;
    for (int attempt = 0; attempt < 200; ++attempt) {
        if (proc_pidinfo(owned_child, PROC_PIDTBSDINFO, 1, &zombie, sizeof(zombie)) == sizeof(zombie) &&
            zombie.pbi_pid == (uint32_t)owned_child && zombie.pbi_uid == geteuid() && zombie.pbi_status == SZOMB) { observed = 1; break; }
        struct timespec delay = {0, 10000000};
        nanosleep(&delay, NULL);
    }
    require(observed, "observe a real unreaped owned Zombie");
    errno = 0;
    require(proc_pidinfo(owned_child, PROC_PIDTBSDINFO, 0, &zombie, sizeof(zombie)) == 0 && errno == ESRCH,
        "real Zombie reproduces original BSD ESRCH");
    require(kill(owned_child, 0) == 0, "real Zombie PID still passes signal 0");

    expect(target, REAL_CHILD, 0, "real owned Zombie no longer makes an inactive target unknown");
    require(probe_count == 2, "Zombie identity is checked twice");
    expect(target, PROBE_DENIED, -1, "Zombie-inclusive permission failure stays unknown");
    expect(target, PROBE_SHORT, -1, "Zombie-inclusive short read stays unknown");
    expect(target, WRONG_PID, -1, "mismatching Zombie PID stays unknown");
    expect(target, WRONG_UID, -1, "mismatching Zombie UID stays unknown");
    expect(target, NOT_ZOMBIE, -1, "unproven terminal state stays unknown");
    expect(target, REUSED_PID, -1, "changed start time on confirmation stays unknown");
    expect(target, CONFIRM_DENIED, -1, "failed second Zombie identity check stays unknown");

    int status = 0;
    require(waitpid(owned_child, &status, 0) == owned_child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "reap only our exact normally exited child");
    puts("PASS: 11 targeted native cases; own child exited normally and was reaped; no App/GUI/LS or termination signal");
    return 0;
}

/* Deterministic boundaries for the real native dual-location implementation.
 * Only namespace-local syscall doubles supply process observations. All paths
 * are exclusively owned fixtures; no real PID, App, GUI, Trash or signal. */
#include <libproc.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum Observation { ABSENT, ORIGINAL_ACTIVE, CURRENT_ACTIVE, NEARBY, BSD_UNKNOWN,
    PATH_UNKNOWN, CONFIRM_CHANGED, UID_CHANGED, REPLACE_CURRENT, REPLACE_ORIGINAL };
static enum Observation observation;
static char original_path[PATH_MAX], current_path[PATH_MAX], parked_path[PATH_MAX];
static int info_calls;
static int fixture_list(uint32_t, uint32_t, void *, int);
static int fixture_info(int, int, uint64_t, void *, int);
static int fixture_path(int, void *, uint32_t);
static int fixture_signal(pid_t, int);
#define proc_listpids fixture_list
#define proc_pidinfo fixture_info
#define proc_pidpath fixture_path
#define kill fixture_signal
#include "../Sources/NativeMetrics.c"
#undef proc_listpids
#undef proc_pidinfo
#undef proc_pidpath
#undef kill

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static int fixture_list(uint32_t kind, uint32_t uid, void *buffer, int capacity) {
    require(kind == PROC_UID_ONLY && uid == geteuid(), "same-user enumeration only");
    pid_t pids[] = { 999991, 999992 };
    if (buffer) {
        require(capacity >= (int)sizeof(pids), "PID buffer capacity");
        memcpy(buffer, pids, sizeof(pids));
        if (observation == REPLACE_CURRENT) {
            require(rename(current_path, parked_path) == 0 && mkdir(current_path, 0700) == 0, "replace only our current fixture");
        }
        if (observation == REPLACE_ORIGINAL) require(mkdir(original_path, 0700) == 0, "replace only our absent original fixture");
    }
    return sizeof(pids);
}
static int fixture_info(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    require((pid == 999991 || pid == 999992) && flavor == PROC_PIDTBSDINFO &&
        size == sizeof(struct proc_bsdinfo), "synthetic process observation only");
    if (arg == 1 || (observation == BSD_UNKNOWN && pid == 999992)) { errno = EACCES; return 0; }
    require(arg == 0, "expected BSD query");
    struct proc_bsdinfo *info = buffer;
    memset(info, 0, sizeof(*info)); info->pbi_pid = pid; info->pbi_uid = geteuid();
    info->pbi_start_tvsec = 100; info->pbi_start_tvusec = 5;
    if (observation == UID_CHANGED && pid == 999992) info->pbi_uid++;
    if (observation == CONFIRM_CHANGED && (++info_calls % 2) == 0) info->pbi_start_tvusec++;
    return sizeof(*info);
}
static int fixture_path(int pid, void *buffer, uint32_t size) {
    require(pid == 999991 || pid == 999992, "synthetic path only");
    if (observation == PATH_UNKNOWN && pid == 999992) { errno = EACCES; return 0; }
    const char *prefix = observation == ORIGINAL_ACTIVE ? original_path : current_path;
    int written;
    if (observation == ORIGINAL_ACTIVE || observation == CURRENT_ACTIVE)
        written = snprintf(buffer, size, "%s/Contents/MacOS/Fixture", prefix);
    else if (observation == NEARBY) written = snprintf(buffer, size, "%s-near/Contents/MacOS/Fixture", prefix);
    else written = snprintf(buffer, size, "/usr/bin/unrelated-fixture");
    return written > 0 && written < (int)size ? written : 0;
}
static int fixture_signal(pid_t pid, int number) {
    require((pid == 999991 || pid == 999992) && number == 0, "only intercepted signal zero allowed");
    errno = EPERM; return -1;
}
static int observed(const char *original, const char *current, struct stat identity, enum Observation mode) {
    observation = mode; info_calls = 0;
    return gjl_application_running_at_locations(original, current,
        (uint64_t)(int64_t)identity.st_dev, identity.st_ino, identity.st_uid);
}
static void expect(int value, int expected, const char *message) {
    require(value == expected, message); printf("PASS: %s\n", message);
}

int main(int argc, char **argv) {
    require(argc == 2, "explicit owned private .noindex fixture root argument required");
    char root[PATH_MAX] = {0}; struct stat root_info = {0};
    require(realpath(argv[1], root) && !strcmp(root, argv[1]) && lstat(root, &root_info) == 0 &&
        S_ISDIR(root_info.st_mode) && root_info.st_uid == geteuid() && (root_info.st_mode & 077) == 0 &&
        strlen(root) > 8 && !strcmp(root + strlen(root) - 8, ".noindex"), "private canonical fixture root");
    require(snprintf(original_path, sizeof(original_path), "%s/Fixture.app", root) < (int)sizeof(original_path) &&
        snprintf(current_path, sizeof(current_path), "%s/staged-bundle", root) < (int)sizeof(current_path) &&
        snprintf(parked_path, sizeof(parked_path), "%s/parked-bundle", root) < (int)sizeof(parked_path), "bounded fixture paths");
    require(mkdir(current_path, 0700) == 0, "create exclusive fixture bundle");
    struct stat bundle = {0}; require(lstat(current_path, &bundle) == 0, "record current identity");
    expect(observed(original_path, current_path, bundle, ABSENT), 0, "verified moved bundle inactive when original is missing");
    expect(observed(original_path, current_path, bundle, ORIGINAL_ACTIVE), 1, "historical original executable prefix remains protected");
    expect(observed(original_path, current_path, bundle, CURRENT_ACTIVE), 1, "current staged executable prefix remains protected");
    expect(observed(original_path, current_path, bundle, NEARBY), 0, "nearby prefix cannot match the exact bundle");
    expect(observed(original_path, current_path, bundle, BSD_UNKNOWN), -1, "one readable unrelated process cannot cover another unknown BSD record");
    expect(observed(original_path, current_path, bundle, PATH_UNKNOWN), -1, "one readable unrelated process cannot cover another unknown path");
    expect(observed(original_path, current_path, bundle, CONFIRM_CHANGED), -1, "changed PID start identity stays unknown");
    expect(observed(original_path, current_path, bundle, UID_CHANGED), -1, "PID changed UID stays unknown");
    struct stat wrong = bundle; wrong.st_ino++;
    expect(observed(original_path, current_path, wrong, ABSENT), -1, "wrong current inode rejected");
    wrong = bundle; wrong.st_dev++;
    expect(observed(original_path, current_path, wrong, ABSENT), -1, "wrong current device rejected");
    wrong = bundle; wrong.st_uid++;
    expect(observed(original_path, current_path, wrong, ABSENT), -1, "wrong current UID rejected");
    require(mkdir(original_path, 0700) == 0, "create original conflict");
    expect(observed(original_path, current_path, bundle, ABSENT), -1, "replacement at original path prevents inactivity claim");
    require(rmdir(original_path) == 0, "remove only our empty conflict");
    expect(observed(original_path, current_path, bundle, REPLACE_CURRENT), -1, "current root replacement during enumeration stays unknown");
    require(rmdir(current_path) == 0 && rename(parked_path, current_path) == 0, "restore only our parked fixture");
    expect(observed(original_path, current_path, bundle, REPLACE_ORIGINAL), -1, "original replacement during enumeration stays unknown");
    require(rmdir(original_path) == 0, "remove only our empty new conflict");
    require(rename(current_path, parked_path) == 0 && symlink(parked_path, current_path) == 0, "fixture current symlink");
    expect(observed(original_path, current_path, bundle, ABSENT), -1, "current root symlink is never followed");
    require(unlink(current_path) == 0, "remove only our fixture link");
    expect(observed(original_path, current_path, bundle, ABSENT), -1, "missing current bundle never establishes absence");
    require(rename(parked_path, current_path) == 0, "restore parked fixture");
    char alias[PATH_MAX], original_alias[PATH_MAX];
    require(snprintf(alias, sizeof(alias), "%s/alias", root) < (int)sizeof(alias) &&
        snprintf(original_alias, sizeof(original_alias), "%s/alias/Fixture.app", root) < (int)sizeof(original_alias) &&
        symlink(root, alias) == 0, "fixture historical-parent symlink");
    expect(observed(original_alias, current_path, bundle, ABSENT), -1, "historical original parent symlink rejected");
    require(unlink(alias) == 0, "remove only our alias");
    expect(observed(current_path, current_path, bundle, ABSENT), 0, "same exact existing location remains valid");
    require(rmdir(current_path) == 0, "remove only our empty bundle");
    puts("PASS: 18 moved-application native boundaries; no real process observation, signal, App or GUI");
    return 0;
}

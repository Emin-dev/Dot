/* Test-only Darwin process-creation capability probe. No arbitrary command mode.
 * The controller compiles and ad-hoc signs this source in a private fresh dir.
 * sandbox_init's fixed public C ABI is resolved from Apple's fixed system dylib:
 * int sandbox_init(const char *, uint64_t, char **). This intentionally exercises
 * the deprecated API without suppressing compiler diagnostics or changing any
 * system setting. Unsupported API availability is a failing capability result.
 */
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int wait_child(pid_t pid, int expected) {
    const struct timespec interval = {0, 10000000};
    int status = 0;
    for (int i = 0; i < 200; i++) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid)
            return WIFEXITED(status) && WEXITSTATUS(status) == expected ? 0 : 1;
        if (result < 0 && errno != EINTR) return 1;
        nanosleep(&interval, NULL);
    }
    /* Never leave a successful positive-control child running on timeout. */
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) return 1;
    for (int i = 0; i < 200; i++) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) return 1;  /* A killed/timed-out child is failure. */
        if (result < 0 && errno != EINTR) return 1;
        nanosleep(&interval, NULL);
    }
    return 1;
}

static int lifecycle(const char *mode) {
    const struct timespec lifetime = {10, 0};
    if (strcmp(mode, "lifecycle-exit") == 0) {
        puts("LEADER_EXIT");
    } else if (strcmp(mode, "lifecycle-live") == 0) {
        puts("LEADER_LIVE");
        if (fflush(stdout) != 0) return 76;
        nanosleep(&lifetime, NULL);
    } else if (strcmp(mode, "lifecycle-mixed") == 0) {
        pid_t child = fork();
        if (child < 0) return 77;
        if (child == 0) {
            nanosleep(&lifetime, NULL);  /* Hard bounded, same owned group. */
            _exit(0);
        }
        printf("MIXED_CHILD %ld\n", (long)child);
    } else {
        return 64;
    }
    return fflush(stdout) == 0 ? 0 : 75;
}

int main(int argc, char **argv) {
    if (argc == 2 && strncmp(argv[1], "lifecycle-", 10) == 0)
        return lifecycle(argv[1]);
    int denied = argc == 3 && strcmp(argv[1], "deny") == 0;
    if (!(argc == 2 && strcmp(argv[1], "control") == 0) && !denied) return 64;
    if (denied) {
        if (strlen(argv[2]) > 32768 || strncmp(argv[2], "(version 1)(deny default)", 25) != 0)
            return 65;
        void *library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW | RTLD_LOCAL);
        if (library == NULL) return 66;
        typedef int (*init_fn)(const char *, uint64_t, char **);
        typedef void (*free_fn)(char *);
        init_fn initialize = (init_fn)dlsym(library, "sandbox_init");
        free_fn release_error = (free_fn)dlsym(library, "sandbox_free_error");
        if (initialize == NULL || release_error == NULL) return 67;
        char *error = NULL;
        if (initialize(argv[2], 0, &error) != 0) {
            if (error != NULL) release_error(error);
            return 68;
        }
        /* Keep this fixed system library mapped until process exit. */
    }
    errno = 0;
    pid_t child = fork();
    int fork_error = errno;
    if (child == 0) _exit(17);
    if (child > 0) {
        if (wait_child(child, 17) != 0) return 69;
        if (denied) return 70;
        puts("FORK_OK 17");
    } else {
        if (!denied || (fork_error != EPERM && fork_error != EACCES)) return 71;
        printf("FORK_DENIED %d\n", fork_error);
    }
    /* This executable/argv is also allowed by the unmodified production
     * profile. Denial must therefore come from process creation containment,
     * rather than using an otherwise forbidden executable as a false control.
     */
    char *const spawn_argv[] = {"/usr/sbin/sysctl", "-n", "hw.optional.arm64", NULL};
    char *const spawn_env[] = {"PATH=/usr/bin:/usr/sbin", "LANG=C", "LC_ALL=C", "TZ=UTC", NULL};
    child = -1;
    int spawn_error = posix_spawn(&child, spawn_argv[0], NULL, NULL, spawn_argv, spawn_env);
    if (spawn_error == 0) {
        if (child <= 0 || wait_child(child, 0) != 0) return 72;
        if (denied) return 73;
        puts("SPAWN_OK 0");
    } else {
        if (!denied || (spawn_error != EPERM && spawn_error != EACCES)) return 74;
        printf("SPAWN_DENIED %d\n", spawn_error);
    }
    return fflush(stdout) == 0 ? 0 : 75;
}

/* Search-only native launcher. Build on the target macOS SDK; no Python runs
 * before listener ownership and the restrictive Seatbelt policy are established.
 * Production admission additionally requires the signed, exact-artifact receipt.
 */
#define _DARWIN_C_SOURCE 1
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <sandbox.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

/* Apple exports this interface, used by WebKit/Chromium; it is not a stable
 * public App Sandbox entitlement API. Every supported macOS build needs canaries.
 */
extern int sandbox_init_with_parameters(const char *, uint64_t, const char *const *, char **);

static void fail(void) {
    static const char message[] = "{\"protocol\":1,\"event\":\"failed\",\"reason\":\"native_boundary_failed\"}\n";
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(2);
}
/* Bound every pre-exec step without relying on a parent PID/name/port kill.
 * This launcher performs no DNS resolution. No pipe write or blocking cleanup
 * is safe in this handler: EOF is already a fail-closed control result.
 */
static void startup_expired(int signal_number) {
    (void)signal_number;
    _exit(2);
}
static void arm_startup_deadline(void) {
    struct sigaction action = {0};
    sigset_t unblocked;
    action.sa_handler = startup_expired;
    if (sigemptyset(&action.sa_mask) || sigaction(SIGALRM, &action, NULL) ||
        sigemptyset(&unblocked) || sigaddset(&unblocked, SIGALRM) ||
        sigprocmask(SIG_UNBLOCK, &unblocked, NULL)) _exit(2);
    (void)alarm(10);
}
static void join(char out[PATH_MAX], const char *root, const char *suffix) {
    int count = snprintf(out, PATH_MAX, "%s/%s", root, suffix);
    if (count <= 0 || count >= PATH_MAX) fail();
}
static void canonical(const char *input, char out[PATH_MAX], bool directory, bool private_state) {
    struct stat node;
    if (!input || input[0] != '/' || !realpath(input, out) || strcmp(input, out) != 0 || lstat(out, &node) != 0) fail();
    if ((directory ? !S_ISDIR(node.st_mode) : !S_ISREG(node.st_mode)) || S_ISLNK(node.st_mode)) fail();
    if (node.st_uid != getuid() && node.st_uid != 0) fail();
    if ((node.st_mode & 0022) || (!directory && node.st_nlink != 1)) fail();
    if (private_state && (node.st_uid != getuid() || (node.st_mode & 0777) != 0700)) fail();
}
/* A nonsecret decimal scalar, deliberately without aliases or leading zeroes. */
static unsigned int parse_port(const char *value) {
    if (!value || !value[0] || value[0] == '0') fail();
    unsigned int port = 0;
    for (const char *digit = value; *digit; digit++) {
        if (*digit < '0' || *digit > '9') fail();
        if (port > (65535U - (unsigned int)(*digit - '0')) / 10U) fail();
        port = port * 10U + (unsigned int)(*digit - '0');
    }
    if (!port) fail();
    return port;
}

int main(int argc, char **argv) {
    arm_startup_deadline();
    if (argc != 7 || strcmp(argv[1], "--payload") || strcmp(argv[3], "--state-root") || strcmp(argv[5], "--egress-port")) fail();
    unsigned int egress_port = parse_port(argv[6]);
    char payload[PATH_MAX], state[PATH_MAX], python[PATH_MAX], helper[PATH_MAX], profile_path[PATH_MAX], expected_self[PATH_MAX];
    canonical(argv[2], payload, true, false); canonical(argv[4], state, true, true);
    if (strncmp(state, payload, strlen(payload)) == 0 || strncmp(payload, state, strlen(state)) == 0) fail();
    char candidate[PATH_MAX];
    join(candidate, payload, "python/bin/python3"); canonical(candidate, python, false, false);
    join(candidate, payload, "dot_search.py"); canonical(candidate, helper, false, false);
    join(candidate, payload, "search.sb"); canonical(candidate, profile_path, false, false);
    join(candidate, payload, "bin/dot-search-bootstrap"); canonical(candidate, expected_self, false, false);
    char executable[PATH_MAX], actual_self[PATH_MAX]; uint32_t executable_size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &executable_size) != 0 || !realpath(executable, actual_self) || strcmp(actual_self, expected_self)) fail();
    struct stat control, events;
    if (fstat(STDIN_FILENO, &control) || fstat(STDOUT_FILENO, &events) || !S_ISFIFO(control.st_mode) || !S_ISFIFO(events.st_mode)) fail();
    int policy_fd = open(profile_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat policy_stat;
    if (policy_fd < 0 || fstat(policy_fd, &policy_stat) || !S_ISREG(policy_stat.st_mode) || policy_stat.st_size <= 0 || policy_stat.st_size > 65536) fail();
    char *policy = calloc((size_t)policy_stat.st_size + 1, 1);
    if (!policy) fail();
    size_t loaded = 0;
    while (loaded < (size_t)policy_stat.st_size) {
        ssize_t got = read(policy_fd, policy + loaded, (size_t)policy_stat.st_size - loaded);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) fail();
        loaded += (size_t)got;
    }
    close(policy_fd);
    if (memchr(policy, '\0', loaded)) fail();

    int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in local = {0}; local.sin_family = AF_INET; local.sin_len = sizeof(local);
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK); local.sin_port = 0;
    if (listener < 0 || bind(listener, (struct sockaddr *)&local, sizeof(local)) || listen(listener, 4)) fail();
    socklen_t local_size = sizeof(local);
    if (getsockname(listener, (struct sockaddr *)&local, &local_size) || local_size != sizeof(local) || !local.sin_port) fail();
    char listen_address[32];
    if (snprintf(listen_address, sizeof(listen_address), "localhost:%u", ntohs(local.sin_port)) >= (int)sizeof(listen_address)) fail();
    if (listener != 3) { if (dup2(listener, 3) != 3) fail(); close(listener); }
    if (fcntl(3, F_SETFD, 0)) fail();
    closefrom(4);
    char egress_address[32];
    if (snprintf(egress_address, sizeof(egress_address), "localhost:%u", egress_port) >= (int)sizeof(egress_address)) fail();
    const char *parameters[] = {
        "DOT_SEARCH_PAYLOAD", payload, "DOT_SEARCH_STATE", state,
        "DOT_SEARCH_PYTHON", python, "DOT_SEARCH_LISTENER", listen_address,
        "DOT_SEARCH_EGRESS", egress_address, NULL
    };
    char *sandbox_error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (sandbox_init_with_parameters(policy, 0, parameters, &sandbox_error) != 0) {
        if (sandbox_error) sandbox_free_error(sandbox_error);
        fail();
    }
#pragma clang diagnostic pop
    free(policy);
    if (chdir(state)) fail();
    char home[PATH_MAX + 8], temporary[PATH_MAX + 8];
    if (snprintf(home, sizeof(home), "HOME=%s", state) >= (int)sizeof(home) ||
        snprintf(temporary, sizeof(temporary), "TMPDIR=%s", state) >= (int)sizeof(temporary)) fail();
    char *environment[] = {"PATH=/usr/bin:/bin", home, temporary, "LANG=en_US.UTF-8", "PYTHONDONTWRITEBYTECODE=1", NULL};
    char *arguments[] = {python, "-I", "-S", "-B", helper, "--payload", payload, "--state-root", state, "--owned-listener", "3", "--egress-port", argv[6], NULL};
    /* The Python supervisor owns its own startup and EOF lifetime. Never let a
     * native-only timer survive exec and kill a healthy supervisor later.
     */
    (void)alarm(0);
    execve(python, arguments, environment);
    /* exec failed: restore the bound before reporting on the control pipe. */
    arm_startup_deadline();
    fail();
}

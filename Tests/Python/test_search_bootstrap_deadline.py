"""Compile/run the production native deadline with build-only platform fixtures.

This exercises the actual C translation unit. Only macOS path/sandbox calls and
alarm duration are substituted in the test wrapper; no external network or
real sandbox is used. The production deadline stays fixed at ten seconds, with
no environment flag or runtime test hook. This is not native macOS acceptance.
"""
import contextlib
import fcntl
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "packaging/search/dot-search-bootstrap.c"
COMPILER = shutil.which("cc")

WRAPPER = r'''
#define _DEFAULT_SOURCE 1
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#define alarm fixture_alarm
#ifdef __linux__
/* Linux has no sin_len; this padding byte has no socket semantics here. */
#define sin_len sin_zero[0]
#endif
#include "BOOTSTRAP_SOURCE"
#undef alarm
#include <sys/resource.h>
extern unsigned int alarm(unsigned int);

static const char *mode;
unsigned int fixture_alarm(unsigned int seconds) {
    if (seconds != 0 && seconds != 10) _exit(90);
    return alarm(seconds ? 1 : 0);
}
int _NSGetExecutablePath(char *out, uint32_t *length) {
    const char *path = getenv("FIXTURE_EXECUTABLE");
    if (!path || strlen(path) + 1 > *length) return -1;
    strcpy(out, path); return 0;
}
int sandbox_init_with_parameters(const char *policy, uint64_t flags,
                                 const char *const *parameters, char **error) {
    (void)policy; (void)flags; (void)error;
    const char *keys[] = {"DOT_SEARCH_PAYLOAD", "DOT_SEARCH_STATE", "DOT_SEARCH_PYTHON",
                          "DOT_SEARCH_LISTENER", "DOT_SEARCH_EGRESS"};
    for (size_t index = 0; index < 5; index++) {
        if (!parameters[2 * index] || strcmp(parameters[2 * index], keys[index]) ||
            !parameters[2 * index + 1]) _exit(97);
    }
    if (parameters[10] || strncmp(parameters[7], "localhost:", 10) ||
        strcmp(parameters[9], "localhost:54321")) _exit(98);
    if (!strcmp(mode, "policy_failure")) return -1;
    if (strstr(mode, "policy_stall")) {
        (void)write(STDERR_FILENO, "P", 1);
        for (;;) pause();
    }
    return 0;
}
void sandbox_free_error(char *error) { (void)error; }
static void setup_fixture(void) __attribute__((constructor));
static void setup_fixture(void) {
    mode = getenv("FIXTURE_MODE");
    if (!mode) _exit(93);
    if (strstr(mode, "low_limit")) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit)) _exit(91);
        limit.rlim_cur = 64;
        if (setrlimit(RLIMIT_NOFILE, &limit)) _exit(92);
    }
    if (strstr(mode, "blocked")) {
        sigset_t set;
        if (signal(SIGALRM, SIG_IGN) == SIG_ERR || sigemptyset(&set) ||
            sigaddset(&set, SIGALRM) || sigprocmask(SIG_BLOCK, &set, NULL)) _exit(94);
    }
}
'''

INTERPRETER = r'''
#define _DEFAULT_SOURCE 1
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#ifdef __APPLE__
#include <netinet/in.h>
#include <netinet/tcp.h>
#endif
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    /* An alarm survives exec even though its caught handler does not. */
    if (alarm(0) != 0) return 95;
    if (argc != 13 || strcmp(argv[9], "--owned-listener") || strcmp(argv[10], "3") ||
        strcmp(argv[11], "--egress-port") || strcmp(argv[12], "54321")) return 96;
#ifdef __APPLE__
    unsigned char listening = 0; socklen_t size = sizeof(listening);
    if (getsockopt(3, IPPROTO_TCP, TCP_CONNECTION_INFO, &listening, &size) || listening != 1) return 97;
#else
    int listening = 0; socklen_t size = sizeof(listening);
    if (getsockopt(3, SOL_SOCKET, SO_ACCEPTCONN, &listening, &size) || listening != 1) return 97;
#endif
    if (fcntl(3, F_GETFD) != 0) return 97;
    for (int descriptor = 0; descriptor < 3; descriptor++) {
        struct stat node;
        if (fstat(descriptor, &node) || !S_ISFIFO(node.st_mode)) return 98;
    }
    for (int descriptor = 4; descriptor < 64; descriptor++) {
        if (fcntl(descriptor, F_GETFD) != -1 || errno != EBADF) return 98;
    }
    if (fcntl(FIXTURE_HIGH_FD, F_GETFD) != -1 || errno != EBADF) return 98;
    size_t count = 0;
    while (environ[count]) count++;
    if (count != 5 || getenv("FIXTURE_MODE") || getenv("HTTP_PROXY") ||
        getenv("SSL_CERT_FILE") || getenv("PYTHONPATH") || getenv("DOT_PRIVATE_CAPABILITY")) return 99;
    static const char result[] = "fixture_exec_ok\n";
    return write(STDOUT_FILENO, result, sizeof(result) - 1) == sizeof(result) - 1 ? 0 : 100;
}
'''


@unittest.skipUnless(os.name == "posix" and COMPILER, "POSIX C compiler required")
class BootstrapDeadlineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="dot-search-deadline-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        include = cls.root / "include"
        (include / "mach-o").mkdir(parents=True)
        (include / "mach-o/dyld.h").write_text('#include <stdint.h>\nint _NSGetExecutablePath(char *, uint32_t *);\n')
        (include / "sandbox.h").write_text('void sandbox_free_error(char *);\n')
        wrapper = cls.root / "wrapper.c"
        wrapper.write_text(WRAPPER.replace("BOOTSTRAP_SOURCE", str(SOURCE)))
        cls.binary = cls.root / "bootstrap"
        if sys.platform == "darwin":
            # Compile and link the unwrapped production translation unit with its
            # real SDK headers and production flags. Fixture headers cannot hide
            # a missing declaration or link dependency from this check.
            production = subprocess.run([
                "xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0",
                "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", str(SOURCE),
                "-o", str(cls.root / "production-bootstrap"), "-lsandbox"],
                capture_output=True, text=True, timeout=20)
            if production.returncode: raise AssertionError(production.stderr)
        compile_flags = [COMPILER, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unknown-pragmas", "-O2"]
        compiled = subprocess.run([*compile_flags, "-I", str(include), str(wrapper), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=20)
        if compiled.returncode: raise AssertionError(compiled.stderr)
        interpreter = cls.root / "interpreter.c"
        # A real inherited descriptor above both the old 64-fd check and the
        # lowered child rlimit must be closed, without touching the parent copy.
        with open(os.devnull, "rb") as decoy:
            cls.high_fd = fcntl.fcntl(decoy.fileno(), fcntl.F_DUPFD, 200)
        cls.addClassCleanup(os.close, cls.high_fd)
        interpreter.write_text(INTERPRETER.replace("FIXTURE_HIGH_FD", str(cls.high_fd)))
        cls.interpreter = cls.root / "interpreter"
        subprocess.run([*compile_flags, str(interpreter), "-o", str(cls.interpreter)],
                       check=True, capture_output=True, timeout=20)

    @contextlib.contextmanager
    def launch(self, mode, *, full_output=False, bad_exec=False, port="54321", extra_args=()):
        with tempfile.TemporaryDirectory(dir=self.root) as temporary:
            base = Path(temporary)
            payload, state = base / "payload", base / "state"
            for path in (payload, state, payload / "bin", payload / "python", payload / "python/bin"):
                path.mkdir(mode=0o700)
            binary = payload / "bin/dot-search-bootstrap"
            shutil.copyfile(self.binary, binary); binary.chmod(0o700)
            interpreter = payload / "python/bin/python3"
            shutil.copyfile(self.interpreter, interpreter); interpreter.chmod(0o700)
            if bad_exec: interpreter.write_text("not an executable image\n")
            (payload / "dot_search.py").write_text("# fixture only\n")
            (payload / "search.sb").write_text("(version 1)\n(deny default)\n")
            output = None
            if full_output:
                read_fd, write_fd = os.pipe()
                output = (read_fd, write_fd)
                os.set_blocking(write_fd, False)
                while True:
                    try: os.write(write_fd, b"X" * 4096)
                    except BlockingIOError: break
                os.set_blocking(write_fd, True)
            decoy_r, decoy_w = os.pipe()
            process = subprocess.Popen([str(binary), "--payload", str(payload), "--state-root", str(state),
                                        "--egress-port", port, *extra_args],
                stdin=subprocess.PIPE, stdout=output[1] if output else subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(decoy_r, decoy_w, self.high_fd),
                env={**os.environ, "FIXTURE_EXECUTABLE": str(binary), "FIXTURE_MODE": mode,
                     "HTTP_PROXY": "http://forbidden.invalid", "SSL_CERT_FILE": "/forbidden",
                     "PYTHONPATH": "/forbidden", "DOT_PRIVATE_CAPABILITY": "synthetic-secret"})
            try:
                yield process
            finally:
                # Test-runner cleanup is limited to the exact fixture it launched.
                # Production has no new parent process-kill behavior.
                if process.poll() is None: process.kill(); process.wait(timeout=3)
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None: stream.close()
                for descriptor in (decoy_r, decoy_w): os.close(descriptor)
                if output:
                    for descriptor in output: os.close(descriptor)

    def wait_at(self, process, marker):
        self.assertTrue(select.select([process.stderr], [], [], 3)[0], "fixture did not reach native seam")
        self.assertEqual(os.read(process.stderr.fileno(), 1), marker)

    def assert_expired(self, process):
        start = time.monotonic()
        self.assertEqual(process.wait(timeout=3), 2)
        self.assertLess(time.monotonic() - start, 3)
        if process.stdout is not None: self.assertEqual(process.stdout.read(), b"")
        self.assertEqual(process.stderr.read(), b"")

    def test_stalled_policy_exits_with_control_still_open(self):
        with self.launch("policy_stall") as process:
            self.wait_at(process, b"P")
            self.assert_expired(process)
            self.assertFalse(process.stdin.closed)

    def test_closed_control_cannot_leave_native_policy_stuck(self):
        with self.launch("policy_stall") as process:
            self.wait_at(process, b"P")
            process.stdin.close()
            self.assert_expired(process)

    def test_inherited_blocked_and_ignored_alarm_is_replaced(self):
        with self.launch("policy_stall_blocked") as process:
            self.wait_at(process, b"P")
            self.assert_expired(process)

    def test_full_output_pipe_cannot_block_deadline_exit(self):
        with self.launch("policy_stall", full_output=True) as process:
            self.wait_at(process, b"P")
            self.assert_expired(process)

    def test_successful_exec_preserves_listener_and_only_positive_environment(self):
        for mode in ("success", "success_low_limit"):
            with self.subTest(mode=mode), self.launch(mode) as process:
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertEqual(process.stdout.read(), b"fixture_exec_ok\n")
                self.assertEqual(process.stderr.read(), b"")
            self.assertGreaterEqual(fcntl.fcntl(self.high_fd, fcntl.F_GETFD), 0)

    def test_exec_failure_full_output_is_bounded(self):
        with self.launch("success", full_output=True, bad_exec=True) as process:
            self.assert_expired(process)

    def test_ordinary_policy_failure_keeps_fixed_failure_event(self):
        with self.launch("policy_failure") as process:
            self.assertEqual(process.wait(timeout=3), 2)
            self.assertEqual(process.stdout.read(), b'{"protocol":1,"event":"failed","reason":"native_boundary_failed"}\n')
            self.assertEqual(process.stderr.read(), b"")

    def test_invalid_or_duplicate_egress_arguments_fail_without_echo(self):
        for port, extra in (("0", ()), ("01", ()), ("65536", ()), ("+1", ()),
                            ("54321", ("--egress-port", "54321")),
                            ("54321", ("--proxy-authorization", "synthetic-secret"))):
            with self.subTest(port=port, extra=extra), self.launch("success", port=port, extra_args=extra) as process:
                self.assertEqual(process.wait(timeout=3), 2)
                self.assertEqual(process.stdout.read(), b'{"protocol":1,"event":"failed","reason":"native_boundary_failed"}\n')
                self.assertEqual(process.stderr.read(), b"")


DESCRIPTOR_MODEL = r'''
#define _DEFAULT_SOURCE 1
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* Apple ABI shape for an algorithm model only; no Darwin API is emulated by
 * the real bootstrap wrapper, which uses its host's actual closure mechanism. */
struct proc_fdinfo { int32_t proc_fd; uint32_t proc_fdtype; };
#define PROC_PIDLISTFDS 1
static const char *scenario;
static int queries, closes;
static void fail(void) { printf("%d\n", closes); fflush(stdout); _Exit(2); }
static int model_close(int descriptor) {
    if (descriptor < 4 || ++closes > 3) _Exit(90);
    if (!strcmp(scenario, "close_eintr")) { errno = EINTR; return -1; }
    if (!strcmp(scenario, "close_ebadf")) { errno = EBADF; return -1; }
    if (!strcmp(scenario, "close_eio")) { errno = EIO; return -1; }
    return 0;
}
static void *model_malloc(size_t size) {
    return !strcmp(scenario, "allocation_failure") ? NULL : malloc(size);
}
static int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int capacity) {
    const int stride = (int)sizeof(struct proc_fdinfo);
    if (pid != getpid() || flavor != PROC_PIDLISTFDS || arg) _Exit(91);
    switch (queries++) {
    case 0:
        if (buffer || capacity) _Exit(92);
        if (!strcmp(scenario, "query_zero")) return 0;
        if (!strcmp(scenario, "query_negative")) return -1;
        if (!strcmp(scenario, "query_oversize")) return 1024 * 1024 + stride;
        if (!strcmp(scenario, "query_partial")) return 8 * stride - 1;
        return 8 * stride;
    case 1: {
        if (!buffer || capacity != 8 * stride) _Exit(93);
        if (!strcmp(scenario, "snapshot_zero")) return 0;
        if (!strcmp(scenario, "snapshot_negative")) return -1;
        if (!strcmp(scenario, "snapshot_full")) return capacity;
        if (!strcmp(scenario, "snapshot_overflow")) return capacity + stride;
        if (!strcmp(scenario, "snapshot_partial")) return 6 * stride - 1;
        struct proc_fdinfo entries[] = {{200, 0}, {3, 0}, {1, 0}, {800000, 0}, {0, 0}, {2, 0}};
        if (!strcmp(scenario, "snapshot_duplicate")) entries[5].proc_fd = 3;
        if (!strcmp(scenario, "snapshot_negative_fd")) entries[5].proc_fd = -1;
        if (!strcmp(scenario, "snapshot_missing_stdio")) entries[5].proc_fd = 10;
        memcpy(buffer, entries, sizeof(entries));
        return (int)sizeof(entries);
    }
    case 2: {
        if (!buffer || capacity != 5 * stride || closes != 2) _Exit(94);
        if (!strcmp(scenario, "verify_zero")) return 0;
        if (!strcmp(scenario, "verify_negative")) return -1;
        if (!strcmp(scenario, "verify_full")) return capacity;
        if (!strcmp(scenario, "verify_overflow")) return capacity + stride;
        if (!strcmp(scenario, "verify_partial")) return 4 * stride - 1;
        struct proc_fdinfo entries[] = {{3, 0}, {1, 0}, {0, 0}, {2, 0}};
        if (!strcmp(scenario, "verify_survivor")) entries[3].proc_fd = 200;
        if (!strcmp(scenario, "verify_duplicate")) entries[3].proc_fd = 3;
        if (!strcmp(scenario, "verify_negative_fd")) entries[3].proc_fd = -1;
        memcpy(buffer, entries, sizeof(entries));
        return (int)sizeof(entries);
    }
    default: _Exit(95);
    }
}
/* Select only the extracted algorithm after system headers are parsed. */
#ifndef __APPLE__
#define __APPLE__ 1
#endif
#define close model_close
#define malloc model_malloc
CLOSURE_SOURCE
int main(int argc, char **argv) {
    if (argc != 2) return 96;
    scenario = argv[1];
    close_inherited_descriptors();
    return queries == 3 && closes == 2 ? 0 : 97;
}
'''


@unittest.skipUnless(os.name == "posix" and COMPILER, "POSIX C compiler required")
class DarwinDescriptorAlgorithmModelTests(unittest.TestCase):
    """Exact production algorithm plus failure models, never native Darwin proof."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="dot-search-fd-model-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        source = SOURCE.read_text()
        begin = source.index("#ifdef __APPLE__\nstatic int descriptor_order(")
        end = source.index("/* A nonsecret decimal scalar", begin)
        harness = root / "descriptor-model.c"
        harness.write_text(DESCRIPTOR_MODEL.replace("CLOSURE_SOURCE", source[begin:end]))
        cls.binary = root / "descriptor-model"
        subprocess.run([COMPILER, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        str(harness), "-o", str(cls.binary)],
                       check=True, capture_output=True, timeout=20)

    def test_model_accepts_unsorted_complete_snapshot_and_exact_stdio_listener(self):
        result = subprocess.run([str(self.binary), "success"], capture_output=True, timeout=3)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_model_rejects_incomplete_invalid_or_failed_snapshot(self):
        cases = ("query_zero", "query_negative", "query_oversize", "query_partial",
                 "allocation_failure", "snapshot_zero", "snapshot_negative", "snapshot_full",
                 "snapshot_overflow", "snapshot_partial", "snapshot_duplicate", "snapshot_negative_fd")
        for scenario in cases:
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.binary), scenario], capture_output=True, timeout=3)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (2, b"0\n", b""))

    def test_model_does_not_retry_close_errors_or_accept_a_survivor(self):
        cases = {"close_eintr": 1, "close_ebadf": 1, "close_eio": 1, "snapshot_missing_stdio": 3,
                 **{name: 2 for name in ("verify_zero", "verify_negative", "verify_full", "verify_overflow",
                                        "verify_partial", "verify_survivor", "verify_duplicate", "verify_negative_fd")}}
        for scenario, closes in cases.items():
            with self.subTest(scenario=scenario):
                result = subprocess.run([str(self.binary), scenario], capture_output=True, timeout=3)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (2, f"{closes}\n".encode(), b""))


if __name__ == "__main__":
    unittest.main()

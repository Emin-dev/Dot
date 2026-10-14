"""Compile/run the production native deadline with build-only platform fixtures.

This exercises the actual C translation unit. Only macOS path/sandbox calls and
alarm duration are substituted in the test wrapper; no external network or
real sandbox is used. The production deadline stays fixed at ten seconds, with
no environment flag or runtime test hook. This is not native macOS acceptance.
"""
import contextlib
import os
from pathlib import Path
import select
import shutil
import subprocess
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
    if (strstr(mode, "blocked")) {
        sigset_t set;
        if (signal(SIGALRM, SIG_IGN) == SIG_ERR || sigemptyset(&set) ||
            sigaddset(&set, SIGALRM) || sigprocmask(SIG_BLOCK, &set, NULL)) _exit(94);
    }
}
'''

INTERPRETER = r'''
#define _DEFAULT_SOURCE 1
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
    for (int descriptor = 4; descriptor < 64; descriptor++) {
        if (fcntl(descriptor, F_GETFD) != -1) return 98;
    }
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
        compile_flags = [COMPILER, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unknown-pragmas", "-O2"]
        compiled = subprocess.run([*compile_flags, "-I", str(include), str(wrapper), "-o", str(cls.binary)],
                                  capture_output=True, text=True, timeout=20)
        if compiled.returncode: raise AssertionError(compiled.stderr)
        interpreter = cls.root / "interpreter.c"
        interpreter.write_text(INTERPRETER)
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
                pass_fds=(decoy_r, decoy_w),
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
        with self.launch("success") as process:
            self.assertEqual(process.wait(timeout=3), 0)
            self.assertEqual(process.stdout.read(), b"fixture_exec_ok\n")
            self.assertEqual(process.stderr.read(), b"")

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


if __name__ == "__main__":
    unittest.main()

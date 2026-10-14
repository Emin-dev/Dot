"""Portable contracts for the real Search bootstrap/profile, not Seatbelt proof."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class OwnedBootstrapContract(unittest.TestCase):
    def test_real_profile_has_only_two_exact_ipv4_tcp_endpoints(self):
        policy = re.sub(r";[^\n]*", "", (ROOT / "Resources/Search/search.sb").read_text())
        self.assertEqual(policy.count("("), policy.count(")"))
        self.assertIn("(deny default)", policy)
        self.assertEqual(policy.count("(allow network-outbound"), 1)
        self.assertEqual(policy.count("(allow network-inbound"), 1)
        self.assertEqual(policy.count("(socket-domain AF_INET)"), 2)
        self.assertIn('(local tcp (param "DOT_SEARCH_LISTENER"))', policy)
        self.assertIn('(remote tcp (param "DOT_SEARCH_EGRESS"))', policy)
        for forbidden in ("DOT_SEARCH_REMOTE_", "mach-lookup", "mDNSResponder", "resolv.conf",
                          '"/private/etc/hosts"', "network-bind", "udp", "AF_INET6",
                          '(remote tcp "*', '(local tcp "*'):
            self.assertNotIn(forbidden, policy)

    def test_real_bootstrap_keeps_path_descriptor_and_pre_python_boundary(self):
        source = (ROOT / "packaging/search/dot-search-bootstrap.c").read_text()
        self.assertEqual(source.count('"localhost:%u"'), 2)
        for required in ("canonical(argv[2], payload, true, false)", "canonical(argv[4], state, true, true)",
                         "strcmp(actual_self, expected_self)", "O_NOFOLLOW", "S_ISFIFO(control.st_mode)",
                         "S_ISFIFO(events.st_mode)", "htonl(INADDR_LOOPBACK)",
                         "socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)", "dup2(listener, 3)",
                         "fcntl(3, F_SETFD, 0)", "closefrom(4)", "arm_startup_deadline()",
                         '"--owned-listener", "3", "--egress-port", argv[6]'):
            self.assertIn(required, source)
        self.assertLess(source.index("sandbox_init_with_parameters(policy"), source.index("execve(python"))
        for forbidden in ("getaddrinfo", "freeaddrinfo", "public_ipv4", "search_addresses", "DOT_SEARCH_REMOTE_",
                          "SO_REUSEADDR", "SO_REUSEPORT", "proxy_authorization", "SSL_CERT", "HTTP_PROXY",
                          "AF_INET6", "SOCK_DGRAM"):
            self.assertNotIn(forbidden, source)

    def test_strict_real_port_parser_extracted_exactly(self):
        compiler = shutil.which("cc")
        if not compiler:
            self.skipTest("no existing portable C compiler")
        source = (ROOT / "packaging/search/dot-search-bootstrap.c").read_text()
        begin = source.index("static unsigned int parse_port(")
        end = source.index("\nint main(", begin)
        harness = ('#include <stdio.h>\n#include <stdlib.h>\n'
                   'static void fail(void) { _Exit(2); }\n' + source[begin:end] +
                   '\nint main(int argc, char **argv) { printf("%u\\n", parse_port(argc == 2 ? argv[1] : NULL)); return 0; }\n')
        with tempfile.TemporaryDirectory(prefix="dot-owned-port-contract-") as temporary:
            c, binary = Path(temporary) / "port.c", Path(temporary) / "port"
            c.write_text(harness)
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", str(c), "-o", str(binary)],
                           check=True, capture_output=True)
            for value in ("1", "80", "1024", "49152", "65535"):
                result = subprocess.run([str(binary), value], capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, (value + "\n").encode())
            for value in (None, "", "0", "00", "01", "+1", "-1", " 1", "1 ", "1x", "1.0", "65536",
                          "999999999999999999999", "１２３", "١", "1\n", "1:443"):
                result = subprocess.run([str(binary)] + ([] if value is None else [value]), capture_output=True)
                self.assertEqual(result.returncode, 2, repr(value))
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")

    def test_build_script_only_builds_unsigned_production_source(self):
        script = (ROOT / "scripts/build_search_bootstrap.sh").read_text()
        self.assertIn('"$ROOT/packaging/search/dot-search-bootstrap.c"', script)
        self.assertIn("-arch arm64", script)
        self.assertIn("-Wall -Wextra -Werror", script)
        self.assertNotIn("canary.c", script)
        self.assertNotIn("codesign", script)
        self.assertNotIn("search-acceptance.json", script)
        if sys.platform != "darwin":
            result = subprocess.run(["bash", str(ROOT / "scripts/build_search_bootstrap.sh")], capture_output=True)
            self.assertEqual(result.returncode, 77)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Portable source/fixture identity checks, never native Seatbelt acceptance."""
from pathlib import Path
import ast
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("search_proxy_canary_support", ROOT / "scripts/search_proxy_canary_support.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


class ProfileContract(unittest.TestCase):
    def test_python_parse(self):
        for relative in ("scripts/test_search_proxy_sandbox_canary.py", "scripts/test_search_proxy_bootstrap_canary.py",
                         "scripts/search_proxy_canary_support.py", "Tests/Native/search_proxy_bootstrap_probe.py"):
            ast.parse((ROOT / relative).read_text(), filename=relative)

    def test_fixture_profile_is_bounded(self):
        policy = (ROOT / "Tests/Fixtures/search_proxy_canary.sb").read_text()
        policy = re.sub(r";[^\n]*", "", policy)
        self.assertEqual(policy.count("("), policy.count(")"))
        self.assertIn("(deny default)", policy)
        self.assertEqual(policy.count("(allow network-outbound"), 1)
        self.assertEqual(policy.count("(allow network-inbound"), 1)
        self.assertIn('(remote tcp (param "DOT_SEARCH_EGRESS"))', policy)
        self.assertIn('(local tcp (param "DOT_SEARCH_LISTENER"))', policy)
        self.assertEqual(policy.count("(socket-domain AF_INET)"), 2)
        for forbidden in ("DOT_SEARCH_REMOTE_", "mach-lookup", "mDNSResponder", "resolv.conf", '"/private/etc/hosts"',
                          "network-bind", "remote udp", "AF_INET6", '(remote tcp "*', '(local tcp "*'):
            self.assertNotIn(forbidden, policy)

    def test_bootstrap_is_standalone_fixture(self):
        source = (ROOT / "Tests/Native/search-proxy-bootstrap-canary.c").read_text()
        self.assertIn("BUILD-ONLY independent", source)
        self.assertEqual(source.count('"localhost:%u"'), 2)
        self.assertIn("htonl(INADDR_LOOPBACK)", source)
        self.assertIn("socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)", source)
        self.assertLess(source.index("sandbox_init_with_parameters(policy"), source.index("execve(python"))
        self.assertIn("closefrom(4)", source)
        self.assertIn("O_NOFOLLOW", source)
        self.assertIn("arm_startup_deadline()", source)
        for forbidden in ("getaddrinfo", "freeaddrinfo", "search_addresses", "DOT_SEARCH_REMOTE_", '#include "../../packaging'):
            self.assertNotIn(forbidden, source)

    def test_all_required_probe_labels_are_present(self):
        source = (ROOT / "Tests/Native/search_proxy_bootstrap_probe.py").read_text()
        for label in ("unrelated-loopback", "other-loopback-address", "public-tcp", "private-tcp", "lan-tcp",
                      "dns-tcp-public", "dns-udp-public", "mdns-resolver-socket", "udp-egress-port",
                      "ipv6-owned-egress-port", "new-loopback-bind", "new-wildcard-bind", "new-ipv6-bind",
                      "private-file-read", "inference-file-read", "state-symlink-read", "payload-symlink-read", "shell-exec"):
            self.assertIn('"' + label + '"', source)
        self.assertIn("errno.EPERM, errno.EACCES", source)
        self.assertNotIn("getaddrinfo", source)
        self.assertIn("(3, 11, 17)", source)

    def test_exact_source_basis_is_self_contained_metadata(self):
        basis = json.loads((ROOT / "profile-bootstrap-basis.json").read_text())
        inputs = json.loads((ROOT / "canary-inputs.json").read_text())
        # Absolute research paths are provenance only. The portable package must
        # remain runnable without the author's separate, mutable staging trees.
        self.assertEqual(basis["schema"], 1)
        self.assertEqual(len(basis["files"]), 6)
        for relative, digest in basis["files"].items():
            self.assertFalse(Path(relative).is_absolute())
            self.assertNotIn("..", Path(relative).parts)
            self.assertRegex(digest, r"^[a-f0-9]{64}$")
            self.assertEqual(inputs["base_files"][relative], digest, relative)
        self.assertRegex(basis["proposal"]["sha256"], r"^[a-f0-9]{64}$")
        self.assertEqual(basis["proposal"]["sha256"], inputs["proposal_sha256"])

    @unittest.skipIf(sys.platform == "darwin", "Linux/non-macOS explicit skip contract")
    def test_native_runners_skip_77(self):
        for name in ("test_search_proxy_sandbox_canary.py", "test_search_proxy_bootstrap_canary.py"):
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / name)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 77, result.stderr.decode())
            self.assertIn(b"no native execution performed", result.stdout)

    def test_strict_port_parser_extracted_exactly(self):
        compiler = shutil.which("cc")
        if not compiler:
            self.skipTest("no existing portable C compiler")
        source = (ROOT / "Tests/Native/search-proxy-bootstrap-canary.c").read_text()
        begin = source.index("static unsigned int parse_port(")
        end = source.index("\nint main(", begin)
        harness = ('#include <stdio.h>\n#include <stdlib.h>\n'
                   'static void fail(void) { _Exit(2); }\n' + source[begin:end] +
                   '\nint main(int argc, char **argv) { printf("%u\\n", parse_port(argc == 2 ? argv[1] : NULL)); return 0; }\n')
        with tempfile.TemporaryDirectory(prefix="dot-canary-port-contract-") as temporary:
            c, binary = Path(temporary) / "port.c", Path(temporary) / "port"
            c.write_text(harness)
            subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", str(c), "-o", str(binary)], check=True, capture_output=True)
            for value in ("1", "80", "1024", "49152", "65535"):
                result = subprocess.run([str(binary), value], capture_output=True)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, (value + "\n").encode())
            for value in (None, "", "0", "00", "01", "+1", "-1", " 1", "1 ", "1x", "1.0", "65536", "999999999999999999999", "１２３", "١"):
                result = subprocess.run([str(binary)] + ([] if value is None else [value]), capture_output=True)
                self.assertEqual(result.returncode, 2, repr(value))

    def test_receipt_validation_rejects_drift_and_admission(self):
        with tempfile.TemporaryDirectory(prefix="dot-canary-payload-contract-") as temporary:
            root = Path(temporary).resolve()
            (root / "python/bin").mkdir(parents=True)
            (root / "python/bin/python3").write_bytes(b"synthetic-non-executed-interpreter")
            (root / "dot_search.py").write_bytes(b"synthetic-helper")
            (root / "evidence").mkdir()
            receipt = {"schema": 1, "status": "unaccepted-static-assembly", "native_executed": False,
                "lock_sha256": "a" * 64, "files": [{"path": name, "sha256": support.sha_file(root / name),
                "size": (root / name).stat().st_size} for name in ("dot_search.py", "python/bin/python3")]}
            receipt_path = root / "evidence/assembly-input-receipt.json"
            def write_receipt():
                receipt_path.write_text(json.dumps(receipt))
                return support.sha_file(receipt_path)
            digest = write_receipt()
            verified, evidence = support.verify_payload(root, digest)
            self.assertEqual(verified, root)
            self.assertEqual(evidence["payload_file_count"], 2)
            self.assertEqual(evidence["interpreter_sha256"], support.sha_file(root / "python/bin/python3"))
            with self.assertRaises(ValueError):
                support.verify_payload(root, "b" * 64)
            extra = root / "unrecorded"
            extra.write_text("drift")
            with self.assertRaises(ValueError):
                support.verify_payload(root, digest)
            extra.unlink()
            extra.symlink_to(root / "dot_search.py")
            with self.assertRaises(ValueError):
                support.verify_payload(root, digest)
            extra.unlink()
            (root / "search-acceptance.json").write_text("{}")
            with self.assertRaises(ValueError):
                support.verify_payload(root, digest)
            (root / "search-acceptance.json").unlink()
            receipt["status"] = "accepted"
            with self.assertRaises(ValueError):
                support.verify_payload(root, write_receipt())
            receipt["status"] = "unaccepted-static-assembly"
            receipt["files"][0]["path"] = "../outside"
            with self.assertRaises(ValueError):
                support.verify_payload(root, write_receipt())


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Portable checks for the actual inherited-listener helper handoff.
No macOS sandbox, app launch, SearXNG import, or external network is exercised.
"""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = Path(__file__).with_name("test_search_helper.py")
spec = importlib.util.spec_from_file_location("search_handoff_fixture", FIXTURE)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
search = fixture.search


def start_owned(root, listener):
    process = subprocess.Popen([sys.executable, "-I", "-B", str(Path(__file__).resolve()),
        "--supervise-owned", str(root), str(listener.fileno())], pass_fds=(listener.fileno(),),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(json.dumps(fixture.start_control()).encode() + b"\n")
    process.stdin.flush()
    return process


class NativeHandoffTests(unittest.TestCase):
    def test_exact_inherited_listener_kept_continuously_and_eof_cleans(self):
        with tempfile.TemporaryDirectory() as root:
            listener = search.owned_listener()
            address = listener.getsockname()
            process = start_owned(root, listener)
            listener.close()
            try:
                ready = fixture.read_event(process)
                self.assertEqual(ready["helper_pid"], process.pid)
                self.assertEqual(urlsplit(ready["endpoint"]).port, address[1])
                with contextlib.closing(socket.socket()) as other:
                    with self.assertRaises(OSError): other.bind(address)
                self.assertIn(b"200 OK", fixture.request(ready))
                process.stdin.close()
                self.assertEqual(fixture.read_event(process)["event"], "stopped")
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertEqual(list(Path(root).iterdir()), [])
                with self.assertRaises(OSError): socket.create_connection(address, timeout=0.2)
            finally: fixture.finish_fixture(process)

    def test_wildcard_inherited_listener_rejected_without_adoption(self):
        with tempfile.TemporaryDirectory() as root, contextlib.closing(socket.socket()) as listener:
            listener.bind(("0.0.0.0", 0)); listener.listen(4)
            process = start_owned(root, listener)
            try:
                self.assertEqual(fixture.read_event(process)["event"], "failed")
                self.assertEqual(process.wait(timeout=5), 2)
                self.assertEqual(list(Path(root).iterdir()), [])
                self.assertTrue(search.listener_is_listening(listener))
            finally: fixture.finish_fixture(process)

    def test_reuse_listener_rejected(self):
        with tempfile.TemporaryDirectory() as root, contextlib.closing(socket.socket()) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0)); listener.listen(4)
            process = start_owned(root, listener)
            try:
                self.assertEqual(fixture.read_event(process)["event"], "failed")
                self.assertEqual(process.wait(timeout=5), 2)
                self.assertEqual(list(Path(root).iterdir()), [])
            finally: fixture.finish_fixture(process)

    def test_nonlistener_descriptor_rejected(self):
        with tempfile.TemporaryDirectory() as root, contextlib.closing(socket.socket()) as listener:
            listener.bind(("127.0.0.1", 0))
            process = start_owned(root, listener)
            try:
                self.assertEqual(fixture.read_event(process)["event"], "failed")
                self.assertEqual(process.wait(timeout=5), 2)
                self.assertEqual(list(Path(root).iterdir()), [])
            finally: fixture.finish_fixture(process)

    def test_production_requires_native_descriptor_and_does_not_bind_fallback(self):
        for flags in ([], ["--owned-listener", "4"]):
            process = subprocess.run([sys.executable, "-I", "-S", "-B", str(fixture.HELPER),
                "--payload", "/fixture-missing", "--state-root", "/fixture-missing", *flags, "--egress-port", "54321"], capture_output=True, timeout=5)
            self.assertEqual(process.returncode, 2)
            self.assertEqual(json.loads(process.stdout)["reason"], "payload_unavailable")
            self.assertEqual(process.stderr, b"")



if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--supervise-owned":
        def worker(listener, bootstrap, lifeline):
            return [sys.executable, "-I", "-B", str(FIXTURE), "worker", str(listener), str(bootstrap), str(lifeline), "normal", ""]
        raise SystemExit(search.supervise(sys.argv[2], worker, listener_fd=int(sys.argv[3]), egress_port=fixture.EGRESS_PORT))
    unittest.main()

"""Strict private-frame and lifecycle contracts; no native or external query proof."""
import base64
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("private_bootstrap_search", ROOT / "Resources/Search/dot_search.py")
search = importlib.util.module_from_spec(spec)
spec.loader.exec_module(search)
GENERATION = "12345678-1234-4ABC-8DEF-123456789ABC"
GATEWAY = "a" * 64
BROKER = "b" * 64
AUTHORIZATION = "Basic " + base64.b64encode(("dot:" + BROKER).encode("ascii")).decode("ascii")
PORT = 54321


def start_frame(**changes):
    result = {"protocol": 1, "command": "start", "generation": GENERATION,
              "egress_port": PORT, "proxy_authorization": AUTHORIZATION}
    result.update(changes)
    return result


def worker_frame(**changes):
    result = {"protocol": 1, "port": 12345, "capability": GATEWAY,
              "generation": GENERATION, "egress_port": PORT, "proxy_authorization": AUTHORIZATION}
    result.update(changes)
    return result


class PrivateBootstrapTests(unittest.TestCase):
    def assert_invalid(self, call, *args):
        with self.assertRaisesRegex(search.SearchFailure, "^invalid_control$") as error:
            call(*args)
        self.assertIsNone(error.exception.__cause__)
        self.assertIsNone(error.exception.__context__)

    def test_canonical_auth_decodes_without_changing_wire_representation(self):
        self.assertEqual(len(AUTHORIZATION), 98)
        self.assertEqual(search.decode_proxy_authorization(AUTHORIZATION), BROKER)
        self.assertIsNone(search.validate_start_frame(start_frame(), PORT))
        self.assertEqual(search.validate_worker_bootstrap(worker_frame()), BROKER)

    def test_noncanonical_auth_and_wrong_token_shape_are_rejected(self):
        def basic(raw):
            return "Basic " + base64.b64encode(raw).decode("ascii")
        bad_pad_bits = AUTHORIZATION[:-2] + "J="  # Same decoded bytes, noncanonical pad bits.
        for value in (None, True, 1, b"Basic bytes", "", BROKER, AUTHORIZATION.lower(),
                      AUTHORIZATION + "\n", " " + AUTHORIZATION, AUTHORIZATION.replace("Basic ", "Basic  "),
                      AUTHORIZATION[:-1], AUTHORIZATION + "=", bad_pad_bits,
                      basic(("user:" + BROKER).encode()), basic(("dot:" + "B" * 64).encode()),
                      basic(("dot:" + "b" * 63).encode()), basic(("dot:" + "b" * 65).encode()),
                      basic(b"dot:" + b"b" * 63 + b"\x00"), "Basic " + "é" * 92):
            with self.subTest(value_type=type(value).__name__):
                self.assert_invalid(search.decode_proxy_authorization, value)

    def test_start_schema_protocol_port_generation_and_expected_port_are_exact(self):
        for key in start_frame():
            value = start_frame(); value.pop(key)
            self.assert_invalid(search.validate_start_frame, value, PORT)
        for extra in ("capability", "port", "proxy_url", "tls_verify", "fixture"):
            self.assert_invalid(search.validate_start_frame, start_frame(**{extra: "forbidden"}), PORT)
        for key, values in (
            ("protocol", [True, False, 1.0, "1", 0, 2]),
            ("command", ["START", "stop", "start\x00", True]),
            ("generation", ["", GENERATION.lower(), "fixture-generation", "{" + GENERATION + "}",
                            GENERATION + "\x00", GENERATION + "\n", "Ｆ" * 36, True]),
            ("egress_port", [True, False, 1.0, "54321", 0, -1, 65536, PORT - 1]),
            ("proxy_authorization", [GATEWAY, BROKER, AUTHORIZATION + "\n"])):
            for value in values:
                with self.subTest(key=key, value_type=type(value).__name__):
                    self.assert_invalid(search.validate_start_frame, start_frame(**{key: value}), PORT)
        for expected in (None, True, 1.0, "54321", 0, 65536, PORT - 1):
            self.assert_invalid(search.validate_start_frame, start_frame(), expected)
        for invalid in (None, [], True, "frame"):
            self.assert_invalid(search.validate_start_frame, invalid, PORT)

    def test_worker_schema_inbound_capability_and_two_ports_are_exact(self):
        for key in worker_frame():
            value = worker_frame(); value.pop(key)
            self.assert_invalid(search.validate_worker_bootstrap, value)
        for key, values in (
            ("protocol", [True, 1.0, "1"]),
            ("port", [True, 1.0, "12345", 0, -1, 65536, PORT]),
            ("capability", [None, True, "a" * 63, "A" * 64, GATEWAY + "\n", BROKER]),
            ("generation", [GENERATION.lower(), GENERATION + "\x00"]),
            ("egress_port", [True, "54321", 0, 65536]),
            ("proxy_authorization", [GATEWAY, BROKER])):
            for value in values:
                with self.subTest(key=key, value_type=type(value).__name__):
                    self.assert_invalid(search.validate_worker_bootstrap, worker_frame(**{key: value}))
        self.assert_invalid(search.validate_worker_bootstrap, worker_frame(extra="forbidden"))
        for invalid in (None, [], True, "frame"):
            self.assert_invalid(search.validate_worker_bootstrap, invalid)

    def test_duplicate_keys_and_nonfinite_constants_have_no_legacy_fallback(self):
        for frame in (start_frame(), worker_frame()):
            wire = json.dumps(frame, separators=(",", ":"))
            for key, value in frame.items():
                duplicate = wire[:-1] + "," + json.dumps(key) + ":" + json.dumps(value) + "}"
                with self.assertRaisesRegex(ValueError, "^invalid_json$"):
                    search.strict_json(duplicate)
        for text in ('{"protocol":NaN}', '{"protocol":Infinity}', '{"protocol":-Infinity}'):
            with self.assertRaisesRegex(ValueError, "^invalid_json$"):
                search.strict_json(text)

    def test_cli_egress_parser_matches_native_canonical_scalar(self):
        for value in ("1", "80", "1024", "54321", "65535"):
            self.assertEqual(search.parse_egress_port(value), int(value))
        for value in (None, True, 1, "", "0", "01", "+1", "-1", " 1", "1 ", "1x", "1.0", "65536",
                      "999999999999999999999", "１２３", "١", "1\n"):
            self.assert_invalid(search.parse_egress_port, value)

    def test_settings_contain_only_nonsecret_proxy_and_strict_transport_policy(self):
        settings = search.settings_text(12345, "c" * 64, PORT)
        self.assertIn('all://: "http://127.0.0.1:54321"', settings)
        for setting in ("pool_connections: 1", "verify: true", "retries: 0", "max_redirects: 0",
                        "extra_proxy_timeout: 0", "request_timeout: 8.0", "max_request_timeout: 12.0"):
            self.assertIn(setting, settings)
        self.assertNotIn(AUTHORIZATION, settings)
        self.assertNotIn(BROKER, settings)
        self.assertNotIn(GATEWAY, settings)
        self.assertNotIn(GENERATION, settings)
        self.assertNotIn("http://dot:", settings)


class PrivateSupervisorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "Tests/Python/test_search_helper.py"
        spec = importlib.util.spec_from_file_location("private_supervisor_fixture", path)
        cls.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.fixture)
        cls.fixture_path = path

    def test_bad_start_frame_never_creates_state_or_launches_a_worker(self):
        controls = [start_frame(extra="forbidden"), start_frame(egress_port=PORT - 1),
                    start_frame(protocol=True), start_frame(proxy_authorization=BROKER),
                    {"protocol": 1, "command": "start", "generation": GENERATION}]
        for control in controls:
            with self.subTest(keys=sorted(control)), tempfile.TemporaryDirectory() as root:
                process = subprocess.Popen([sys.executable, "-I", "-B", str(self.fixture_path),
                    "supervisor", root, "normal", ""], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    process.stdin.write(json.dumps(control).encode() + b"\n"); process.stdin.flush()
                    event = self.fixture.read_event(process)
                    self.assertEqual(event, {"protocol": 1, "event": "failed", "generation": None,
                                             "reason": "invalid_control"})
                    self.assertEqual(process.wait(timeout=5), 2)
                    self.assertEqual(list(Path(root).iterdir()), [])
                    self.assertEqual(process.stderr.read(), b"")
                finally:
                    self.fixture.finish_fixture(process)

    def test_malformed_duplicate_and_oversized_private_frames_fail_before_worker(self):
        good = json.dumps(self.fixture.start_control(), separators=(",", ":")).encode()
        controls = [good[:-1] + b',"protocol":1}\n', b'{"protocol":NaN}\n',
                    b'{"bad":"' + b"x" * search.MAX_CONTROL + b'"}\n', b'{not-json}\n']
        for control in controls:
            with self.subTest(size=len(control)), tempfile.TemporaryDirectory() as root:
                process = subprocess.Popen([sys.executable, "-I", "-B", str(self.fixture_path),
                    "supervisor", root, "normal", ""], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    process.stdin.write(control); process.stdin.flush()
                    event = self.fixture.read_event(process)
                    self.assertEqual(event["event"], "failed")
                    self.assertIsNone(event["generation"])
                    self.assertIn(event["reason"], ("startup_failed", "invalid_control"))
                    self.assertEqual(process.wait(timeout=5), 2)
                    self.assertEqual(list(Path(root).iterdir()), [])
                    self.assertEqual(process.stderr.read(), b"")
                finally:
                    self.fixture.finish_fixture(process)

    def test_serving_requires_exact_schema_protocol_and_same_generation(self):
        for mode in ("stale_generation", "extra_serving", "boolean_protocol", "missing_generation"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as root:
                process = self.fixture.start_fixture(root, mode)
                try:
                    self.assertEqual(self.fixture.read_event(process), {"protocol": 1, "event": "failed",
                        "generation": GENERATION, "reason": "invalid_worker"})
                    self.assertEqual(process.wait(timeout=5), 2)
                    self.assertEqual(list(Path(root).iterdir()), [])
                    self.assertEqual(process.stderr.read(), b"")
                finally:
                    self.fixture.finish_fixture(process)

    def test_private_worker_handoff_keeps_broker_auth_out_of_ready_files_and_environment(self):
        with tempfile.TemporaryDirectory() as root:
            process = self.fixture.start_fixture(root)
            try:
                ready = self.fixture.read_event(process)
                self.assertEqual(ready["event"], "ready")
                self.assertEqual(set(ready), {"protocol", "event", "generation", "endpoint", "capability",
                                             "helper_pid", "server_pid"})
                self.assertNotEqual(ready["capability"], self.fixture.BROKER_TOKEN)
                for secret in (self.fixture.BROKER_TOKEN, self.fixture.PROXY_AUTHORIZATION):
                    self.assertNotIn(secret, json.dumps(ready))
                    for path in Path(root).rglob("*"):
                        if path.is_file(): self.assertNotIn(secret.encode(), path.read_bytes())
                # The fixture worker itself checked actual argv/environment and
                # pipe bootstrap before emitting its same-generation serving.
                self.assertIn(b"200 OK", self.fixture.request(ready))
                self.assertIn(b"403 Forbidden", self.fixture.request(ready, token=self.fixture.BROKER_TOKEN))
                process.stdin.close()
                self.assertEqual(self.fixture.read_event(process), {"protocol": 1, "event": "stopped",
                                                                    "generation": GENERATION})
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertEqual(list(Path(root).iterdir()), [])
                self.assertEqual(process.stderr.read(), b"")
            finally:
                self.fixture.finish_fixture(process)

    def test_cli_rejects_duplicate_alias_extra_or_malformed_scalar_without_echo(self):
        good = ["--payload", "/fixture", "--state-root", "/fixture-state", "--owned-listener", "3", "--egress-port", "54321"]
        cases = [good + ["--egress-port", "54321"], good + ["--proxy-authorization", AUTHORIZATION],
                 ["--pay", *good[1:]], [*good[:-1], "01"], [*good[:-1], "54321\n"],
                 [*good[:-2]], ["--serve", "3", "4", "5", "--egress-port", "54321"]]
        for arguments in cases:
            result = subprocess.run([sys.executable, "-I", "-S", "-B", str(ROOT / "Resources/Search/dot_search.py"),
                                     *arguments], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'{"protocol":1,"event":"failed","reason":"payload_unavailable"}\n')
            self.assertEqual(result.stderr, b"")

    def test_worker_activation_follows_validation_and_initialization_before_serving(self):
        # Syntax ordering is a portable guard, not pinned-library/native proof.
        import ast
        tree = ast.parse((ROOT / "Resources/Search/dot_search.py").read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "serve_production")
        calls = {node.func.id: node.lineno for node in ast.walk(function)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        initialized = next(node.lineno for node in ast.walk(function)
                           if isinstance(node, ast.ImportFrom) and node.module == "searx.webapp")
        self.assertLess(calls["validate_worker_bootstrap"], calls["adopt_listener"])
        self.assertLess(calls["adopt_listener"], initialized)
        self.assertLess(initialized, calls["install_private_ddg_processor"])
        self.assertLess(calls["install_private_ddg_processor"], calls["create_server"])
        self.assertLess(calls["create_server"], calls["send_event"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

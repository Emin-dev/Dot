"""Finite stdlib call-shape contracts; these stubs are NOT native wire proof."""
import ast
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("dot_private_auth_test", ROOT / "Resources/Search/dot_search.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
TOKEN = "a" * 64


class RequestException(Exception):
    def __init__(self, message, code=0, response=None):
        super().__init__(message)
        self.code, self.response = code, response


class Timeout(RequestException):
    pass


class OnlineProcessor:
    def __init__(self, engine):
        self.engine = engine


class PrivateAuthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        path = Path(self.tmp.name) / "synthetic-engine.py"
        path.write_text("# explicitly synthetic portable shape test\n")
        self.engine = types.SimpleNamespace(name="duckduckgo", __file__=str(path),
            _HTTP_User_Agent="Synthetic pinned agent", quote_ddg_bangs=lambda q: " ".join(q.split()),
            traits=types.SimpleNamespace(all_locale="wt-wt", get_region=lambda locale, fallback: fallback))
        self.network = types.SimpleNamespace(verify=True, enable_http=False, enable_http3=False,
            retries=0, max_redirects=0, max_connections=1, using_tor_proxy=False,
            retry_on_http_error=False, local_addresses=None,
            proxies={"all://": "http://127.0.0.1:23456"}, _clients={})
        self.engines = {"duckduckgo": self.engine}
        self.processors = {"duckduckgo": OnlineProcessor(self.engine)}
        self.post = mock.Mock(return_value=types.SimpleNamespace(status_code=200))
        modules = {name: types.ModuleType(name) for name in (
            "searx", "searx.network", "searx.engines", "searx.search", "searx.search.processors",
            "searx.search.processors.online", "curl_cffi", "curl_cffi.requests", "curl_cffi.requests.exceptions")}
        modules["searx"].network = modules["searx.network"]
        modules["searx.network"].get_network = lambda name: self.network
        modules["searx.network"].post = self.post
        modules["searx.engines"].engines = self.engines
        modules["searx.search.processors"].PROCESSORS = self.processors
        modules["searx.search.processors.online"].OnlineProcessor = OnlineProcessor
        modules["curl_cffi"].CurlOpt = types.SimpleNamespace(PROXYAUTH=111)
        modules["curl_cffi.requests.exceptions"].RequestException = RequestException
        modules["curl_cffi.requests.exceptions"].Timeout = Timeout
        self.modules_patch = mock.patch.dict(sys.modules, modules)
        self.modules_patch.start()
        self.addCleanup(self.modules_patch.stop)
        pin = mock.patch.object(helper, "DDG_TRANSIENT_SHA256", hashlib.sha256(path.read_bytes()).hexdigest())
        pin.start()
        self.addCleanup(pin.stop)

    def params(self):
        return {"method": "POST", "url": helper.DDG_REQUEST_URL,
            "headers": {"User-Agent": self.engine._HTTP_User_Agent, "Sec-Fetch-Dest": "document",
                "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "same-origin", "Sec-Fetch-User": "?1",
                "Referer": helper.DDG_REQUEST_URL, "Content-Type": "application/x-www-form-urlencoded",
                "Accept-Language": "en-US,en;q=0.9"},
            "data": {"q": "synthetic query", "b": "", "kl": "wt-wt"}, "cookies": {},
            "json": {}, "content": b"", "allow_redirects": False, "max_redirects": 0,
            "soft_max_redirects": 0, "auth": None, "verify": None, "raise_for_httperror": True,
            "query": "synthetic query", "category": "general", "pageno": 1, "safesearch": 1,
            "time_range": None, "engine_data": {}, "searxng_locale": "all", "language": "all"}

    def install(self):
        return helper.install_private_ddg_processor(TOKEN, 23456)

    def test_exact_per_request_call_and_original_params_unchanged(self):
        original = self.params()
        before = copy.deepcopy(original)
        old = self.processors["duckduckgo"]
        processor = self.install()
        self.assertIs(self.processors["duckduckgo"], processor)
        self.assertIs(type(old), OnlineProcessor)
        self.assertIs(type(processor).__bases__[0], OnlineProcessor)
        processor._send_http_request(original)
        self.post.assert_called_once_with(helper.DDG_REQUEST_URL, data=before["data"],
            headers=before["headers"], cookies={}, auth=None, proxy_auth=("dot", TOKEN),
            curl_options={111: 1}, allow_redirects=False, max_redirects=0, raise_for_httperror=True)
        self.assertEqual(original, before)
        self.assertNotIn(TOKEN, repr(original))
        self.assertEqual(self.network._clients, {})

    def test_processor_cannot_switch_engine_identity_after_registration(self):
        processor = self.install()
        processor.engine = types.SimpleNamespace(name="duckduckgo")
        with self.assertRaisesRegex(helper.SearchFailure, "^engine_boundary_failed$"):
            processor._send_http_request(self.params())
        self.post.assert_not_called()

    def test_second_and_concurrent_attempts_cannot_reuse_generation(self):
        processor = self.install()
        entered, release = threading.Event(), threading.Event()
        def block(*args, **kwargs):
            entered.set()
            self.assertTrue(release.wait(2))
        self.post.side_effect = block
        thread = threading.Thread(target=processor._send_http_request, args=(self.params(),))
        thread.start()
        try:
            self.assertTrue(entered.wait(2))
            with self.assertRaisesRegex(RequestException, "^dot_proxy_generation_consumed$"):
                processor._send_http_request(self.params())
        finally:
            release.set()
            thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.post.call_count, 1)

    def test_transport_normalization_has_no_original_chain_or_message(self):
        class LeakingError(Exception):
            def __str__(self):
                raise AssertionError("original exception was stringified")
        for original, expected, code in ((LeakingError(TOKEN), RequestException, 0),
                (Timeout(TOKEN), Timeout, 28), (RuntimeError(TOKEN), RequestException, 0)):
            with self.subTest(kind=type(original).__name__):
                self.processors["duckduckgo"] = OnlineProcessor(self.engine)
                processor = self.install()
                self.post.side_effect = original
                with self.assertRaises(expected) as caught:
                    processor._send_http_request(self.params())
                error = caught.exception
                self.assertIsNone(error.__cause__)
                self.assertIsNone(error.__context__)
                self.assertIsNone(error.response)
                self.assertEqual(error.code, code)
                self.assertEqual(str(error), "dot_proxy_timeout" if code else "dot_proxy_transport_failed")
                self.assertNotIn(TOKEN, json.dumps({"error": str(error), "args": error.args, "code": error.code}))

    def test_rejects_transport_overrides_before_any_call(self):
        mutations = [lambda p, k=k: p.update({k: "arbitrary"}) for k in
            ("proxy", "proxies", "proxy_auth", "curl_options", "impersonate", "default_headers", "timeout", "stream")]
        mutations += [lambda p, k=k, v=v: p.update({k: v}) for k, v in (
            ("url", "https://elsewhere.invalid/"), ("method", "GET"), ("pageno", 2), ("pageno", True),
            ("auth", ("dot", TOKEN)), ("verify", False), ("verify", "/fixture/ca"),
            ("json", {"q": "x"}), ("content", b"x"), ("allow_redirects", True), ("max_redirects", 1),
            ("soft_max_redirects", 1), ("raise_for_httperror", False), ("time_range", "day"),
            ("engine_data", {"vqd": "x"}), ("language", "different"), ("category", "images"))]
        mutations += [lambda p, k=k: p["headers"].update({k: "secret"}) for k in
            ("Authorization", "authorization", "Proxy-Authorization", "PROXY-AUTHORIZATION", "Host", "Cookie")]
        mutations += [lambda p: p["headers"].update({"Accept-Language": "en\r\nAuthorization: x"}),
            lambda p: p["data"].update({"vqd": "x"}), lambda p: p["data"].update({"q": "changed"}),
            lambda p: p["cookies"].update({"unexpected": "x"}), lambda p: p.pop("verify")]
        for number, mutate in enumerate(mutations):
            with self.subTest(case=number):
                self.processors["duckduckgo"] = OnlineProcessor(self.engine)
                params = self.params()
                mutate(params)
                with self.assertRaises(helper.SearchFailure):
                    self.install()._send_http_request(params)
        self.post.assert_not_called()

    def test_registration_rejects_bad_capability_port_engine_and_existing_clients(self):
        for cap, port in (("a" * 63, 23456), (TOKEN, True), (TOKEN, 0), (TOKEN, 65536), (None, 23456)):
            with self.assertRaises(helper.SearchFailure):
                helper.install_private_ddg_processor(cap, port)
        for attribute, value in (("verify", False), ("enable_http", True), ("enable_http3", True),
                ("retries", 1), ("max_redirects", 1), ("max_connections", 2),
                ("using_tor_proxy", True), ("retry_on_http_error", True),
                ("proxies", {"all://": "http://dot:" + TOKEN + "@127.0.0.1:23456"}), ("_clients", {"old": object()})):
            with self.subTest(policy=attribute):
                before = getattr(self.network, attribute)
                setattr(self.network, attribute, value)
                with self.assertRaises(helper.SearchFailure):
                    self.install()
                setattr(self.network, attribute, before)
        self.engine.init = lambda: True
        with self.assertRaises(helper.SearchFailure):
            self.install()
        del self.engine.init
        self.engines["other"] = self.engine
        with self.assertRaises(helper.SearchFailure):
            self.install()
        del self.engines["other"]
        self.install()
        with self.assertRaises(helper.SearchFailure):
            self.install()

    def test_activation_follows_private_validation_and_exact_policy_without_global_patch(self):
        source = (ROOT / "Resources/Search/dot_search.py").read_text()
        tree = ast.parse(source)
        serve = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "serve_production")
        direct = {node.value.func.id: node.lineno for node in serve.body
                  if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                  and isinstance(node.value.func, ast.Name)}
        calls = {node.func.id: node.lineno for node in ast.walk(serve)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        initialized = next(node.lineno for node in serve.body
                           if isinstance(node, ast.ImportFrom) and node.module == "searx.webapp")
        engine_pin = next(node.lineno for node in serve.body
                          if isinstance(node, ast.If) and "DDG_TRANSIENT_SHA256" in ast.unparse(node.test))
        self.assertLess(calls["validate_worker_bootstrap"], initialized)
        self.assertLess(initialized, engine_pin)
        self.assertLess(engine_pin, direct["install_private_ddg_processor"])
        self.assertLess(direct["install_private_ddg_processor"], calls["create_server"])
        self.assertLess(calls["create_server"], direct["send_event"])
        self.assertEqual(sum(isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                             and node.func.id == "install_private_ddg_processor" for node in ast.walk(serve)), 1)
        factory = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                       and node.name == "install_private_ddg_processor")
        policy = next(node for node in factory.body if isinstance(node, ast.If)
                      and "network._clients" in ast.unparse(node.test))
        registration = next(node for node in factory.body if isinstance(node, ast.Assign)
                            and any(ast.unparse(target) == "PROCESSORS['duckduckgo']" for target in node.targets))
        self.assertLess(policy.lineno, registration.lineno)
        for required in ("network.verify", "network.enable_http3", "network.retries", "network.max_redirects",
                         "network.max_connections", "network.proxies"):
            self.assertIn(required, ast.unparse(policy.test))
        assignments = [ast.unparse(target) for node in ast.walk(tree)
                       if isinstance(node, ast.Assign) for target in node.targets]
        self.assertNotIn("searx.network.post", assignments)
        self.assertNotIn("OnlineProcessor._send_http_request", assignments)


if __name__ == "__main__":
    unittest.main()

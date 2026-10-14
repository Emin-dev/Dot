#!/usr/bin/env python3
"""Native-only pinned curl/SearXNG transport proof against offline fixtures.

No request monkeypatch, no live DNS/TLS/provider, no production receipt. The
client runs under the independent candidate profile. The Python endpoint and
TLS trust file are BUILD-ONLY test seams, not a production broker or CA change.
"""
from __future__ import annotations
import argparse
import asyncio
import importlib.metadata
import importlib.util
import json
import logging
import os
from pathlib import Path
import platform
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
# Isolated invocation intentionally adds only this known build-fixture directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from search_proxy_fixture_support import (AUTHORITY, HOST, UP_CAP, DOWN_CAP, MAX_AUTH_CONNECTS,
    ConnectEndpoint, TLSOrigin, contains_proxy_credential, create_certificates, digest, settle)
POISON = {"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
          "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP"}


class CanaryFailure(RuntimeError):
    """Only fixture-authored, capability-free diagnostic text."""


def require_native(payload):
    if sys.platform != "darwin" or platform.machine() != "arm64":
        print("SKIP: pinned Search transport canary requires native macOS arm64; no native evidence")
        raise SystemExit(77)
    if sys.version_info[:3] != (3, 11, 17) or Path(sys.executable).resolve() != payload / "python/bin/python3":
        raise CanaryFailure("exact independent Search CPython 3.11.17 required")
    if not (sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode):
        raise CanaryFailure("isolated no-site no-bytecode invocation required")
    if POISON.intersection(os.environ):
        raise CanaryFailure("invoking-shell contamination survived clean launch")



def secret_in_structure(value, credential):
    """Test-only booleans; never serialize keys, request objects or credentials."""
    if isinstance(value, str):
        return contains_proxy_credential(value.encode(), credential)
    if isinstance(value, bytes):
        return contains_proxy_credential(value, credential)
    if isinstance(value, dict):
        return any(secret_in_structure(key, credential) or secret_in_structure(item, credential)
                   for key, item in value.items())
    if isinstance(value, (tuple, list)):
        return any(secret_in_structure(item, credential) for item in value)
    return False


def client_policy(network, proxy, credential):
    from curl_cffi import CurlOpt
    expected_options = {CurlOpt.PROXYAUTH: 1, CurlOpt.PROTOCOLS_STR: "https",
                        CurlOpt.REDIR_PROTOCOLS_STR: "https"}
    if network.proxies != {"all://": proxy}:
        raise CanaryFailure("nonsecret network proxy policy changed")
    for key, client in network._clients.items():
        if (secret_in_structure(key, credential) or key[5] != ((int(CurlOpt.PROXYAUTH), 1),)
                or client.proxy_auth is not None or client.auth is not None
                or client.proxies != {"all": proxy} or client.curl_options != expected_options):
            raise CanaryFailure("credential retention or unexpected cached client policy")
    return {"cache_keys_credential_free": True, "client_auth_defaults_absent": True,
            "client_options_constant_nonsecret": True, "client_proxy_urls_nonsecret": True,
            "cached_client_count": len(network._clients)}


def assert_origin_request(raw, credential):
    header, body = raw.split(b"\r\n\r\n", 1)
    lines = header.split(b"\r\n")
    if lines[0] != b"POST /html/ HTTP/1.1":
        raise CanaryFailure("origin request target or method changed")
    fields = [line.split(b":", 1) for line in lines[1:]]
    hosts = [value.strip() for name, value in fields if name.lower() == b"host"]
    if hosts != [HOST.encode()] or any(name.lower() in (b"authorization", b"proxy-authorization") for name, _ in fields):
        raise CanaryFailure("unexpected origin host or authentication header")
    if contains_proxy_credential(header + body, credential):
        raise CanaryFailure("proxy credential reached origin")


def worker(args):
    payload = args.payload.resolve(strict=True)
    require_native(payload)
    site = payload / "python/lib/python3.11/site-packages"
    if not site.is_dir() or list(site.glob("*.pth")):
        raise CanaryFailure("unexpected site initialization")
    sys.path.insert(0, str(site))
    state = Path(args.state).resolve(strict=True)
    frame = sys.stdin.buffer.readline(1025)
    if len(frame) > 1024 or not frame.endswith(b"\n"):
        raise CanaryFailure("invalid fixture start frame")
    data = json.loads(frame)
    capability = data["capability"]
    if set(data) != {"capability"} or len(capability) != 64 or any(c not in "0123456789abcdef" for c in capability):
        raise CanaryFailure("invalid fixture capability")
    nonsecret_proxy = "http://127.0.0.1:" + str(args.port)
    settings = state / "settings.yml"
    settings.write_text('''use_default_settings:
  engines:
    keep_only: [duckduckgo]
plugins: {}
general:
  debug: false
  enable_metrics: false
server:
  secret_key: "synthetic-build-only-key-not-production"
  limiter: false
  public_instance: false
  image_proxy: false
outgoing:
  request_timeout: 8.0
  max_request_timeout: 12.0
  extra_proxy_timeout: 0
  pool_connections: 1
  verify: true
  max_redirects: 0
  retries: 0
  proxies:
    all://: "''' + nonsecret_proxy + '"\n')
    os.environ["SEARXNG_SETTINGS_PATH"] = str(settings)
    logging.disable(logging.CRITICAL)
    import searx
    if "searx.network" in sys.modules or "searx.webapp" in sys.modules:
        raise CanaryFailure("pinned initialization order changed")
    outgoing = searx.settings["outgoing"]
    if outgoing["proxies"] != {"all://": nonsecret_proxy}:
        raise CanaryFailure("unexpected proxy configuration")
    import searx.network
    from searx.network.client import get_loop
    from searx.network.network import NETWORKS
    from curl_cffi import CurlOpt
    helper_layer = args.scenario.startswith("helper-")
    processor = None
    params = None
    if helper_layer:
        # Load the exact new HOST helper copied into this private state. Never
        # accidentally test the historical helper inside the locked payload.
        helper_path = state / "dot_search_host.py"
        if digest(helper_path) != args.helper_sha256:
            raise CanaryFailure("host helper fixture identity mismatch")
        spec = importlib.util.spec_from_file_location("dot_search_host", helper_path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        import searx.search
        searx.search.initialize(check_network=False, enable_metrics=False)
        processor = helper.install_private_ddg_processor(capability, args.port)
        network = searx.network.get_network("duckduckgo")
        query = SimpleNamespace(query="build-only-synthetic-query", pageno=1, safesearch=1,
            time_range=None, engine_data={}, lang="all", locale=None)
        params = processor.get_params(query, "general")
        if params is None:
            raise CanaryFailure("pinned processor rejected fixed fixture search")
    else:
        # Actual pinned initialization and public request interface. Empty registry
        # marker prevents initializing unrelated engine clients; no transport patch.
        searx.network.initialize(settings_engines=[{"name": "dot-unloaded-fixture"}], settings_outgoing=outgoing)
        network = searx.network.get_network()
    if (network.verify is not True or network.enable_http or network.retries != 0 or
            network.max_redirects != 0 or network.max_connections != 1 or network.enable_http3):
        raise CanaryFailure("network policy differs from the reviewed settings")
    before_policy = client_policy(network, nonsecret_proxy, capability.encode())
    # BUILD-ONLY trust seam on the actual fixture network. The helper API accepts
    # no CA override. Registration above had to observe production verify=True.
    if helper_layer:
        network.verify = str(args.ca)
    start = time.monotonic()
    outcomes = []
    try:
        for _ in range(2 if args.scenario == "consecutive" else 1):
            try:
                if args.scenario == "helper-result-error":
                    from searx.results import ResultContainer
                    from searx.metrics.error_recorder import errors_per_engines
                    container = ResultContainer()
                    processor.search(query.query, params, container, time.monotonic(), 8.0)
                    errors = [(item.engine, item.error_type, item.suspended)
                              for item in container.unresponsive_engines]
                    if (errors != [("duckduckgo", "curl_cffi.requests.exceptions.RequestException", False)]
                            or errors_per_engines or secret_in_structure(params, capability.encode())
                            or secret_in_structure(errors, capability.encode())):
                        raise CanaryFailure("pinned result or disabled-metric error path changed")
                    outcomes.append({"error_type": "RequestException", "result_error_class_fixed": True,
                        "result_and_search_params_credential_free": True, "metrics_remained_empty": True})
                elif helper_layer:
                    processor.init_network_in_thread(time.monotonic(), 8.0)
                    parsed = processor._search_basic(query.query, params)
                    if (len(parsed) != 1 or parsed[0].title != "Synthetic result"
                            or parsed[0].url != "https://example.org/fixture"):
                        raise CanaryFailure("actual pinned DDG parser did not produce fixture result")
                    if secret_in_structure(params, capability.encode()):
                        raise CanaryFailure("capability reached original search params")
                    outcomes.append({"status": 200, "parsed_result_count": len(parsed),
                        "parsed_result_is_fixture": True, "original_search_params_credential_free": True})
                else:
                    response = searx.network.request("post", "https://" + HOST + "/html/",
                        data={"q": "build-only-synthetic-query"}, timeout=8,
                        auth=None, proxy_auth=("dot", capability), curl_options={CurlOpt.PROXYAUTH: 1},
                        allow_redirects=False, max_redirects=0, verify=str(args.ca))
                    request = response.request
                    request_fields = {"url": request.url, "method": request.method,
                        "headers": dict(request.headers.items()), "body": request.body}
                    if (secret_in_structure(request_fields, capability.encode())
                            or any(name.lower() in ("authorization", "proxy-authorization")
                                   for name in request_fields["headers"])):
                        raise CanaryFailure("proxy credential reached request object")
                    outcomes.append({"status": response.status_code, "body_bytes": len(response.content),
                                     "body_is_fixture": response.content == b"fixture",
                                     "request_object_credential_free": True})
            except CanaryFailure:
                raise
            except Exception as error:
                if helper_layer:
                    from curl_cffi.requests.exceptions import RequestException, Timeout
                    expected = "dot_proxy_timeout" if type(error) is Timeout else "dot_proxy_transport_failed"
                    expected_code = 28 if type(error) is Timeout else 0
                    if (type(error) not in (RequestException, Timeout) or error.args != (expected,)
                            or error.code != expected_code or error.response is not None
                            or error.__cause__ is not None or error.__context__ is not None):
                        raise CanaryFailure("helper exception was not fixed and unchained") from None
                    outcomes.append({"error_type": type(error).__name__, "curl_code": expected_code,
                        "normalized_error": expected, "original_exception_chain_absent": True})
                else:
                    # Transport-only layer reports no exception text or object.
                    outcomes.append({"error_type": type(error).__name__, "curl_code": int(getattr(error, "code", 0))})
        after_policy = client_policy(network, nonsecret_proxy, capability.encode())
    finally:
        asyncio.run_coroutine_threadsafe(network.aclose(), get_loop()).result(timeout=3)
        # Unused initialized networks own no clients but are explicitly closed.
        for item in NETWORKS.values():
            asyncio.run_coroutine_threadsafe(item.aclose(), get_loop()).result(timeout=3)
    closed_policy = client_policy(network, nonsecret_proxy, capability.encode())
    if capability in settings.read_text():
        raise CanaryFailure("fixture capability persisted to settings")
    print(json.dumps({"outcomes": outcomes, "elapsed": time.monotonic() - start,
        "clean_environment": True, "initialization_order_verified": True,
        "proof_layer": "actual-helper-pinned-ddg-search-basic" if helper_layer else "pinned-network-transport",
        "helper_source_sha256": args.helper_sha256 if helper_layer else None,
        "client_policy_before": before_policy, "client_policy_after": after_policy,
        "client_policy_closed": closed_policy,
        "searx_request_monkeypatched": False, "curl_cffi_version": importlib.metadata.version("curl-cffi")}))


def probe(payload, lock, pins):
    site = payload / "python/lib/python3.11/site-packages"
    if not site.is_dir() or list(site.glob("*.pth")):
        raise CanaryFailure("unexpected site initialization")
    for relative, expected in pins["files"].items():
        if digest(site / relative) != expected:
            raise CanaryFailure("pinned transport source mismatch: " + relative)
    sys.path.insert(0, str(site))
    for package in lock["wheels"]:
        if importlib.metadata.version(package["name"]) != package["version"]:
            raise CanaryFailure("pinned dependency version mismatch: " + package["name"])
    if lock["searxng"]["revision"] != pins["searxng_revision"]:
        raise CanaryFailure("SearXNG revision mismatch")
    if digest(site / "searx/engines/duckduckgo.py") != lock["searxng"]["transient_patch"]["patched_sha256"]:
        raise CanaryFailure("pinned DDG transient patch mismatch")
    import curl_cffi
    import certifi
    if not ssl.OPENSSL_VERSION.startswith("OpenSSL 3.5.9 "):
        raise CanaryFailure("bundled OpenSSL mismatch")
    cert = Path(certifi.where()).resolve(strict=True)
    if not cert.is_relative_to(payload):
        raise CanaryFailure("bundled CA escaped payload")
    curl = curl_cffi.Curl()
    try:
        version = curl.version().decode()
    finally:
        curl.close()
    return {"python": platform.python_version(), "openssl": ssl.OPENSSL_VERSION,
            "curl": version, "curl_cffi": importlib.metadata.version("curl-cffi"),
            "bundled_ca_sha256": digest(cert), "pinned_sources": pins}


def run(args):
    payload = args.payload.resolve(strict=True)
    require_native(payload)
    sys.path.insert(0, str(ROOT / "scripts"))
    from search_proxy_canary_support import verify_payload, verify_source_lock, fixture_hashes, native_host_identity
    payload, identity = verify_payload(payload, args.expected_receipt_sha256)
    report = args.report.resolve()
    if report.exists() or report.is_relative_to(payload):
        raise CanaryFailure("report must be new and outside payload")
    lock_path = args.lock.resolve(strict=True)
    lock, lock_identity = verify_source_lock(lock_path, identity["assembly_lock_sha256"])
    pins_path = ROOT / "Tests/Fixtures/search_proxy_pinned_hashes.json"
    pins = json.loads(pins_path.read_text())
    details = probe(payload, lock, pins)
    sources = ["Tests/Fixtures/search_proxy_transport_fixture.py", "Tests/Fixtures/search_proxy_fixture_support.py",
               "Tests/Fixtures/search_proxy_pinned_hashes.json", "Tests/Fixtures/search_proxy_canary.sb",
               "scripts/search_proxy_canary_support.py", "scripts/verify_search_proxy_native_fixture.sh",
               "Resources/Search/dot_search.py"]
    host_identity = fixture_hashes(ROOT, sources)
    scenarios = []
    with tempfile.TemporaryDirectory(prefix="dot-search-proxy-native-") as temporary:
        base = Path(temporary).resolve()
        certificates = create_certificates(base)
        for scenario in ("consecutive", "wrong-auth", "untrusted-certificate", "wrong-host-certificate",
                         "redirect-private", "built-in-reconnect", "downstream-cap", "origin-auth-challenge",
                         "helper-success", "helper-origin-auth-challenge", "helper-wrong-auth",
                         "helper-untrusted-certificate", "helper-timeout", "helper-result-error"):
            state = base / scenario
            state.mkdir(mode=0o700)
            for name in ("search_proxy_transport_fixture.py", "search_proxy_fixture_support.py"):
                shutil.copyfile(ROOT / "Tests/Fixtures" / name, state / name)
            helper_hash = host_identity["Resources/Search/dot_search.py"]
            shutil.copyfile(ROOT / "Resources/Search/dot_search.py", state / "dot_search_host.py")
            if digest(state / "dot_search_host.py") != helper_hash:
                raise CanaryFailure("host helper copy changed")
            cert_name = "untrusted" if scenario in ("untrusted-certificate", "helper-untrusted-certificate") else "wrong-host" if scenario == "wrong-host-certificate" else "trusted"
            cert, key = certificates[cert_name]
            trust = certificates["wrong-host" if scenario == "wrong-host-certificate" else "trusted"][0]
            shutil.copyfile(trust, state / "trust.pem")
            response = None
            if scenario in ("origin-auth-challenge", "helper-origin-auth-challenge", "helper-result-error"):
                response = (b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="synthetic-origin"\r\n'
                            b'Content-Length: 0\r\nConnection: close\r\n\r\n')
            elif scenario == "helper-timeout":
                def timeout_response(_):
                    time.sleep(9)
                    return b""
                response = timeout_response
            elif scenario == "helper-success":
                body = (b'<html><body><div id="links"><div class="web-result"><h2>'
                        b'<a href="https://example.org/fixture">Synthetic result</a></h2>'
                        b'<a class="result__snippet">Offline parser fixture</a></div></div></body></html>')
                response = (b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " +
                            str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            elif scenario == "redirect-private":
                response = b"HTTP/1.1 302 Found\r\nLocation: https://10.0.0.1/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            elif scenario == "built-in-reconnect":
                response = lambda index: b"" if index == 1 else b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture"
            elif scenario == "downstream-cap":
                response = (b"HTTP/1.1 200 OK\r\nContent-Length: " + str(DOWN_CAP + 1).encode() +
                            b"\r\nConnection: close\r\n\r\n" + b"x" * (DOWN_CAP + 1))
            credential = secrets.token_hex(32).encode()
            with TLSOrigin(cert, key, response) as origin, ConnectEndpoint(origin.address, credential) as endpoint, socket.socket() as reserved:
                reserved.bind(("127.0.0.1", 0))
                reserved.listen(1)
                # The client can reach only this endpoint. Direct TLS-origin
                # access, public/private networks, DNS and wildcard egress remain denied.
                params = {"DOT_SEARCH_PAYLOAD": str(payload), "DOT_SEARCH_STATE": str(state),
                          "DOT_SEARCH_PYTHON": str(payload / "python/bin/python3"),
                          "DOT_SEARCH_LISTENER": "localhost:" + str(reserved.getsockname()[1]),
                          "DOT_SEARCH_EGRESS": "localhost:" + str(endpoint.address[1])}
                command = ["/usr/bin/sandbox-exec"]
                for name, value in params.items():
                    command.extend(["-D", name + "=" + value])
                command.extend(["-f", str(ROOT / "Tests/Fixtures/search_proxy_canary.sb"),
                    str(payload / "python/bin/python3"), "-I", "-S", "-B", str(state / "search_proxy_transport_fixture.py"),
                    "--mode", "worker", "--payload", str(payload), "--state", str(state), "--port", str(endpoint.address[1]),
                    "--ca", str(state / "trust.pem"), "--scenario", scenario, "--helper-sha256", helper_hash])
                # Deliberately poison the parent immediately before constructing
                # the positive-list environment. No hostile key is copied through.
                saved = dict(os.environ)
                try:
                    os.environ.update({name: "dot-poison.invalid" for name in POISON})
                    env = {"PATH": "/usr/bin:/bin", "HOME": str(state), "TMPDIR": str(state), "LANG": "en_US.UTF-8"}
                    sent = "0" * 64 if scenario in ("wrong-auth", "helper-wrong-auth") else credential.decode()
                    started = time.monotonic()
                    child = subprocess.run(command, input=(json.dumps({"capability": sent}) + "\n").encode(),
                        capture_output=True, cwd=state, env=env, timeout=20)
                finally:
                    os.environ.clear()
                    os.environ.update(saved)
                if child.returncode != 0:
                    raise CanaryFailure("sandboxed pinned worker failed in " + scenario + "; stderr_sha256=" +
                                       __import__("hashlib").sha256(child.stderr).hexdigest())
                inspected_credentials = (credential, sent.encode())
                if child.stderr or any(contains_proxy_credential(child.stdout + child.stderr, value)
                                       for value in inspected_credentials):
                    raise CanaryFailure("unexpected output or credential leak")
                result = json.loads(child.stdout)
                settle(endpoint)
                settle(origin)
                evidence = endpoint.snapshot()
                outcomes = result["outcomes"]
                if evidence["active"] != 0 or evidence["upstream_allocations"] > MAX_AUTH_CONNECTS:
                    raise CanaryFailure("connection budget or drainage failure")
                if evidence["total_upstream_bytes"] > UP_CAP or evidence["total_downstream_bytes"] > DOWN_CAP:
                    raise CanaryFailure("real encrypted byte cap exceeded")
                if time.monotonic() - started > 15:
                    raise CanaryFailure("absolute request generation did not settle")
                if scenario in ("wrong-auth", "helper-wrong-auth"):
                    assert "error_type" in outcomes[0] and not origin.sni and not origin.requests
                    assert evidence["upstream_allocations"] == 0
                    assert evidence["authentication_rejections"] > 0
                    assert evidence["rejected"] == evidence["authentication_rejections"]
                elif scenario in ("untrusted-certificate", "wrong-host-certificate", "helper-untrusted-certificate"):
                    assert outcomes[0].get("curl_code") == (0 if scenario.startswith("helper-") else 60) and not origin.requests
                    assert origin.sni and set(origin.sni) == {HOST}
                elif scenario in ("origin-auth-challenge", "helper-origin-auth-challenge", "helper-result-error"):
                    assert "error_type" in outcomes[0] and origin.requests
                    assert set(origin.sni) == {HOST}
                    assert len(origin.requests) <= MAX_AUTH_CONNECTS
                elif scenario == "helper-timeout":
                    assert outcomes[0].get("normalized_error") == "dot_proxy_timeout"
                    assert outcomes[0].get("curl_code") == 28 and len(origin.requests) == 1
                    assert set(origin.sni) == {HOST}
                elif scenario == "helper-success":
                    assert outcomes == [{"status": 200, "parsed_result_count": 1,
                        "parsed_result_is_fixture": True, "original_search_params_credential_free": True}]
                    assert len(origin.requests) == 1 and set(origin.sni) == {HOST}
                elif scenario == "downstream-cap":
                    assert "error_type" in outcomes[0]
                    assert any("cap" in tunnel["reason"] for tunnel in evidence["tunnels"])
                else:
                    expected_status = 302 if scenario == "redirect-private" else 200
                    assert all(x.get("status") == expected_status for x in outcomes)
                    if expected_status == 200:
                        assert all(x["body_is_fixture"] for x in outcomes)
                    expected_connects = 2 if scenario in ("consecutive", "built-in-reconnect") else 1
                    assert len(evidence["connects"]) == expected_connects
                    assert len(origin.requests) == expected_connects
                    assert set(origin.sni) == {HOST}
                for request in origin.requests:
                    for value in inspected_credentials:
                        assert_origin_request(request, value)
                assert all(item["headers"].get("proxy-authorization") == "<redacted>"
                           and "authorization" not in item["headers"] for item in evidence["connects"])
                assert all(item["request_line"] == "CONNECT " + AUTHORITY.decode() + " HTTP/1.1" for item in evidence["connects"])
                for path in state.rglob("*"):
                    if path.is_file() and any(contains_proxy_credential(path.read_bytes(), value)
                                              for value in inspected_credentials):
                        raise CanaryFailure("capability persisted in fixture state")
                scenario_report = {"scenario": scenario, "client": result, "endpoint": evidence,
                                   "origin_sni": origin.sni, "origin_request_count": len(origin.requests)}
                if any(contains_proxy_credential(json.dumps(scenario_report).encode(), value)
                       for value in inspected_credentials):
                    raise CanaryFailure("credential leaked into fixture report")
                scenarios.append(scenario_report)
    _, final_identity = verify_payload(payload, args.expected_receipt_sha256)
    _, final_lock_identity = verify_source_lock(lock_path, identity["assembly_lock_sha256"])
    if identity != final_identity or fixture_hashes(ROOT, sources) != host_identity or lock_identity != final_lock_identity:
        raise CanaryFailure("host, payload or source lock changed during canary")
    result = {"schema": 1, "kind": "build-only-pinned-proxy-transport-canary", "result": "passed",
              "production_acceptance": False, "production_broker_tested": False,
              "independent_broker_revocation_proven": False, "exit_and_drain_before_replacement_proven": False,
              "platform": platform.platform(), "native_host": native_host_identity(), "payload_identity": identity, "host_source_sha256": host_identity,
              "host_executable_sha256": digest(sys.executable), **lock_identity,
              "dependency_probe": details, "scenarios": scenarios,
              "unverified": ["Swift broker and app integration", "production bootstrap", "full Waitress/gateway integration (actual DDG _search_basic only)",
                             "representative live provider sizes", "production TLS/public-peer validation", "native acceptance/assembly/signing",
                             "full Stop/Quit/crash/sleep paths", "inflated HTML allocation bounds"]}
    with report.open("x") as stream:
        stream.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": "build-only-native-transport-pass", "production_acceptance": False, "report": str(report)}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("run", "worker"), default="run")
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--expected-receipt-sha256")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--state")
    parser.add_argument("--port", type=int)
    parser.add_argument("--ca", type=Path)
    parser.add_argument("--scenario")
    parser.add_argument("--helper-sha256")
    args = parser.parse_args()
    if args.mode == "run":
        if not args.report or not args.expected_receipt_sha256 or not args.lock:
            parser.error("--report, --lock and --expected-receipt-sha256 are required")
        run(args)
    else:
        if not args.state or not args.port or not args.ca or not args.scenario or not args.helper_sha256:
            parser.error("missing worker fixture inputs")
        worker(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print transport exception text (may contain a credential-bearing URL).
        print("FAIL: build-only transport canary: " + type(error).__name__ +
              (": " + str(error) if isinstance(error, CanaryFailure) else ""), file=sys.stderr)
        raise SystemExit(1)

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
    outgoing["proxies"]["all://"] = "http://dot:" + capability + "@127.0.0.1:" + str(args.port)
    import searx.network
    from searx.network.client import get_loop
    from searx.network.network import NETWORKS
    # Actual pinned initialization and public request interface. Empty registry
    # marker prevents initializing unrelated engine clients; no transport patch.
    searx.network.initialize(settings_engines=[{"name": "dot-unloaded-fixture"}], settings_outgoing=outgoing)
    network = searx.network.get_network()
    if (network.verify is not True or network.enable_http or network.retries != 0 or
            network.max_redirects != 0 or network.max_connections != 1 or network.enable_http3):
        raise CanaryFailure("network policy differs from the reviewed settings")
    start = time.monotonic()
    outcomes = []
    try:
        for _ in range(2 if args.scenario == "consecutive" else 1):
            try:
                response = searx.network.request("post", "https://" + HOST + "/html/",
                    data={"q": "build-only-synthetic-query"}, timeout=8,
                    allow_redirects=False, max_redirects=0, verify=str(args.ca))
                outcomes.append({"status": response.status_code, "body_bytes": len(response.content),
                                 "body_is_fixture": response.content == b"fixture"})
            except Exception as error:
                # Do not emit exception messages, URLs, capabilities or TLS keys.
                outcomes.append({"error_type": type(error).__name__, "curl_code": int(getattr(error, "code", 0))})
    finally:
        asyncio.run_coroutine_threadsafe(network.aclose(), get_loop()).result(timeout=3)
        # Unused initialized networks own no clients but are explicitly closed.
        for item in NETWORKS.values():
            asyncio.run_coroutine_threadsafe(item.aclose(), get_loop()).result(timeout=3)
    if capability in settings.read_text():
        raise CanaryFailure("fixture capability persisted to settings")
    print(json.dumps({"outcomes": outcomes, "elapsed": time.monotonic() - start,
        "clean_environment": True, "initialization_order_verified": True,
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
               "scripts/search_proxy_canary_support.py", "scripts/verify_search_proxy_native_fixture.sh"]
    host_identity = fixture_hashes(ROOT, sources)
    scenarios = []
    with tempfile.TemporaryDirectory(prefix="dot-search-proxy-native-") as temporary:
        base = Path(temporary).resolve()
        certificates = create_certificates(base)
        for scenario in ("consecutive", "wrong-auth", "untrusted-certificate", "wrong-host-certificate",
                         "redirect-private", "built-in-reconnect", "downstream-cap"):
            state = base / scenario
            state.mkdir(mode=0o700)
            for name in ("search_proxy_transport_fixture.py", "search_proxy_fixture_support.py"):
                shutil.copyfile(ROOT / "Tests/Fixtures" / name, state / name)
            cert_name = "untrusted" if scenario == "untrusted-certificate" else "wrong-host" if scenario == "wrong-host-certificate" else "trusted"
            cert, key = certificates[cert_name]
            trust = certificates["wrong-host" if scenario == "wrong-host-certificate" else "trusted"][0]
            shutil.copyfile(trust, state / "trust.pem")
            response = None
            if scenario == "redirect-private":
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
                    "--ca", str(state / "trust.pem"), "--scenario", scenario])
                # Deliberately poison the parent immediately before constructing
                # the positive-list environment. No hostile key is copied through.
                saved = dict(os.environ)
                try:
                    os.environ.update({name: "dot-poison.invalid" for name in POISON})
                    env = {"PATH": "/usr/bin:/bin", "HOME": str(state), "TMPDIR": str(state), "LANG": "en_US.UTF-8"}
                    sent = "0" * 64 if scenario == "wrong-auth" else credential.decode()
                    started = time.monotonic()
                    child = subprocess.run(command, input=(json.dumps({"capability": sent}) + "\n").encode(),
                        capture_output=True, cwd=state, env=env, timeout=20)
                finally:
                    os.environ.clear()
                    os.environ.update(saved)
                if child.returncode != 0:
                    raise CanaryFailure("sandboxed pinned worker failed in " + scenario + "; stderr_sha256=" +
                                       __import__("hashlib").sha256(child.stderr).hexdigest())
                if child.stderr or contains_proxy_credential(child.stdout, credential) or contains_proxy_credential(child.stderr, credential):
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
                if scenario == "wrong-auth":
                    assert "error_type" in outcomes[0] and not origin.sni and not origin.requests
                    assert evidence["upstream_allocations"] == 0
                    assert evidence["authentication_rejections"] > 0
                    assert evidence["rejected"] == evidence["authentication_rejections"]
                elif scenario in ("untrusted-certificate", "wrong-host-certificate"):
                    assert outcomes[0].get("curl_code") == 60 and not origin.requests
                    assert origin.sni and set(origin.sni) == {HOST}
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
                assert all(b"proxy-authorization" not in item.lower() and not contains_proxy_credential(item, credential) for item in origin.requests)
                assert all(item["request_line"] == "CONNECT " + AUTHORITY.decode() + " HTTP/1.1" for item in evidence["connects"])
                for path in state.rglob("*"):
                    if path.is_file() and contains_proxy_credential(path.read_bytes(), credential):
                        raise CanaryFailure("capability persisted in fixture state")
                scenario_report = {"scenario": scenario, "client": result, "endpoint": evidence,
                                   "origin_sni": origin.sni, "origin_request_count": len(origin.requests)}
                if contains_proxy_credential(json.dumps(scenario_report).encode(), credential):
                    raise CanaryFailure("credential leaked into fixture report")
                scenarios.append(scenario_report)
    _, final_identity = verify_payload(payload, args.expected_receipt_sha256)
    _, final_lock_identity = verify_source_lock(lock_path, identity["assembly_lock_sha256"])
    if identity != final_identity or fixture_hashes(ROOT, sources) != host_identity or lock_identity != final_lock_identity:
        raise CanaryFailure("host, payload or source lock changed during canary")
    result = {"schema": 1, "kind": "build-only-pinned-proxy-transport-canary", "result": "passed",
              "production_acceptance": False, "production_broker_tested": False,
              "platform": platform.platform(), "native_host": native_host_identity(), "payload_identity": identity, "host_source_sha256": host_identity,
              "host_executable_sha256": digest(sys.executable), **lock_identity,
              "dependency_probe": details, "scenarios": scenarios,
              "unverified": ["Swift broker and app integration", "production bootstrap", "full SearXNG/Waitress/DDG engine flow",
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
    args = parser.parse_args()
    if args.mode == "run":
        if not args.report or not args.expected_receipt_sha256 or not args.lock:
            parser.error("--report, --lock and --expected-receipt-sha256 are required")
        run(args)
    else:
        if not args.state or not args.port or not args.ca or not args.scenario:
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

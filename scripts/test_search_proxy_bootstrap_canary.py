#!/usr/bin/env python3
"""Compile/sign/run an independent BUILD-ONLY proxy bootstrap canary on macOS.
Only a temporary fixture is signed. Input payload and production source are read-only.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
from search_proxy_canary_support import (
    drive_probe, fixture_directories, fixture_hashes, minimal_env, owned_listener,
    native_host_identity, parse_args, require_native, sha_file, verify_payload,
)


def main():
    require_native()
    args = parse_args(__doc__)
    source_payload, identity = verify_payload(args.search_payload, args.expected_receipt_sha256)
    root = Path(__file__).resolve().parents[1]
    sources = fixture_hashes(root, ["scripts/test_search_proxy_bootstrap_canary.py", "scripts/search_proxy_canary_support.py",
        "Tests/Native/search-proxy-bootstrap-canary.c", "Tests/Native/search_proxy_bootstrap_probe.py",
        "Tests/Fixtures/search_proxy_canary.sb", "profile-bootstrap-basis.json"])
    with tempfile.TemporaryDirectory(prefix="dot-search-proxy-bootstrap-") as temporary:
        base = Path(temporary).resolve()
        state, outside, inference = fixture_directories(base)
        payload = base / "fixture-payload"
        payload.mkdir(mode=0o700)
        # No acceptance manifests or original assembly evidence are copied.
        shutil.copytree(source_payload / "python", payload / "python", symlinks=False)
        receipt = json.loads((source_payload / "evidence/assembly-input-receipt.json").read_text())
        for entry in receipt["files"]:
            if entry["path"].startswith("python/"):
                assert sha_file(payload / entry["path"]) == entry["sha256"], "interpreter copy changed"
        (payload / "bin").mkdir(mode=0o700)
        shutil.copyfile(root / "Tests/Fixtures/search_proxy_canary.sb", payload / "search.sb")
        shutil.copyfile(root / "Tests/Native/search_proxy_bootstrap_probe.py", payload / "dot_search.py")
        (payload / "escape").symlink_to(outside / "private.fixture")
        binary = payload / "bin/dot-search-bootstrap"
        subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-std=c11",
            "-Wall", "-Wextra", "-Werror", "-O2", str(root / "Tests/Native/search-proxy-bootstrap-canary.c"),
            "-o", str(binary), "-lsandbox"], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "app.dot.search-bootstrap-canary", str(binary)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True)
        binary_hash = sha_file(binary)
        compiler_version = subprocess.check_output(["/usr/bin/xcrun", "clang", "--version"], text=True).strip()
        sdk_version = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        with owned_listener() as foreign, owned_listener() as egress, (state / "descriptor-decoy").open("w+") as decoy:
            command = [str(binary), "--payload", str(payload), "--state-root", str(state), "--egress-port", str(egress.getsockname()[1])]
            poisoned = minimal_env(state)
            poisoned.update({key: "https://127.0.0.1:1/poison" for key in
                ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")})
            poisoned.update({"NO_PROXY": "*", "no_proxy": "*", "PYTHONHOME": "/does-not-exist",
                "PYTHONPATH": "/does-not-exist", "SSL_CERT_FILE": "/does-not-exist",
                "CURL_CA_BUNDLE": "/does-not-exist", "REQUESTS_CA_BUNDLE": "/does-not-exist"})
            checks = drive_probe(command, payload, state, outside, inference, foreign, egress,
                                 pass_fds=(decoy.fileno(),), env=poisoned)
            # All aliases, malformed values and overflows fail with a canary-only
            # native frame before Python. Positive run above proves canonical
            # paths, signing, profile compilation and same executable worked.
            bad_ports = ("", "0", "00", "01", "+1", "-1", " 1", "1 ", "1x", "1.0", "65536", "999999999999999999999", "１２３")
            for value in bad_ports:
                result = subprocess.run(command[:-1] + [value], input=b"", stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, cwd=state, env=minimal_env(state), timeout=12)
                assert result.returncode == 2 and result.stdout == b'{"event":"native_canary_failed"}\n' and result.stderr == b"", repr(value)
            for bad_command in (command[:-2], command + ["--egress-port", command[-1]],
                                command[:-2] + ["--broker-port", command[-1]]):
                result = subprocess.run(bad_command, input=b"", stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, cwd=state, env=minimal_env(state), timeout=12)
                assert result.returncode == 2 and result.stdout == b'{"event":"native_canary_failed"}\n' and result.stderr == b""
            checks.extend(("strict-egress-port-parser", "no-extra-descriptors", "clean-environment-under-poison"))
        assert sha_file(binary) == binary_hash
        for entry in receipt["files"]:
            if entry["path"].startswith("python/"):
                assert sha_file(payload / entry["path"]) == entry["sha256"], "interpreter copy changed during fixture"
    _, after = verify_payload(source_payload, args.expected_receipt_sha256)
    assert after == identity, "source payload changed during fixture run"
    assert sources == fixture_hashes(root, list(sources)), "fixture source changed during run"
    print(json.dumps({"schema": 1, "status": "compiled-proxy-bootstrap-synthetic-pass", "production_acceptance": False,
        "signature": "ad-hoc-fixture-only", "native_host": native_host_identity(), "payload": identity, "fixture_sources": sources,
        "fixture_bootstrap_sha256": binary_hash, "compiler_version": compiler_version, "sdk_version": sdk_version, "checks": checks,
        "scope": "Test-only native bootstrap/profile. No production broker, TLS, SearXNG, live provider or app admission evidence."}, sort_keys=True))


if __name__ == "__main__":
    main()

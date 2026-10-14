#!/usr/bin/env python3
"""Run a fixture-only loopback proxy profile with an exact independent interpreter.
Never edits Resources, invokes live search, or creates production acceptance.
"""
from pathlib import Path
import json
import shutil
import tempfile
from search_proxy_canary_support import (
    drive_probe, fixture_directories, fixture_hashes, owned_listener,
    native_host_identity, parse_args, require_native, verify_payload,
)


def main():
    require_native()
    args = parse_args(__doc__)
    payload, identity = verify_payload(args.search_payload, args.expected_receipt_sha256)
    root = Path(__file__).resolve().parents[1]
    profile = root / "Tests/Fixtures/search_proxy_canary.sb"
    python = payload / "python/bin/python3"
    sources = fixture_hashes(root, ["scripts/test_search_proxy_sandbox_canary.py", "scripts/search_proxy_canary_support.py",
        "Tests/Native/search_proxy_bootstrap_probe.py", "Tests/Fixtures/search_proxy_canary.sb", "profile-bootstrap-basis.json"])
    with tempfile.TemporaryDirectory(prefix="dot-search-proxy-profile-") as temporary:
        base = Path(temporary).resolve()
        state, outside, inference = fixture_directories(base)
        helper = state / "profile_probe.py"
        shutil.copyfile(root / "Tests/Native/search_proxy_bootstrap_probe.py", helper)
        with owned_listener() as listener, owned_listener() as foreign, owned_listener() as egress:
            parameters = {"DOT_SEARCH_PAYLOAD": str(payload), "DOT_SEARCH_STATE": str(state),
                          "DOT_SEARCH_PYTHON": str(python),
                          "DOT_SEARCH_LISTENER": f"localhost:{listener.getsockname()[1]}",
                          "DOT_SEARCH_EGRESS": f"localhost:{egress.getsockname()[1]}"}
            command = ["/usr/bin/sandbox-exec"]
            for key, value in parameters.items():
                command.extend(["-D", key + "=" + value])
            command.extend(["-f", str(profile), str(python), "-I", "-S", "-B", str(helper),
                "--payload", str(payload), "--state-root", str(state),
                "--owned-listener", str(listener.fileno()), "--egress-port", str(egress.getsockname()[1]),
                "--probe-kind", "profile"])
            checks = drive_probe(command, payload, state, outside, inference, foreign, egress,
                                 pass_fds=(listener.fileno(),))
    _, after = verify_payload(payload, args.expected_receipt_sha256)
    assert after == identity, "source payload changed during fixture run"
    assert sources == fixture_hashes(root, list(sources)), "fixture source changed during run"
    print(json.dumps({"schema": 1, "status": "synthetic-proxy-profile-pass", "production_acceptance": False,
        "native_host": native_host_identity(), "payload": identity, "fixture_sources": sources, "checks": checks,
        "scope": "Exact interpreter with independent fixture profile. No production bootstrap, broker, TLS, SearXNG or live provider acceptance."}, sort_keys=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compare two privacy snapshots. Any unexplained difference fails the build."""
import argparse
import fnmatch
import json
import sys
from pathlib import Path


def display(path):
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home + "/") else path


def load_allowlist(path):
    rules = []
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        pattern, _, reason = line.partition("|")
        rules.append((pattern.strip(), reason.strip() or "OS-owned transient state"))
    return rules


def allowed(shown, rules):
    # A Dot-owned path can never be excused by an Apple-cache pattern, even if a
    # future allowlist entry accidentally uses a wildcard that spans slashes.
    if "app.dot.local" in shown or shown.endswith("/Dot.app") or "/Dot.app/" in shown:
        return None
    for pattern, reason in rules:
        if fnmatch.fnmatchcase(shown, pattern):
            return reason
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--allowlist", default="scripts/privacy_allowlist.txt")
    arguments = parser.parse_args()
    before = json.loads(Path(arguments.before).read_text())
    after = json.loads(Path(arguments.after).read_text())
    rules = load_allowlist(arguments.allowlist)

    failures = []
    explained = []
    for path in sorted(set(before["paths"]) | set(after["paths"])):
        old = before["paths"].get(path)
        new = after["paths"].get(path)
        if old == new:
            continue
        shown = display(path)
        reason = allowed(shown, rules)
        if reason:
            explained.append((shown, reason))
        else:
            failures.append(f"{shown}: {old} -> {new}")

    for name in sorted(set(before["commands"]) | set(after["commands"])):
        old = before["commands"].get(name)
        new = after["commands"].get(name)
        if old == new:
            continue
        failures.append(f"OS listing {name} changed:\n  before: {old}\n  after:  {new}")

    for shown, reason in explained:
        print(f"allowed transient change: {shown} ({reason})")
    if failures:
        print("FAIL: the install/uninstall cycle was not trace-free:", file=sys.stderr)
        for failure in failures:
            print("  " + failure, file=sys.stderr)
        return 1
    print(f"PASS: no trace remains ({len(explained)} documented OS-transient changes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

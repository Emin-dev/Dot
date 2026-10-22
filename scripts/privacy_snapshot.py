#!/usr/bin/env python3
"""Capture the filesystem and OS registration state used by the no-trace CI test.

The snapshot lists every path under the user home, /Applications and /Library
with its type, permissions and size, plus launchctl labels, background-task
records, defaults domains, installed packages and the readable TCC rows. It is
deliberately data-only: no file contents, no secrets, no network.
"""
import argparse
import json
import os
import plistlib
import sqlite3
import subprocess
import sys
from pathlib import Path

SKIP_NAMES = {"node_modules", ".git"}


def command(argv):
    try:
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=30, check=False)
        return result.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unavailable: {error}"


def normalize_launchctl(_):
    labels = set()
    for line in command(["launchctl", "list"]).splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) >= 3 and fields[2].strip():
            labels.add(fields[2].strip())
    return sorted(label for label in labels
                  if not label.startswith(("com.apple.", "application.com.apple.")))


def normalize_defaults(_):
    text = command(["defaults", "domains"])
    domains = {part.strip() for part in text.replace("\n", ",").split(",") if part.strip()}
    return sorted(domain for domain in domains if not domain.startswith("com.apple.")
                  and not domain.startswith("NSGlobalDomain"))


def normalize_btm(_):
    text = command(["sfltool", "dumpbtm"])
    bundles = set()
    for line in text.splitlines():
        stripped = line.strip()
        for prefix in ("Bundle Identifier:", "bundleIdentifier =", "Bundle ID:"):
            if stripped.startswith(prefix):
                value = stripped[len(prefix):].strip().strip('"')
                if value and not value.startswith("com.apple."):
                    bundles.add(value)
    return sorted(bundles)


def tcc_rows(_):
    candidates = [
        Path.home() / "Library/Application Support/com.apple.TCC/TCC.db",
        Path.home() / "Library/Application Support/com.apple.TCC/TCC.db-wal",
    ]
    for database in candidates[:1]:
        if not database.is_file():
            continue
        try:
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5)
            try:
                rows = connection.execute(
                    "select service, client, auth_value from access order by service, client"
                ).fetchall()
            finally:
                connection.close()
            return sorted("|".join(str(item) for item in row) for row in rows
                          if str(row[1]) != "com.apple.TCC"
                          and not str(row[1]).startswith("com.apple."))
        except (sqlite3.Error, OSError) as error:
            return [f"unreadable: {error}"]
    return ["no readable TCC database (macOS protects it)"]


COMMANDS = {
    "launchctl_labels": normalize_launchctl,
    "defaults_domains": normalize_defaults,
    "background_items": normalize_btm,
    "packages": lambda _: sorted(line.strip() for line in command(["pkgutil", "--pkgs"]).splitlines() if line.strip()),
    "tcc": tcc_rows,
}


def excluded(path, excludes):
    for root in excludes:
        if path == root or root in path.parents:
            return True
    return False


def walk(root, excludes, max_depth=None):
    entries = {}
    stack = [(root, 0)]
    while stack:
        directory, depth = stack.pop()
        try:
            iterator = os.scandir(directory)
        except (PermissionError, FileNotFoundError, NotADirectoryError):
            continue
        with iterator:
            for entry in iterator:
                path = Path(entry.path)
                if excluded(path, excludes) or entry.name in SKIP_NAMES:
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except (PermissionError, FileNotFoundError):
                    continue
                if entry.is_symlink():
                    kind = "l"
                elif entry.is_dir(follow_symlinks=False):
                    kind = "d"
                elif entry.is_file(follow_symlinks=False):
                    kind = "f"
                else:
                    kind = "o"
                # Directory entry-count sizes differ across APFS and would flag
                # a parent merely because a Dot container was created/removed.
                value = {"k": kind, "m": info.st_mode & 0o7777,
                         "s": 0 if kind == "d" else info.st_size}
                # File timestamps catch an in-place rewrite that preserves size and
                # mode. Directory timestamps are excluded because creating and then
                # deleting a container legitimately touches the parent directory.
                if kind == "f":
                    value["t"] = info.st_mtime_ns
                entries[str(path)] = value
                if kind == "d" and (max_depth is None or depth + 1 < max_depth):
                    stack.append((path, depth + 1))
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    arguments = parser.parse_args()
    raw_excludes = os.environ.get("DOT_SNAPSHOT_EXCLUDES", "")
    excludes = [Path(item).resolve() for item in raw_excludes.split(":") if item]
    # Hosted-runner infrastructure writes its own diagnostic logs under the
    # runner's home while the workflow is running. It is not part of the Mac
    # state this test is proving clean.
    for name in ("actions-runner", "work", "hostedtoolcache"):
        candidate = Path.home() / name
        if candidate.exists():
            excludes.append(candidate.resolve())
    # The home is captured in full. System roots only need their application
    # bundles and top-level library entries; recursing through Xcode or the
    # CoreSimulator runtime would take tens of minutes and cannot hide a Dot
    # install (which would appear at /Applications/Dot.app).
    roots = [(Path.home(), None), (Path("/Applications"), 2), (Path("/Library"), 3)]
    paths = {}
    for root, depth in roots:
        if root.is_dir():
            paths.update(walk(root, excludes, depth))
    record = {
        "schema": 1,
        "roots": [str(root) for root, _ in roots],
        "paths": paths,
        "commands": {name: function(None) for name, function in COMMANDS.items()},
    }
    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(record, indent=0, sort_keys=True) + "\n")
    print(f"captured {len(paths)} paths and {len(COMMANDS)} OS listings in {output}")


if __name__ == "__main__":
    sys.exit(main())

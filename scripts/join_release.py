#!/usr/bin/env python3
"""Download, join and verify a split release (for example the all-in-one DMG).

Usage:
  python3 scripts/join_release.py Dot-all-in-one.dmg.parts.json --output Dot-all-in-one.dmg
  python3 scripts/join_release.py ... --download     # fetch missing parts from their URLs

Every part and the joined file are verified against SHA-256 before the output is
accepted. Existing parts are reused, so an interrupted download resumes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

CHUNK = 8 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path, expected: int) -> None:
    if destination.is_file() and destination.stat().st_size == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    if destination.is_file() and destination.stat().st_size == expected:
        return
    if partial.is_file() and partial.stat().st_size == expected and not destination.exists():
        partial.replace(destination)
        return
    existing = partial.stat().st_size if partial.exists() else 0
    if existing > expected:
        partial.unlink()
        existing = 0
    request = urllib.request.Request(url)
    if existing:
        request.add_header("Range", f"bytes={existing}-")
    with urllib.request.urlopen(request, timeout=120) as response:
        status = getattr(response, "status", 200)
        if status == 206 and existing:
            mode = "ab"
        else:
            mode = "wb"
            existing = 0
        with partial.open(mode) as out:
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                out.write(block)
    if partial.stat().st_size != expected:
        raise SystemExit(f"incomplete download: {destination.name}")
    partial.replace(destination)


def join(manifest_path: Path, output: Path, fetch: bool) -> None:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schema_version") != 1:
        raise SystemExit("unsupported parts manifest")
    parts = manifest.get("parts")
    if not isinstance(parts, list) or not parts:
        raise SystemExit("parts manifest is empty")
    if sum(int(part["bytes"]) for part in parts) != int(manifest["bytes"]):
        raise SystemExit("part sizes do not add up to the manifest size")
    base = manifest_path.parent
    resolved: list[Path] = []
    for part in parts:
        path = base / part["name"]
        expected = int(part["bytes"])
        usable = path.is_file() and path.stat().st_size == expected and sha256_file(path) == part["sha256"]
        if not usable and fetch and part.get("url"):
            print(f"downloading {part['name']}")
            if path.exists():
                path.unlink()
            download(part["url"], path, expected)
            usable = path.is_file() and path.stat().st_size == expected and sha256_file(path) == part["sha256"]
        if not usable:
            if not path.is_file() or path.stat().st_size != expected:
                raise SystemExit(f"missing or wrong-size part: {part['name']}")
            raise SystemExit(f"SHA-256 mismatch: {part['name']}")
        resolved.append(path)
    staging = output.with_suffix(output.suffix + ".join")
    with staging.open("wb") as out:
        for path in resolved:
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(CHUNK), b""):
                    out.write(block)
    if staging.stat().st_size != int(manifest["bytes"]):
        staging.unlink()
        raise SystemExit("joined size does not match the manifest")
    if sha256_file(staging) != manifest["sha256"]:
        staging.unlink()
        raise SystemExit("joined SHA-256 does not match the manifest")
    staging.replace(output)
    print(f"verified {output} ({manifest['bytes']} bytes, sha256 {manifest['sha256']})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    output = args.output or (args.manifest.parent / manifest["output"])
    join(args.manifest, output, args.download)
    return 0


if __name__ == "__main__":
    sys.exit(main())

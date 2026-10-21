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
import posixpath
import re
import urllib.request
from pathlib import Path
from urllib.parse import unquote, urlparse

CHUNK = 8 * 1024 * 1024
RELEASE_PREFIX = "/Emin-dev/Dot/releases/download/"


def safe_name(value: object) -> str:
    """Part/output names must be one plain filename, never a path."""
    if not isinstance(value, str) or value in ("", ".", ".."):
        raise SystemExit("parts manifest has an invalid file name")
    if value != Path(value).name or "/" in value or "\\" in value or "\x00" in value:
        raise SystemExit(f"unsafe file name in parts manifest: {value!r}")
    return value


def safe_url(value: object) -> str:
    """Only fetch parts from this repository's own HTTPS release assets."""
    if not isinstance(value, str):
        raise SystemExit("parts manifest has an invalid URL")
    parsed = urlparse(value)
    path = parsed.path
    for _ in range(8):
        decoded = unquote(path)
        if decoded == path:
            break
        path = decoded
    normalized = posixpath.normpath(path)
    if parsed.scheme != "https" or parsed.netloc != "github.com" \
            or ".." in path.split("/") \
            or not normalized.startswith(RELEASE_PREFIX):
        raise SystemExit(f"refusing a part URL outside the Dot release: {value!r}")
    return value


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
    names: set[str] = set()
    for part in parts:
        name = safe_name(part.get("name"))
        if name in names:
            raise SystemExit(f"duplicate part name: {name}")
        names.add(name)
        expected = int(part["bytes"])
        if expected <= 0 or not re.fullmatch("[0-9a-f]{64}", str(part.get("sha256", ""))):
            raise SystemExit(f"invalid size or SHA-256 for part: {name}")
        path = base / name
        usable = path.is_file() and path.stat().st_size == expected and sha256_file(path) == part["sha256"]
        if not usable and fetch and part.get("url"):
            url = safe_url(part["url"])
            print(f"downloading {name}")
            if path.exists():
                path.unlink()
            download(url, path, expected)
            usable = path.is_file() and path.stat().st_size == expected and sha256_file(path) == part["sha256"]
        if not usable:
            if not path.is_file() or path.stat().st_size != expected:
                raise SystemExit(f"missing or wrong-size part: {name}")
            raise SystemExit(f"SHA-256 mismatch: {name}")
        resolved.append(path)
    if output.is_symlink():
        raise SystemExit(f"refusing to replace a symlink: {output}")
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
    output = args.output or (args.manifest.parent / safe_name(manifest.get("output")))
    join(args.manifest, output, args.download)
    return 0


if __name__ == "__main__":
    sys.exit(main())

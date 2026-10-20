#!/usr/bin/env python3
"""Split the verified model payload into GitHub-release parts (<2 GB each).

Run this on the Mac that holds the accepted `OfflineModels` payload. It verifies
every file against `Resources/bundled-models.json`, writes deterministic part
assets, per-part SHA-256 and `model-parts.json` (the primary download plan read
by the app). Nothing is uploaded automatically.

Usage:
  python3 scripts/model_parts.py --models ~/path/OfflineModels --output build-parts

Then upload every `*.partNNN` asset plus `model-parts.json` to the release tag
printed by the script (default model-parts-v1), then commit model-parts.json so
the next app build carries the exact plan.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_PART = 1_900_000_000
MAX_PART = 2_000_000_000
CHUNK = 8 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_asset(path: str) -> str:
    asset = re.sub(r"[^A-Za-z0-9._-]+", "-", path).strip("-")
    if not asset or ".." in asset:
        raise SystemExit(f"cannot derive a safe asset name from {path!r}")
    return asset


def load_manifest(path: Path) -> dict:
    data = json.loads(path.read_text())
    if data.get("schema_version") != 1:
        raise SystemExit("bundled-models.json schema_version must be 1")
    files = data.get("files")
    if not isinstance(files, list) or not files:
        raise SystemExit("bundled-models.json has no files")
    total = sum(int(item["bytes"]) for item in files)
    if total != int(data.get("total_bytes", -1)):
        raise SystemExit("bundled-models.json total_bytes does not match its files")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True, type=Path)
    parser.add_argument("--manifest", type=Path, default=Path("Resources/bundled-models.json"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", default="model-parts-v1")
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--part-size", type=int, default=DEFAULT_PART)
    args = parser.parse_args()
    if not 1 < args.part_size <= MAX_PART:
        raise SystemExit(f"--part-size must be between 2 and {MAX_PART} bytes")
    base_url = args.base_url or (
        f"https://github.com/Emin-dev/Dot/releases/download/{args.tag}/"
    )
    if not base_url.startswith("https://github.com/Emin-dev/Dot/releases/download/"):
        raise SystemExit("--base-url must point at an Emin-dev/Dot release download path")
    if not base_url.endswith("/"):
        base_url += "/"

    manifest = load_manifest(args.manifest)
    root = args.models.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    parts: list[dict] = []
    for item in manifest["files"]:
        relative = item["path"]
        source = (root / relative).resolve()
        if root not in source.parents and source != root:
            raise SystemExit(f"model path escapes the payload: {relative}")
        if not source.is_file():
            raise SystemExit(f"missing model file: {relative}")
        expected_bytes = int(item["bytes"])
        if source.stat().st_size != expected_bytes:
            raise SystemExit(f"size mismatch for {relative}")
        digest = sha256_file(source)
        if digest != item["sha256"]:
            raise SystemExit(f"SHA-256 mismatch for {relative}; refusing to split")
        offset = 0
        index = 0
        stem = safe_asset(relative)
        with source.open("rb") as stream:
            while offset < expected_bytes:
                size = min(args.part_size, expected_bytes - offset)
                name = f"{stem}.part{index:03d}"
                destination = args.output / name
                part_digest = hashlib.sha256()
                written = 0
                with destination.open("wb") as out:
                    while written < size:
                        block = stream.read(min(CHUNK, size - written))
                        if not block:
                            raise SystemExit(f"unexpected EOF while splitting {relative}")
                        out.write(block)
                        part_digest.update(block)
                        written += len(block)
                parts.append({
                    "asset": name,
                    "file": relative,
                    "offset": offset,
                    "bytes": size,
                    "sha256": part_digest.hexdigest(),
                })
                offset += size
                index += 1
    plan = {
        "schema_version": 1,
        "status": "ready",
        "release_tag": args.tag,
        "base_url": base_url,
        "parts": parts,
    }
    plan_path = args.output / "model-parts.json"
    plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(parts)} parts ({sum(p['bytes'] for p in parts)} bytes) to {args.output}")
    print(f"plan: {plan_path}")
    print(f"upload with: gh release create {args.tag} --title 'Dot model parts' \\")
    print(f"  {' '.join(str(args.output / p['asset']) for p in parts)} {plan_path}")
    print("then: cp %s Resources/model-parts.json && git add Resources/model-parts.json" % plan_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

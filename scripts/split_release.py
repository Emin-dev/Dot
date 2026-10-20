#!/usr/bin/env python3
"""Split a release file (for example an all-in-one DMG) into <2 GiB parts.

Outputs `<name>.partNNN`, `<name>.parts.json` and `<name>.parts.sha256`.
The joiner (`scripts/join_release.py`) verifies every part and the whole file.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

MAX_PART = 2_000_000_000
CHUNK = 8 * 1024 * 1024


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def split(source: Path, output: Path, part_size: int, base_url: str | None) -> dict:
    if not source.is_file():
        raise SystemExit(f"no such file: {source}")
    if not 1 < part_size <= MAX_PART:
        raise SystemExit(f"part size must be between 2 and {MAX_PART} bytes")
    output.mkdir(parents=True, exist_ok=True)
    whole = sha256_file(source)
    total = source.stat().st_size
    parts: list[dict] = []
    offset = 0
    index = 0
    with source.open("rb") as stream:
        while offset < total:
            size = min(part_size, total - offset)
            name = f"{source.name}.part{index:03d}"
            destination = output / name
            digest = hashlib.sha256()
            written = 0
            with destination.open("wb") as out:
                while written < size:
                    block = stream.read(min(CHUNK, size - written))
                    if not block:
                        raise SystemExit("unexpected EOF while splitting")
                    out.write(block)
                    digest.update(block)
                    written += len(block)
            parts.append({
                "name": name,
                "bytes": size,
                "sha256": digest.hexdigest(),
                "url": (base_url.rstrip("/") + "/" + name) if base_url else None,
            })
            offset += size
            index += 1
    manifest = {
        "schema_version": 1,
        "output": source.name,
        "bytes": total,
        "sha256": whole,
        "parts": parts,
    }
    (output / f"{source.name}.parts.json").write_text(json.dumps(manifest, indent=2) + "\n")
    lines = [f"{part['sha256']}  {part['name']}" for part in parts]
    (output / f"{source.name}.parts.sha256").write_text("\n".join(lines) + "\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--part-size", type=int, default=MAX_PART)
    parser.add_argument("--base-url", default=None)
    args = parser.parse_args()
    manifest = split(args.source, args.output, args.part_size, args.base_url)
    print(f"{len(manifest['parts'])} parts, {manifest['bytes']} bytes, sha256 {manifest['sha256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

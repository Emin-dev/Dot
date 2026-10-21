#!/usr/bin/env python3
"""Fetch the pinned Qwen3.8 27B Q4 payload and publish <2 GB release parts.

The source is the official public model repository pinned in
`Resources/bundled-models.json`; every file is verified against the SHA-256 in
that manifest before any part is uploaded. The script streams one file at a
time, so the runner only needs room for the largest file (~5.4 GB), never the
whole 22.4 GB payload.

It writes `model-parts.json` in exactly the schema the app reads
(`ModelPartPlan`), plus `model-parts.json.sha256` and `model-parts.sha256`.
With `--upload-release TAG` every completed part is uploaded with `gh` (the
built-in `GITHUB_TOKEN`); no other credentials are used.

Usage (CI):
  python3 -B scripts/fetch_model_parts.py --tag model-parts-v1 \
      --upload-release --output build-parts
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_PART = 1_900_000_000
MAX_PART = 2_000_000_000
CHUNK = 8 * 1024 * 1024
MAX_ATTEMPTS = 4

TARGET = (
    "llm-target/",
    "https://huggingface.co/mlx-community/Qwen3.8-27B-4bit/resolve/"
    "10c35caafbb80f7dc6a7a432cdd11af10a6d4818/",
)
DRAFT = (
    "llm-draft/",
    "https://huggingface.co/incoai/Qwen3.8-27B-DFlash2/resolve/"
    "015e795645c74b1a0eeef3b570031fb62e769bc5/",
)
AUX = (
    "aux/",
    "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/"
    "d0976223747697cb51e056d85c532013931fe52e/",
)
OFFICIAL_PREFIXES = (TARGET, DRAFT, AUX)
ALLOWED_HOST_SUFFIXES = (".huggingface.co", ".hf.co", "huggingface.co", "hf.co")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def remote_url(path: str, source_root: str | None = None) -> str:
    for prefix, base in OFFICIAL_PREFIXES:
        if path.startswith(prefix):
            rest = path[len(prefix):]
            if not rest or ".." in rest or rest.startswith("/"):
                raise SystemExit(f"unsafe model path: {path!r}")
            if source_root:
                root = source_root if source_root.endswith("/") else source_root + "/"
                return root + urllib.parse.quote(path)
            return base + urllib.parse.quote(rest)
    raise SystemExit(f"unknown model path prefix: {path!r}")


def check_final_url(url: str, source_root: str | None) -> None:
    parsed = urllib.parse.urlparse(url)
    if source_root:
        expected = urllib.parse.urlparse(source_root)
        if (parsed.scheme, parsed.hostname, parsed.port) != (
            expected.scheme,
            expected.hostname,
            expected.port,
        ):
            raise SystemExit(f"download redirected away from the test source: {url}")
        return
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or not host.endswith(ALLOWED_HOST_SUFFIXES):
        raise SystemExit(f"download redirected away from the official source: {url}")


def open_stream(url: str, source_root: str | None):
    last: Exception | None = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Dot-model-fetch/1"})
            response = urllib.request.urlopen(request, timeout=120)
            check_final_url(response.geturl(), source_root)
            return response
        except (urllib.error.URLError, TimeoutError, ConnectionError, socket.timeout) as error:
            last = error
            if attempt == MAX_ATTEMPTS:
                break
            time.sleep(min(30, 2 ** attempt))
    raise SystemExit(f"could not download {url}: {last}")


def upload(path: Path, tag: str) -> None:
    last: Exception | None = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            subprocess.run(["gh", "release", "upload", tag, str(path)], check=True)
            return
        except (subprocess.CalledProcessError, OSError) as error:
            last = error
            if attempt == MAX_ATTEMPTS:
                break
            time.sleep(min(60, 5 * attempt))
    raise SystemExit(f"could not upload {path.name}: {last}")


def fetch_file(
    item: dict,
    output: Path,
    part_size: int,
    source_root: str | None,
    upload_tag: str | None,
) -> list[dict]:
    relative = item["path"]
    expected_bytes = int(item["bytes"])
    expected_hash = str(item["sha256"])
    url = remote_url(relative, source_root)
    stem = "".join(
        character if character.isalnum() or character in "._-" else "-"
        for character in relative
    ).strip("-")
    if not stem or ".." in stem:
        raise SystemExit(f"cannot derive a safe asset name from {relative!r}")

    output.mkdir(parents=True, exist_ok=True)
    for stale in output.glob(f"{stem}.part*"):
        stale.unlink()

    parts: list[dict] = []
    whole = hashlib.sha256()
    read_total = 0
    response = open_stream(url, source_root)
    try:
        offset = 0
        index = 0
        while offset < expected_bytes:
            size = min(part_size, expected_bytes - offset)
            name = f"{stem}.part{index:03d}"
            destination = output / name
            part_digest = hashlib.sha256()
            written = 0
            with destination.open("wb") as out:
                while written < size:
                    block = response.read(min(CHUNK, size - written))
                    if not block:
                        raise SystemExit(f"unexpected EOF while reading {relative}")
                    out.write(block)
                    part_digest.update(block)
                    whole.update(block)
                    written += len(block)
                    read_total += len(block)
            if sha256_file(destination) != part_digest.hexdigest():
                destination.unlink(missing_ok=True)
                raise SystemExit(f"part {name} did not verify after writing")
            parts.append(
                {
                    "asset": name,
                    "file": relative,
                    "offset": offset,
                    "bytes": size,
                    "sha256": part_digest.hexdigest(),
                }
            )
            offset += size
            index += 1
    finally:
        response.close()

    if read_total != expected_bytes or whole.hexdigest() != expected_hash:
        for part in parts:
            (output / part["asset"]).unlink(missing_ok=True)
        if read_total != expected_bytes:
            raise SystemExit(f"size mismatch for {relative}: got {read_total}, expected {expected_bytes}")
        raise SystemExit(f"SHA-256 mismatch for {relative}; refusing to publish parts")

    print(f"verified {relative} ({expected_bytes} bytes, {len(parts)} parts)", flush=True)
    if upload_tag:
        for part in parts:
            upload(output / part["asset"], upload_tag)
            (output / part["asset"]).unlink()
    return parts


def write_sha_file(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=Path("Resources/bundled-models.json"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", default="model-parts-v1")
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--part-size", type=int, default=DEFAULT_PART)
    parser.add_argument("--upload-release", action="store_true")
    parser.add_argument("--source-root", default=None, help="test-only alternate source")
    args = parser.parse_args(argv)
    if not 1 < args.part_size <= MAX_PART:
        raise SystemExit(f"--part-size must be between 2 and {MAX_PART} bytes")

    base_url = args.base_url or (
        f"https://github.com/Emin-dev/Dot/releases/download/{args.tag}/"
    )
    if not base_url.startswith("https://github.com/Emin-dev/Dot/releases/download/"):
        raise SystemExit("--base-url must point at an Emin-dev/Dot release download path")
    if not base_url.endswith("/"):
        base_url += "/"

    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schema_version") != 1:
        raise SystemExit("bundled-models.json schema_version must be 1")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise SystemExit("bundled-models.json has no files")
    if sum(int(item["bytes"]) for item in files) != int(manifest.get("total_bytes", -1)):
        raise SystemExit("bundled-models.json total_bytes does not match its files")

    args.output.mkdir(parents=True, exist_ok=True)
    parts: list[dict] = []
    for item in files:
        parts.extend(
            fetch_file(
                item,
                args.output,
                args.part_size,
                args.source_root,
                args.tag if args.upload_release else None,
            )
        )

    plan = {
        "schema_version": 1,
        "status": "ready",
        "release_tag": args.tag,
        "base_url": base_url,
        "parts": parts,
    }
    plan_path = args.output / "model-parts.json"
    plan_path.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    write_sha_file(
        args.output / "model-parts.json.sha256",
        [f"{sha256_file(plan_path)}  model-parts.json"],
    )
    write_sha_file(
        args.output / "model-parts.sha256",
        [f"{part['sha256']}  {part['asset']}" for part in parts],
    )
    print(
        f"wrote {len(parts)} parts ({sum(p['bytes'] for p in parts)} bytes) to {args.output}",
        flush=True,
    )
    print(f"plan: {plan_path} (sha256 {sha256_file(plan_path)})", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

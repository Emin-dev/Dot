#!/usr/bin/env python3
"""Build-only, exact-source patch for page-one-only SearXNG token retention.

No dependency installation or runtime package mutation. The original/modified
source and AGPL notice must be distributed with the completed Search payload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = ROOT / "Resources/Search/searxng-transient-cache-patch.json"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def patched_bytes(data, spec):
    current = digest(data)
    if current == spec["patched_sha256"]:
        return data
    if current != spec["original_sha256"]:
        raise ValueError("unrecognized_searxng_source")
    before, after = spec["before"].encode("utf-8"), spec["after"].encode("utf-8")
    if data.count(before) != 1:
        raise ValueError("source_delta_not_unique")
    patched = data.replace(before, after)
    if digest(patched) != spec["patched_sha256"]:
        raise ValueError("source_delta_digest_mismatch")
    compile(patched, "duckduckgo.py", "exec")
    return patched


def patch_file(source_root, spec, apply=False):
    root = Path(source_root).resolve(strict=True)
    path = root / spec["path"]
    if any(part.is_symlink() for part in (path, *path.parents)) or not path.resolve().is_relative_to(root):
        raise ValueError("symlink_source_rejected")
    data = path.read_bytes()
    patched = patched_bytes(data, spec)
    if data == patched:
        return "already_patched"
    if not apply:
        return "patch_required"
    descriptor, temporary = tempfile.mkstemp(prefix=".dot-cache-patch-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(patched)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, path.stat().st_mode & 0o777)
        # Never overwrite a changed concurrent source between read and replace.
        if path.read_bytes() != data:
            raise ValueError("source_changed")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if digest(path.read_bytes()) != spec["patched_sha256"]:
        raise ValueError("patch_verification_failed")
    return "patched"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    spec = json.loads(SPEC_PATH.read_text())
    result = patch_file(args.source_root, spec, args.apply)
    print(result)
    return 1 if result == "patch_required" else 0


if __name__ == "__main__":
    raise SystemExit(main())

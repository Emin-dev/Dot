#!/usr/bin/env python3
"""Describe the development DMG only after verify_macos.sh succeeds in CI.

This is provenance and a checksum, not notarization or hardware acceptance.
It never changes the app, DMG, complete-build gate, or payload inventory.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def nonempty_file(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Missing, empty, or linked candidate file: {path.name}")
    return path


def candidate_receipt(root, commit, host_arch, macos_version, sdk_version, app_archs):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected an exact source commit")
    if host_arch not in {"arm64", "x86_64"} or app_archs != [host_arch]:
        raise ValueError("Development executable must match its native build target")
    if not macos_version or not sdk_version:
        raise ValueError("Missing macOS build platform facts")
    app = root / "build/Dot.app"
    resources = app / "Contents/Resources"
    dmg = nonempty_file(root / "build/Dot.dmg")
    provenance = json.loads(nonempty_file(resources / "build-provenance.json").read_text())
    expected = {"commit": commit, "source_dirty": False, "signing": "ad-hoc",
                "notarized": False, "runtime_bundled": False, "models_bundled": False,
                "llm_weights_download_on_first_launch": False}
    if any(key not in provenance or type(provenance[key]) is not type(value)
           or provenance[key] != value for key, value in expected.items()):
        raise ValueError("Bundle provenance is not the exact clean model-free development build")
    for path in [resources / "Offline", resources / "OfflineModels",
                 app / "Contents/Frameworks/whisper.framework", resources / "Search"]:
        if path.exists() or path.is_symlink():
            raise ValueError("Unexpected runtime payload in model-free development build")
    # The native Rust runtimes ship beside the executable, never as bundled resources.
    for native in ["dot-search", "dot-voice"]:
        binary = nonempty_file(app / "Contents/MacOS" / native)
        if binary.is_symlink() or not os.access(binary, os.X_OK):
            raise ValueError(f"The bundled native {native} runtime must be an executable regular file")
    info = plistlib.loads(nonempty_file(app / "Contents/Info.plist").read_bytes())
    minimum = info.get("LSMinimumSystemVersion")
    if not isinstance(minimum, str) or not re.fullmatch(r"\d+(?:\.\d+){1,2}", minimum):
        raise ValueError("Missing or invalid application deployment target")
    if hasattr(hashlib, "file_digest"):
        with dmg.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
    else:
        h = hashlib.sha256()
        with dmg.open("rb") as stream:
            while chunk := stream.read(65536):
                h.update(chunk)
        digest = h.hexdigest()
    return {
        "schema_version": 1, "artifact_kind": "model-free-development-only",
        "final_installer": False, "commit": commit, "source_dirty": False,
        "dmg": {"file": dmg.name, "bytes": dmg.stat().st_size, "sha256": digest},
        "platform": {"os": "macOS", "minimum_version": minimum,
                     "executable_architectures": app_archs, "build_host_architecture": host_arch,
                     "build_host_macos_version": macos_version, "sdk_version": sdk_version},
        "signing": "ad-hoc", "notarized": False,
        "runtime_bundled": False, "models_bundled": False, "search_runtime_bundled": True,
        "llm_weights_download_on_first_launch": False,
        "hardware_acceptance": "not-performed-by-CI",
        "limitations": [
            "Native UI development candidate; not a complete neural app or public release.",
            "No bundled model payload: the native voice and search runtimes ship without Whisper, Splash/Qwen or Kokoro model files.",
            "Web search runs through the bundled native dot-search runtime; no hosted search provider credential is bundled.",
            "General web-source fetching needs the native source reader staged beside the app executable.",
            "Ad-hoc signed and unnotarized; macOS may block opening.",
            "A renamed copy shares app identity and local data; use a separate macOS account for isolation."
        ]
    }


def main():
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    if not (root / "build/Dot.dmg").is_file():
        # The mandatory runtime-finalizer canary intentionally blocks packaging
        # on hosted runners. A verification-only run has no DMG to describe.
        print("No development DMG was produced (packaging skipped); receipt skipped.")
        return
    commit = output("git", "rev-parse", "HEAD")
    if output("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Candidate receipt requires a clean checkout")
    if os.environ.get("GITHUB_SHA", commit) != commit:
        raise ValueError("Workflow revision differs from the packaged source")
    binary = nonempty_file(root / "build/Dot.app/Contents/MacOS/Dot")
    receipt = candidate_receipt(root, commit, output("uname", "-m"),
        output("sw_vers", "-productVersion"), output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        output("lipo", "-archs", str(binary)).split())
    text = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    (root / "build/Dot-candidate-receipt.json").write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()

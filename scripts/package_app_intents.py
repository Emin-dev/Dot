#!/usr/bin/env python3
"""Package native App Intents build products; never launch or register the app."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from check_app_intents import check_app_intents


def prepare(work, sources):
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if any(work.iterdir()):
        raise ValueError("App Intents intermediate directory must be fresh")
    output_map, receipt, source_list, constants = {}, {}, [], []
    for index, source in enumerate(sources):
        path = Path(source).resolve(strict=True)
        if path.suffix != ".swift" or str(path) in receipt:
            raise ValueError("unique Swift source files required")
        const = str(work / (str(index) + ".swiftconstvalues"))
        output_map[str(source)] = {"const-values": const}
        receipt[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
        source_list.append(str(path))
        constants.append(const)
    if not source_list:
        raise ValueError("Swift sources required")
    (work / "output-map.json").write_text(json.dumps(output_map))
    (work / "protocols.json").write_text(json.dumps(["AppIntent", "AppShortcutsProvider"]))
    (work / "sources.txt").write_text("\n".join(source_list) + "\n")
    (work / "const-values.txt").write_text("\n".join(constants) + "\n")
    (work / "source-hashes.json").write_text(json.dumps(receipt))


def _check_sources(work):
    for path, expected in json.loads((work / "source-hashes.json").read_bytes()).items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest() != expected:
            raise ValueError("Swift source changed during App Intents packaging")


def extract(work, app, target, deployment):
    work, app = Path(work).resolve(), Path(app).absolute()
    if not re.fullmatch(r"(?:arm64|x86_64)-apple-macosx?" + re.escape(deployment), target):
        raise ValueError("matching macOS target and deployment version required")
    _check_sources(work)
    # These are compiler outputs from this fresh build, not cached metadata from
    # a previous app. A missing constant file must fail before running extraction.
    for filename in (work / "const-values.txt").read_text().splitlines():
        if not Path(filename).is_file():
            raise ValueError("compiler did not emit all App Intents constant files")
    resources = app / "Contents/Resources"
    for directory in (app, app / "Contents", resources):
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError("regular app resource directory required")
    metadata = resources / "Metadata.appintents"
    if metadata.is_symlink():
        raise ValueError("App Intents metadata cannot be a symlink")
    if metadata.exists():
        shutil.rmtree(metadata)

    def output(*args):
        return subprocess.check_output(args, text=True).strip()

    compiler = Path(output("xcrun", "--find", "swiftc"))
    toolchain = compiler.parent.parent.parent
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    version = re.search(r"^Build version (\S+)$", output("xcodebuild", "-version"), re.MULTILINE)
    if not version:
        raise ValueError("Xcode build version unavailable")
    subprocess.run([
        "xcrun", "appintentsmetadataprocessor", "--output", str(resources),
        "--toolchain-dir", str(toolchain), "--module-name", "Dot", "--sdk-root", sdk,
        "--xcode-version", version[1], "--platform-family", "macOS",
        "--deployment-target", deployment, "--target-triple", target,
        "--source-file-list", str(work / "sources.txt"),
        "--swift-const-vals-list", str(work / "const-values.txt"), "--force"
    ], check=True)
    subprocess.run([
        "xcrun", "appintentsnltrainingprocessor", "--infoplist-path", str(app / "Contents/Info.plist"),
        "--temp-dir-path", str(work / "ssu"), "--bundle-id", "app.dot.local",
        "--product-path", str(resources), "--extracted-metadata-path", str(metadata),
        "--archive-ssu-assets"
    ], check=True)
    _check_sources(work)
    # The native trainer can return zero after an archive error. Require the
    # actual phrase/locale/archive products before either build script signs.
    return check_app_intents(app)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--work-dir", type=Path, required=True)
    prep.add_argument("sources", nargs="+")
    package = commands.add_parser("extract")
    package.add_argument("--work-dir", type=Path, required=True)
    package.add_argument("--app", type=Path, required=True)
    package.add_argument("--target", required=True)
    package.add_argument("--deployment-target", required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.work_dir, args.sources)
        else:
            print(json.dumps(extract(args.work_dir, args.app, args.target, args.deployment_target), sort_keys=True))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, "App Intents packaging failed: " + str(error) + "\n")

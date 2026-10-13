#!/usr/bin/env python3
"""Validate dot's packaged App Intents metadata without launching or registering it.

This verifies the build artifact, not Siri/Shortcuts discovery on a user's Mac.
Run after metadata extraction and before signing; signature verification remains
a separate packaging check. The native metadata format is checked deliberately:
a toolchain format change requires reviewing this check against fresh extraction.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import stat


INTENTS = {
    "TalkToDotIntent": ("Talk to dot", "Talk to ${applicationName}"),
    "StopDotIntent": ("Stop dot", "Stop ${applicationName}"),
    "ShowDotIntent": ("Show dot", "Show ${applicationName}"),
}


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _directory(path):
    _require(stat.S_ISDIR(path.lstat().st_mode), "regular bundle directories required")


def _read(path, maximum=1_000_000):
    info = path.lstat()
    _require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= maximum,
             "bounded regular metadata files required")
    return path.read_bytes()


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value, "duplicate JSON key")
        value[key] = item
    return value


def _json(data):
    value = json.loads(data, object_pairs_hook=_unique_object)
    _require(isinstance(value, dict), "metadata object required")
    return value


def check_app_intents(app, bundle_identifier="app.dot.local", module="Dot"):
    app = Path(app)
    _require(app.suffix == ".app", "macOS app bundle required")
    contents = app / "Contents"
    resources = contents / "Resources"
    metadata = resources / "Metadata.appintents"
    for path in (app, contents, contents / "MacOS", resources, metadata):
        _directory(path)
    info = plistlib.loads(_read(contents / "Info.plist"))
    _require(isinstance(info, dict), "Info.plist dictionary required")
    _require(info.get("CFBundleIdentifier") == bundle_identifier, "wrong app bundle identifier")
    _require(info.get("CFBundlePackageType") == "APPL", "wrong bundle package type")
    _require(info.get("CFBundleExecutable") == "Dot", "wrong app executable")
    _require(bool(info.get("CFBundleDisplayName") or info.get("CFBundleName")), "application name missing")
    _require(info.get("CFBundleDevelopmentRegion") == "en", "English development region required for phrase training")
    executable = contents / "MacOS" / "Dot"
    executable_info = executable.lstat()
    _require(stat.S_ISREG(executable_info.st_mode) and executable_info.st_size > 0
             and executable_info.st_mode & 0o111, "packaged executable missing")

    version = _json(_read(metadata / "version.json"))
    _require(version.get("version") == "3.0" and bool(version.get("toolsVersion")),
             "unreviewed App Intents metadata version")
    data = _read(metadata / "extract.actionsdata")
    extracted = _json(data)
    _require(extracted.get("version") == 1, "unreviewed extracted actions format")
    generator = extracted.get("generator", {})
    _require(isinstance(generator, dict) and generator.get("name") == "xcode-tools"
             and generator.get("version") == version["toolsVersion"], "extractor provenance mismatch")
    actions = extracted.get("actions")
    _require(isinstance(actions, dict) and set(actions) == set(INTENTS), "expected exactly three dot intents")
    for identifier, (title, _) in INTENTS.items():
        action = actions[identifier]
        _require(isinstance(action, dict), "invalid intent record")
        _require(action.get("identifier") == identifier
                 and action.get("fullyQualifiedTypeName") == module + "." + identifier,
                 "wrong intent identity or Swift module")
        _require(action.get("isDiscoverable") is True
                 and action.get("visibilityMetadata", {}).get("isDiscoverable") is True
                 and action.get("visibilityMetadata", {}).get("assistantOnly") is False,
                 "intent is not discoverable")
        _require(action.get("openAppWhenRun") is True and action.get("supportedModes") == 2,
                 "intent must use the foreground app coordinator")
        _require(action.get("parameters") == [], "unexpected intent input surface")
        _require(action.get("title", {}).get("key") == title, "intent title missing")

    _require(bool(extracted.get("autoShortcutProviderMangledName")), "App Shortcuts provider missing")
    shortcuts = extracted.get("autoShortcuts")
    _require(isinstance(shortcuts, list) and len(shortcuts) == len(INTENTS), "App Shortcuts missing")
    seen = set()
    for shortcut in shortcuts:
        _require(isinstance(shortcut, dict), "invalid shortcut record")
        identifier = shortcut.get("actionIdentifier")
        _require(identifier in INTENTS and identifier not in seen, "unexpected or duplicated shortcut")
        seen.add(identifier)
        title, phrase = INTENTS[identifier]
        templates = shortcut.get("phraseTemplates")
        _require(isinstance(templates, list)
                 and any(isinstance(item, dict) and item.get("key") == phrase for item in templates),
                 "application-name Siri phrase missing")
        _require(shortcut.get("shortTitle", {}).get("key") == title
                 and bool(shortcut.get("systemImageName")), "shortcut presentation missing")
    # The native trainer can exit zero after failing to archive an empty set of
    # locales. Check its products, not merely its process status. This is an
    # artifact smoke check; it does not substitute for Siri recognition testing.
    training = _read(metadata / "root.ssu.yaml").decode("utf-8")
    _require("bundleIdentifier: " + bundle_identifier in training
             and "locale: en" in training, "English shortcut training missing")
    for identifier, (_, phrase) in INTENTS.items():
        _require("name: " + identifier + "_" in training
                 and phrase.replace("${applicationName}", "${+applicationName}") in training,
                 "trained shortcut phrase missing")
    _directory(metadata / "nlu")
    archive = _read(metadata / "nlu/nlu.lzfse", maximum=16_000_000)
    _require(len(archive) > 8 and archive[:4] in (b"bvx2", b"bvx1", b"bvxn", b"bvx-"),
             "native trained language archive missing")
    return {"status": "packaged_metadata_verified", "intents": sorted(actions),
            "shortcut_count": len(shortcuts), "tools_version": version["toolsVersion"],
            "metadata_sha256": hashlib.sha256(data).hexdigest(),
            "trained_archive_sha256": hashlib.sha256(archive).hexdigest(),
            "siri_registration_tested": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check_app_intents(args.app), sort_keys=True))
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
        parser.exit(1, "App Intents check failed: " + str(error) + "\n")

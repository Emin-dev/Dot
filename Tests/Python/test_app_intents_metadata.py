import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from check_app_intents import check_app_intents, INTENTS
from package_app_intents import prepare, extract
from unittest.mock import patch


class AppIntentsPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "An Intent.swift"
        self.source.write_text("import AppIntents\n")
        self.work = self.root / "intermediates"

    def test_fresh_map_keeps_exact_compiler_input_keys_and_persistent_outputs(self):
        prepare(self.work, [str(self.source)])
        mapping = json.loads((self.work / "output-map.json").read_bytes())
        self.assertEqual(set(mapping), {str(self.source)})
        const = mapping[str(self.source)]["const-values"]
        self.assertEqual((self.work / "const-values.txt").read_text(), const + "\n")
        self.assertEqual((self.work / "sources.txt").read_text(), str(self.source.resolve()) + "\n")
        self.assertEqual(Path(const).parent, self.work.resolve())

    def test_reusing_intermediates_fails_instead_of_accepting_stale_constants(self):
        prepare(self.work, [str(self.source)])
        with self.assertRaises(ValueError): prepare(self.work, [str(self.source)])

    def test_source_change_blocks_extraction_before_native_tools(self):
        prepare(self.work, [str(self.source)])
        self.source.write_text("changed source")
        with patch("package_app_intents.subprocess.run") as run:
            with self.assertRaisesRegex(ValueError, "source changed"):
                extract(self.work, self.root / "Dot.app", "arm64-apple-macosx15.0", "15.0")
            run.assert_not_called()

    def test_missing_compiler_outputs_block_extraction(self):
        prepare(self.work, [str(self.source)])
        with patch("package_app_intents.subprocess.run") as run:
            with self.assertRaisesRegex(ValueError, "did not emit"):
                extract(self.work, self.root / "Dot.app", "arm64-apple-macosx15.0", "15.0")
            run.assert_not_called()

    def test_extractor_deployment_must_match_compilation(self):
        with self.assertRaisesRegex(ValueError, "matching macOS"):
            extract(self.work, self.root / "Dot.app", "arm64-apple-macosx26.4", "15.0")


class AppIntentsMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Dot.app"
        self.contents = self.app / "Contents"
        self.metadata = self.contents / "Resources/Metadata.appintents"
        self.metadata.mkdir(parents=True)
        (self.contents / "MacOS").mkdir()
        executable = self.contents / "MacOS/Dot"
        executable.write_bytes(b"unexecuted fixture")
        executable.chmod(0o755)
        self.info = {"CFBundleIdentifier": "app.dot.local", "CFBundlePackageType": "APPL",
                     "CFBundleExecutable": "Dot", "CFBundleName": "Dot", "CFBundleDevelopmentRegion": "en"}
        (self.metadata / "version.json").write_text(json.dumps({"version": "3.0", "toolsVersion": "fixture"}))
        self.data = {"version": 1, "generator": {"name": "xcode-tools", "version": "fixture"},
                     "actions": {}, "autoShortcutProviderMangledName": "fixture", "autoShortcuts": []}
        for identifier, (title, phrase) in INTENTS.items():
            self.data["actions"][identifier] = {
                "identifier": identifier, "fullyQualifiedTypeName": "Dot." + identifier,
                "isDiscoverable": True, "visibilityMetadata": {"isDiscoverable": True, "assistantOnly": False},
                "openAppWhenRun": True, "supportedModes": 2, "parameters": [], "title": {"key": title}}
            self.data["autoShortcuts"].append({"actionIdentifier": identifier,
                "phraseTemplates": [{"key": phrase}], "shortTitle": {"key": title}, "systemImageName": "fixture"})
        self.training = "bundleIdentifier: app.dot.local\nlocale: en\n" + "\n".join(
            "name: " + identifier + "_0\n" + phrase.replace("${applicationName}", "${+applicationName}")
            for identifier, (_, phrase) in INTENTS.items())
        (self.metadata / "nlu").mkdir()
        (self.metadata / "nlu/nlu.lzfse").write_bytes(b"bvx2unexecuted fixture")

    def write(self):
        (self.contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.metadata / "extract.actionsdata").write_text(json.dumps(self.data))
        (self.metadata / "root.ssu.yaml").write_text(self.training)

    def audit(self):
        self.write()
        return check_app_intents(self.app)

    def test_complete_packaged_fixture_does_not_claim_siri_registration(self):
        result = self.audit()
        self.assertEqual(result["shortcut_count"], 3)
        self.assertEqual(result["status"], "packaged_metadata_verified")
        self.assertFalse(result["siri_registration_tested"])

    def test_missing_metadata_fails(self):
        self.write()
        (self.metadata / "extract.actionsdata").unlink()
        with self.assertRaises(OSError): check_app_intents(self.app)

    def test_missing_or_extra_intent_fails(self):
        del self.data["actions"]["TalkToDotIntent"]
        with self.assertRaises(ValueError): self.audit()

    def test_hidden_or_background_intent_fails(self):
        for field, value in (("isDiscoverable", False), ("openAppWhenRun", False), ("supportedModes", 1)):
            original = self.data["actions"]["TalkToDotIntent"][field]
            self.data["actions"]["TalkToDotIntent"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.audit()
            self.data["actions"]["TalkToDotIntent"][field] = original

    def test_wrong_binary_module_fails(self):
        self.data["actions"]["TalkToDotIntent"]["fullyQualifiedTypeName"] = "Fixture.TalkToDotIntent"
        with self.assertRaises(ValueError): self.audit()

    def test_unexpected_parameters_fail(self):
        self.data["actions"]["TalkToDotIntent"]["parameters"] = [{"name": "commands"}]
        with self.assertRaises(ValueError): self.audit()

    def test_missing_provider_fails(self):
        del self.data["autoShortcutProviderMangledName"]
        with self.assertRaises(ValueError): self.audit()

    def test_plain_phrase_without_application_name_fails(self):
        self.data["autoShortcuts"][0]["phraseTemplates"] = [{"key": "Talk to Dot"}]
        with self.assertRaises(ValueError): self.audit()

    def test_duplicate_shortcut_fails(self):
        self.data["autoShortcuts"][1] = self.data["autoShortcuts"][0]
        with self.assertRaises(ValueError): self.audit()

    def test_wrong_bundle_identity_fails(self):
        self.info["CFBundleIdentifier"] = "app.unrelated"
        with self.assertRaises(ValueError): self.audit()

    def test_unreviewed_format_or_provenance_fails(self):
        self.data["generator"]["version"] = "other-toolchain"
        with self.assertRaises(ValueError): self.audit()

    def test_missing_development_locale_fails(self):
        del self.info["CFBundleDevelopmentRegion"]
        with self.assertRaises(ValueError): self.audit()

    def test_empty_training_corpuses_fail_even_if_extraction_passed(self):
        self.training = "bundleIdentifier: app.dot.local\ntraining: []"
        with self.assertRaises(ValueError): self.audit()

    def test_unarchived_training_fails_even_if_native_trainer_exited_zero(self):
        self.write()
        (self.metadata / "nlu/nlu.lzfse").unlink()
        with self.assertRaises(OSError): check_app_intents(self.app)

    def test_metadata_symlink_fails(self):
        self.write()
        path = self.metadata / "extract.actionsdata"
        target = Path(self.temp.name) / "external.json"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError): check_app_intents(self.app)

    def test_duplicate_json_key_fails(self):
        self.write()
        (self.metadata / "extract.actionsdata").write_text('{"actions":{},"actions":{}}')
        with self.assertRaises(ValueError): check_app_intents(self.app)

    def test_oversized_metadata_fails_before_decoding(self):
        self.write()
        with (self.metadata / "extract.actionsdata").open("wb") as file:
            file.truncate(1_000_001)
        with self.assertRaises(ValueError): check_app_intents(self.app)


if __name__ == "__main__":
    unittest.main()

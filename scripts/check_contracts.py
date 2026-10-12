#!/usr/bin/env python3
"""Portable static guardrails. These are not Swift compilation/runtime tests."""
from pathlib import Path
import plistlib, re, xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[1]
read = lambda p: (root / p).read_text()
engine, speech, chat = map(read, ['src/Engine.swift', 'src/Speech.swift', 'src/ChatView.swift'])
checks = {
    'no borrowed runtime or broad process kills': not re.search(r'pkill|llama-server|DOT_SPLASH_URL|splashURL', engine),
    'bundled native recognizer required': 'WhisperRecognizer.available' in speech and 'SFSpeechRecognizer' not in speech,
    'capture task rejects stale generation': 'guard let self, !Task.isCancelled, self.gate.accepts(id)' in chat,
    'capture checks cancellation before permissions': re.search(r'func start\(id: UUID\) async \{\s*guard !Task.isCancelled', speech) is not None,
    'capture checks cancellation after setup and microphone await': speech.count('guard !Task.isCancelled, capture == id') >= 3,
    'silence timer runs during menu tracking': 'RunLoop.main.add(timer, forMode: .common)' in speech,
    'redirects denied': 'completionHandler(nil)' in engine,
    'truncated SSE rejected': 'guard sawDone else { throw EngineError.response }' in engine,
    'thinking preserved': '"enable_thinking": true' in engine and '"reasoning_effort": "low"' in engine,
    'packaging treats warnings as errors': '-warnings-as-errors' in read('build.sh'),
    'release never publishes an incomplete development app': 'action-gh-release' not in read('.github/workflows/release.yml') and 'exit 1' in read('.github/workflows/release.yml'),
    'no stale tracked main app in source snapshot': not (root / 'Dot.dmg').exists(),
    'shared Xcode scheme exists': (root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme').exists(),
    'no separate app settings or setup surfaces': not any(token in read('src/App.swift') + chat for token in ['Settings {', 'WindowGroup', '.popover(', '.sheet(', 'NSOpenPanel', 'ConnectionView']),
    'one reusable companion surface': 'CompanionSurface()' in read('src/App.swift') and 'if let panel { window = panel }' in read('src/CompanionPanel.swift'),
    'no production model downloader': not (root / 'src/ModelDownload.swift').exists() and 'URLSession' not in read('src/OfflinePreparation.swift') and 'AssetTransfer' not in read('src/OfflinePreparation.swift'),
    'bundled model index has no download URLs': 'https://' not in read('Resources/bundled-models.json'),
    'complete assembly requires all models': '${DOT_MODEL_PAYLOAD:?' in read('scripts/build_complete.sh') and 'MODEL_DOWNLOAD=true' not in read('scripts/build_complete.sh'),
    'installer requires native offline acceptance': 'offline_acceptance.py' in read('scripts/package_complete.sh') and 'hdiutil create' not in read('scripts/build_complete.sh'),
    'real Xcode XCTest target': 'com.apple.product-type.bundle.unit-test' in read('Dot.xcodeproj/project.pbxproj'),
}
plistlib.loads((root / 'Resources/Info.plist').read_bytes())
ET.parse(root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme')
for label, result in checks.items(): print(('PASS' if result else 'FAIL') + ': ' + label)
if not all(checks.values()): raise SystemExit(1)
print(f'{len(checks)} static guardrails passed; Swift/macOS execution is separate.')

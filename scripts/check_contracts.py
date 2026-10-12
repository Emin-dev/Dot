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
    'release publishes current output path': 'files: build/Dot.dmg' in read('.github/workflows/release.yml'),
    'no stale tracked main app in source snapshot': not (root / 'Dot.dmg').exists(),
    'shared Xcode scheme exists': (root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme').exists(),
    'real Xcode XCTest target': 'com.apple.product-type.bundle.unit-test' in read('Dot.xcodeproj/project.pbxproj'),
}
plistlib.loads((root / 'Resources/Info.plist').read_bytes())
ET.parse(root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme')
for label, result in checks.items(): print(('PASS' if result else 'FAIL') + ': ' + label)
if not all(checks.values()): raise SystemExit(1)
print(f'{len(checks)} static guardrails passed; Swift/macOS execution is separate.')

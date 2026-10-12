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
    'voice errors never request external setup': all(x not in read('src/BionicVoice.swift') for x in ['existing Python packages', 'Check the local voice setup']),
    'product voice has no unreachable built-in routing': 'VoiceMode' not in read('src/BionicVoice.swift') and 'NativeTTSManager' not in read('src/BionicVoice.swift') and 'try bionic.start(id: id, root: root)' in read('src/BionicVoice.swift'),
    'removed bubble state and private response accumulator': 'bubbleHovered' not in chat + read('src/App.swift') and 'private var answer = ""' in chat and '@Published private(set) var answer' not in chat,
    'manual audio diagnostic remains available': 'final class NativeTTSManager' in speech and 'NativeTTSManager()' in read('tests/main.swift'),
    'no persistent visual caption; accessible errors remain': 'Text(status)' not in chat and 'Text(detail)' not in chat and 'CompanionAccessibility.value(status: status, detail: detail' in chat,
    'compact issue and screen indicators remain': 'exclamationmark.circle.fill' in chat and 'eye.fill' in chat,
    'zero-progress and paused readiness stay visible': 'Circle().stroke(Color.accentColor.opacity(0.45)' in chat and 'pause.circle.fill' in chat and 'hourglass' in chat,
    'isolated voice Python explicitly disables bytecode writes': 'python.path, "-I", "-B", "-u", helper.path' in read('src/BionicVoice.swift'),
    'voice sandbox uses private writes and OpenMP environment fallback': '(deny file-write*)' in read('Resources/Voice/voice.sb') and '(subpath (param "DOT_OUTPUT"))' in read('Resources/Voice/voice.sb') and '(deny file-read-data (literal "/tmp") (literal "/private/tmp"))' in read('Resources/Voice/voice.sb') and '"DOT_OUTPUT="' in read('src/BionicVoice.swift'),
    'installer requires native offline acceptance': 'offline_acceptance.py' in read('scripts/package_complete.sh') and 'hdiutil create' not in read('scripts/build_complete.sh'),
    'owned runtime transport is TLS pinned': 'https://127.0.0.1:' in read('src/BundledSplash.swift') and 'RuntimeCertificatePin.matches' in engine,
    'runtime listener retained across child exec': 'pass_fds=(listener.fileno(),)' in read('Resources/Runtime/dot_runtime.py') and 'relay.close()' in read('Resources/Runtime/dot_runtime.py'),
    'status and SSE enforce client byte budgets': 'boundedStatus' in engine and 'BoundedSSELines()' in engine and 'ResponseTextBudget()' in engine,
    'real Xcode XCTest target': 'com.apple.product-type.bundle.unit-test' in read('Dot.xcodeproj/project.pbxproj'),
}
plistlib.loads((root / 'Resources/Info.plist').read_bytes())
ET.parse(root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme')
for label, result in checks.items(): print(('PASS' if result else 'FAIL') + ': ' + label)
if not all(checks.values()): raise SystemExit(1)
print(f'{len(checks)} static guardrails passed; Swift/macOS execution is separate.')

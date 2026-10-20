#!/usr/bin/env python3
"""Portable static guardrails. These are not Swift compilation/runtime tests."""
from pathlib import Path
import ast, plistlib, re, xml.etree.ElementTree as ET
def runtime_handoff_contract(source):
    """Static shape check; executable handoff tests establish runtime behavior."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return False
    def matches(node, expression):
        return ast.dump(node) == ast.dump(ast.parse(expression, mode='eval').body)
    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
    spawns = [node for node in calls if matches(node.func, 'subprocess.Popen')]
    if len(spawns) != 1 or not any(matches(node, 'relay.close()') for node in calls):
        return False
    spawn = spawns[0]
    for scope in (node for node in ast.walk(tree) if isinstance(node, ast.With)):
        for item in scope.items:
            if (not matches(item.context_expr, '_process.api_key_pipe(api_key)')
                or not isinstance(item.optional_vars, ast.Name)):
                continue
            if not any(node is spawn for statement in scope.body for node in ast.walk(statement)):
                continue
            inherited = next((keyword.value for keyword in spawn.keywords if keyword.arg == 'pass_fds'), None)
            if not isinstance(inherited, ast.Tuple) or len(inherited.elts) != 2:
                return False
            required = {ast.dump(ast.parse('listener.fileno()', mode='eval').body),
                        ast.dump(ast.Name(id=item.optional_vars.id, ctx=ast.Load()))}
            return {ast.dump(node) for node in inherited.elts} == required
    return False


root = Path(__file__).resolve().parents[1]
# A missing file yields empty text: one deletion can only fail its own guard, never
# abort the whole run before the remaining guards report.
read = lambda p: (root / p).read_text() if (root / p).is_file() else ''
swift_sources = ''.join(path.read_text() for path in sorted((root / 'src').glob('*.swift')))
engine, speech, chat = map(read, ['src/Engine.swift', 'src/Speech.swift', 'src/ChatView.swift'])
checks = {
    'no borrowed runtime or broad process kills': not re.search(r'pkill|llama-server|DOT_SPLASH_URL|splashURL', engine),
    'bundled native recognizer required': 'WhisperRecognizer.available' in speech and 'SFSpeechRecognizer' not in speech,
    'capture task rejects stale generation': 'guard let self, !Task.isCancelled, self.gate.accepts(id)' in chat,
    'capture checks cancellation before permissions': re.search(r'func start\(id: UUID, settings: VoiceTimingSettings, invitation: Bool\) async \{\s*guard !Task.isCancelled', speech) is not None,
    'capture checks cancellation after setup and microphone await': speech.count('guard continueStarting(id) else { return }') >= 5 and 'guard capture == id else { return false }' in speech and 'guard !Task.isCancelled else { endCapture(id, reason: .intentionalCancellation)' in speech,
    'silence timer runs during menu tracking': 'RunLoop.main.add(timer, forMode: .common)' in speech,
    'redirects denied': 'completionHandler(nil)' in engine,
    'truncated SSE rejected': 'guard sawDone else { throw EngineError.response }' in engine,
    'thinking preserved': '"enable_thinking": true' in engine and '"reasoning_effort": "low"' in engine,
    'packaging treats warnings as errors': '-warnings-as-errors' in read('build.sh'),
    'release never publishes an incomplete development app': 'action-gh-release' not in read('.github/workflows/release.yml') and 'exit 1' in read('.github/workflows/release.yml'),
    'no stale tracked main app in source snapshot': not (root / 'Dot.dmg').exists(),
    'shared Xcode scheme exists': (root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme').exists(),
    'native options remain in compact companion menu': not any(token in read('src/App.swift') + chat for token in ['Settings {', 'WindowGroup', '.popover(', '.sheet(', 'NSOpenPanel', 'ConnectionView']),
    'one reusable companion surface': 'CompanionSurface()' in read('src/App.swift') and 'if let panel { window = panel }' in read('src/CompanionPanel.swift'),
    'production model downloader is manifest-verified': (
        'ModelProvisioner' in read('src/OfflinePreparation.swift')
        and 'huggingface.co/mlx-community/Qwen3.8-27B-4bit' in read('src/OfflinePreparation.swift')
        and 'huggingface.co/incoai/Qwen3.8-27B-DFlash2' in read('src/OfflinePreparation.swift')
        and 'OfflinePayload.verifyHash' in read('src/OfflinePreparation.swift')
        and 'safePath' in read('src/OfflinePreparation.swift')
        and 'getDownloadURL' not in read('src/OfflinePreparation.swift')
    ),
    'bundled model index has no download URLs': 'https://' not in read('Resources/bundled-models.json'),
    'complete assembly requires all models': '${DOT_MODEL_PAYLOAD:?' in read('scripts/build_complete.sh') and 'MODEL_DOWNLOAD=true' not in read('scripts/build_complete.sh'),
    'voice errors never request external setup': all(x not in read('src/BionicVoice.swift') for x in ['existing Python packages', 'Check the local voice setup']),
    'product voice has no unreachable built-in routing': 'VoiceMode' not in read('src/BionicVoice.swift') and 'NativeTTSManager' not in read('src/BionicVoice.swift') and 'try bionic.start(id: id, root: root)' in read('src/BionicVoice.swift'),
    'readable reply has one read-only published owner': 'bubbleHovered' not in chat + read('src/App.swift') and '@Published private(set) var answer = ""' in chat and 'Text(model.answer.isEmpty' in read('src/TypedInteractionPanel.swift'),
    'manual audio diagnostic remains available': 'final class NativeTTSManager' in speech and 'NativeTTSManager()' in read('tests/main.swift'),
    'compact actual status and accessible errors remain': 'Text(shortStatus)' in chat and 'stt.timingSnapshot' in chat and 'CompanionAccessibility.value(status: status, detail: detail' in chat,
    'compact issue and screen indicators remain': 'exclamationmark.circle.fill' in chat and 'eye.fill' in chat,
    'zero-progress and paused readiness stay visible': 'Circle().stroke(Color.accentColor.opacity(0.45)' in chat and 'pause.circle.fill' in chat and 'hourglass' in chat,
    'voice launch uses the bundled native engine with a POSIX canonical private output': 'realpath(directory.path, nil)' in read('src/VoiceAudioReader.swift') and 'before.st_ino == after.st_ino' in read('src/VoiceAudioReader.swift') and 'appendingPathComponent("dot-voice")' in read('src/BionicVoice.swift') and 'FileManager.default.isExecutableFile(atPath: native.path)' in read('src/BionicVoice.swift') and 'sandbox-exec' not in read('src/BionicVoice.swift') and 'bionic_helper' not in read('src/BionicVoice.swift'),
    'shipped sources reference no retired Python runtime helper': all(retired not in swift_sources for retired in ['dot_source_fetch.py', 'bionic_helper.py', 'dot_search.py']),
    'retired Search resource directory is not shipped': not (root / 'Resources/Search').exists(),
    'installer requires native offline acceptance': 'offline_acceptance.py' in read('scripts/package_complete.sh') and 'hdiutil create' not in read('scripts/build_complete.sh'),
    'owned runtime transport is TLS pinned': 'https://127.0.0.1:' in read('src/BundledSplash.swift') and 'RuntimeCertificatePin.matches' in engine,
    'runtime listener and scoped credential pipe retained across child exec': runtime_handoff_contract(read('Resources/Runtime/dot_runtime.py')),
    'status and SSE enforce client byte budgets': 'boundedStatus' in engine and 'BoundedSSELines()' in engine and 'ResponseTextBudget()' in engine,
    'screen first grant rechecks access without prompt loops': 'permission.prepare(turn: turn, enabled: enabled, preflight: CGPreflightScreenCaptureAccess' in read('src/ScreenContext.swift') and 'requestPermission && CGRequestScreenCaptureAccess()' in read('src/ScreenContext.swift'),
    'runtime protocol reads available pipe bytes without waiting for EOF': 'Darwin.read(descriptor' in read('src/BundledSplash.swift') and 'O_NONBLOCK' in read('src/BundledSplash.swift') and 'FD_CLOEXEC' in read('src/BundledSplash.swift') and 'read(upToCount:' not in read('src/BundledSplash.swift'),
    'runtime startup timeout closes only current owned generation': re.search(r'let error = await failure\(\).*?guard token == expected, !Task.isCancelled.*?outcome=timeout.*?shutdown\(\).*?throw error', read('src/BundledSplash.swift'), re.S) is not None,
    'turn failure logging excludes cancellation and uses finite identifiers': 'error is CancellationError' in chat and '(error as? URLError)?.code == .cancelled' in chat and 'PipelineDiagnostic.failure(stage: actualStage, reason: reason' in chat and 'self.logFailure(error, stage: stage)' in chat,
    'voice native child receives only bounded private paths': 'attributes: [.posixPermissions: 0o700]' in read('src/BionicVoice.swift') and 'child.arguments = ["--root", base.path, "--output", requested.path, "--voice", voice]' in read('src/BionicVoice.swift') and 'child.standardError = FileHandle.nullDevice' in read('src/BionicVoice.swift') and 'child.environment = ["PATH": "/usr/bin:/bin"]' in read('src/BionicVoice.swift') and 'try? FileManager.default.removeItem(at: directory)' in read('src/BionicVoice.swift'),
    'screen permission precedes microphone and rechecks without another prompt': chat.index('self.screen.prepare(turn: id, requestPermission: !invitation)') < chat.index('await self.runtime.startCapture(id, self.voiceTiming, invitation)') and 'permission.mayCapture(turn: turn, preflight: CGPreflightScreenCaptureAccess)' in read('src/ScreenContext.swift'),
    'warmup starts only after accepted microphone capture and is reused': 'stt.onRecording =' in chat and speech.index('recording = true') < speech.index('onRecording?(id)') and 'try await self.warmup.wait(turn: id)' in chat and 'warmup.cancel()' in chat,
    'full integrity checks run in exactly two bounded verification branches': 'PayloadVerification.run(runtime: self.runtimeCheck' in read('src/OfflinePreparation.swift') and read('src/OfflinePreparation.swift').count('group.addTask {') == 2 and 'try await OfflinePayload.verifyHash(path' in read('src/OfflinePreparation.swift'),
    'placement never requests permission or sends pixels to inference': 'CGRequestScreenCaptureAccess' not in read('src/PlacementCapture.swift') and 'URLSession' not in read('src/PlacementCapture.swift') and 'EngineManager' not in read('src/PlacementCapture.swift'),
    'placement uses exact display and fails closed without a snapshot': 'content.displays.first(where: { $0.displayID == id })' in read('src/PlacementCapture.swift') and 'content.displays.first else' not in read('src/PlacementCapture.swift') and 'let snapshot, snapshot.valid' in read('src/RoamingCore.swift'),
    'placement honors persistent screen switch and shows local analysis': 'let eligible = !paused && model.screenEnabled' in read('src/App.swift') and 'model.placementCapturing' in chat and 'placementInvalidated?()' in chat,
    'placement bounds single-flight cadence and removes random targets': 'active == nil' in read('src/RoamingCore.swift') and 'nextAllowed = now + 10' in read('src/RoamingCore.swift') and 'unit()' not in read('src/RoamingCore.swift') and 'safePath(from: frame' in read('src/RoamingCore.swift'),
    'compact menu errors never display unbounded detail rows': 'CompanionIssue.menuHeader' in read('src/App.swift') and 'message.prefix(160)' not in read('src/App.swift') and 'Copy details' in read('src/InteractionCore.swift'),
    'primary companion remains compact without a scrolling surface': 'ScrollView' not in chat + read('src/App.swift') + read('src/CompanionPanel.swift'),
    'question followup requires final playback and validated intent': 'self.followup.generationFinished(turn: id, hasQuestion: question != nil)' in chat and 'tts.onFinalPlayback =' in chat and 'FinalPlaybackBarrier()' in read('src/BionicVoice.swift') and 'try questionIntent.completed()' in engine,
    'automatic listening never asks for permissions': 'requestPermission: !invitation' in chat and '!invitation && permission == .undetermined' in read('src/VoiceTiming.swift'),
    'top menu bar offers explicit quit without a new window': 'CompanionStatusMenu.make(target: self' in read('src/App.swift') and 'NSMenuItem(title: "Quit Dot", action: quit' in read('src/CompanionPanel.swift'),
    'screen freshness preserves acquisition through submission': 'let acquiredAt = ProcessInfo.processInfo.systemUptime' in read('src/ScreenContext.swift') and 'acquiredAt: acquiredAt' in read('src/ScreenContext.swift') and engine.count('capturedImage?.validateFreshness(now: clock())') == 2,
    'history separates generated text from final playback': 'recordAssistant(turn: id, event: .playbackCompleted)' in chat and 'ConversationGenerationStatus' in read('src/ConversationHistory.swift'),
    'explicit utility control region receives native events': 'controlHitTest?' in read('src/CompanionPanel.swift') and 'nativeControlPressed' in read('src/CompanionPanel.swift'),
    'real Xcode XCTest target': 'com.apple.product-type.bundle.unit-test' in read('Dot.xcodeproj/project.pbxproj'),
}
plistlib.loads((root / 'Resources/Info.plist').read_bytes())
ET.parse(root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme')
for label, result in checks.items(): print(('PASS' if result else 'FAIL') + ': ' + label)
if not all(checks.values()): raise SystemExit(1)
print(f'{len(checks)} static guardrails passed; Swift/macOS execution is separate.')

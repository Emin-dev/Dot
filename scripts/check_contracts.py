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
    'release publishes only the verified model-less app with a pinned runtime donor': (
        'package_default_release.sh' in read('.github/workflows/release.yml')
        and 'DONOR_SHA256' in read('.github/workflows/release.yml')
        and 'shasum -a 256 -c -' in read('.github/workflows/release.yml')
        and 'Dot.dmg' in read('.github/workflows/release.yml')
    ),
    'release pipeline runs the static contracts': 'scripts/check_contracts.py' in read('.github/workflows/release.yml'),
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
    'Dot knows it is heard and never forces a question': 'Never claim you cannot hear' in engine and '60%' not in engine and 'only when the comment genuinely needs' in read('src/ProactiveBehavior.swift'),
    'every British voice passes the voice handshake': 'DotVoice.british.contains(voice)' in read('src/InteractionCore.swift') and 'DotVoice.launchVoice(selected: selected, root: base)' in read('src/BionicVoice.swift'),
    'log noise is bounded and labelled honestly': (
        re.search(r'guard\s+signature\s*!=\s*lastHealthSignature\s+else\s*\{\s*return\s*\}', chat) is not None
        and 'engine.answering ? "ready"' in chat
        and len(re.findall(r'DiagnosticChatLogger\.record\(\s*role:\s*"system",\s*text:\s*"Context extraction skipped',
                           read('src/InteractionCore.swift'))) == 2
        and re.search(r'reason\s*!=\s*lastRoamRefusal', read('src/App.swift')) is not None
        and re.search(r'guard\s+snapshotSize\s*!=\s*size\s*\|\|\s*sourceModified\s*>\s*snapshotModified\s+else\s*\{\s*continue\s*\}',
                      read('src/DotLogSync.swift')) is not None
        and len(re.findall(r'DiagnosticChatLogger\.record\(', read('src/DotLogSync.swift'))) == 1
        and 'private func enqueueCurrentFiles()' in read('src/DotLogSync.swift')
        and 'private func enqueue(local: URL' in read('src/DotLogSync.swift')
        and 'dot-sync' not in read('src/DotLogSync.swift').partition('private func enqueueCurrentFiles()')[2].partition('private func enqueue(local: URL')[0]
    ),
    'offline core keeps speech and inference loopback-only': (
        'https://127.0.0.1:' in read('src/BundledSplash.swift')
        and '127.0.0.1' in engine
        and 'URLSession' not in read('src/BionicVoice.swift')
        and 'SFSpeechRecognizer' not in read('src/Speech.swift')
        and all(url not in read(name) for name in ('src/BionicVoice.swift', 'src/Speech.swift', 'src/WhisperRecognizer.swift')
                for url in ('http://', 'https://'))
    ),
    'first-launch model files are reused offline and re-hashed': (
        'if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,' in read('src/OfflinePreparation.swift')
        and 'Int64(size) == asset.bytes' in read('src/OfflinePreparation.swift')
        and 'OfflinePayload.verifyHash(path, bytes: asset.bytes, expected: asset.sha256)' in read('src/OfflinePreparation.swift')
        and 'ModelProvisioner.shared.ensureModels' in read('src/OfflinePreparation.swift')
    ),
    'model file mutations pass the R16 safety approver first': (
        chat.index('case .deleteFile(let path, _):') < chat.index('safetyRefusal(for: "delete file \\(path)")')
        and chat.index('safetyRefusal(for: command)') < chat.index('await Self.runShellCommand(command)')
    ),
    'memory list includes core facts and R5 key points': (
        'isMemoryListRequest(copyPhrase)' in chat and 'for tier in [MemoryTier.core, .keyPoints]' in chat
    ),
    'log sync is optional and silent when offline': (
        re.search(r'guard\s+let\s+token\s*=\s*token\(\)\s+else\s*\{', read('src/DotLogSync.swift')) is not None
        and re.search(r'state\.failed\(\s*remotePath:\s*entry\.remotePath,\s*now:\s*now\s*\)',
                      read('src/DotLogSync.swift')) is not None
        and 'NSAlert' not in read('src/DotLogSync.swift')
        and re.search(r'\bissue\s*=', read('src/DotLogSync.swift')) is None
    ),
    'R18 wake greeting is varied, time-aware and bounded': 'WakeGreeting.shouldGreet(awaySeconds: away' in chat and 'static let greetChance = 0.8' in read('src/ProactiveBehavior.swift') and 'shortestAbsence = 180.0' in read('src/ProactiveBehavior.swift') and 'longestAbsence = 600.0' in read('src/ProactiveBehavior.swift') and "speakDirect(\"I'm back.\")" not in chat,
    'R19 errors keep Dot living, show a banner and heal the engine': 'private let issueBanner = IssueBanner()' in read('src/App.swift') and read('src/App.swift').count('model.phase.isResting') >= 5 and 'model.phase == .idle' not in read('src/App.swift') and '.puzzled' not in chat and 'if issue == .engine { scheduleEngineHeal(for: message) }' in chat and 'ignoresMouseEvents = true' in read('src/CompanionPanel.swift'),
    'safety approver request fits its context and harness failures never count as refusals': 'with_n_ctx(NonZeroU32::new(CONTEXT_TOKENS))' in read('crates/dot-safety/src/main.rs') and 'json!({"error": reason})' in read('crates/dot-safety/src/main.rs') and 'process.standardError = FileHandle.nullDevice' in read('src/SafetyApprover.swift') and 'Self.recent(conversation)' in read('src/SafetyApprover.swift') and 'if let error = object["error"] as? String { return .unavailable(reason: error) }' in read('src/SafetyApprover.swift'),
    'an offline relaunch with the model on disk needs no download or free space': 'if DownloadBudget.needsDownload(total: plan.total_bytes, reusableBytes: reusable) {' in read('src/OfflinePreparation.swift'),
    'display sleep and lock never stop the one-time model download': read('src/App.swift').count('OfflinePreparation.shared.pause(keepingDownload: true)') == 2 and 'if keepingDownload, state == .checking, detail != nil { return }' in read('src/OfflinePreparation.swift'),
    'R20 idle self-reflection is a short spoken note and never touches the clipboard': 'performReflectionAndWriteToAntigravity(copyToClipboard: false)' in chat and 'guard copyToClipboard else { return Self.shortNote(wroteFile: wroteFile) }' in read('src/InteractionCore.swift'),
    'R19 banner is wired and a healed engine clears the error': re.search(r'model\.\$phase\.combineLatest\(preparation\.\$state\)\s+\.receive\(on: RunLoop\.main\)\.sink \{ \[weak self\] phase, readiness in\s+Task \{ @MainActor in self\?\.showIssue\(phase: phase, readiness: readiness\) \}', read('src/App.swift')) is not None and re.search(r'if answered \{\s+self\.issue = nil; self\.phase = \.idle', chat) is not None,
    'safety approver context is 2,048 tokens and trims the oldest conversation to fit': 'const CONTEXT_TOKENS: u32 = 2048;' in read('crates/dot-safety/src/main.rs') and '.with_n_batch(CONTEXT_TOKENS)' in read('crates/dot-safety/src/main.rs') and 'conversation = &conversation[cut..];' in read('crates/dot-safety/src/main.rs') and 'if tokens.len() <= PROMPT_TOKENS {' in read('crates/dot-safety/src/main.rs') and re.search(r'static let conversationCharacters = 3_000\n', read('src/SafetyApprover.swift')) is not None and re.search(r'static let actionCharacters = 1_000\n', read('src/SafetyApprover.swift')) is not None,
    'a wake or second retry never restarts the running download': 'if state == .checking, work != nil, !resumeRequested { return }' in read('src/OfflinePreparation.swift'),
    'idle reflection returns before any clipboard write': (lambda f: f.index('guard copyToClipboard else { return Self.shortNote(wroteFile: wroteFile) }') < f.index('ClipboardIntelligence.write(suggestion)'))(read('src/InteractionCore.swift').partition('public func performReflectionAndWriteToAntigravity(')[2]) if 'ClipboardIntelligence.write(suggestion)' in read('src/InteractionCore.swift').partition('public func performReflectionAndWriteToAntigravity(')[2] else False,
    'Remove Dot never returns before leaving the command on the clipboard': 'if opened { return }' not in read('src/App.swift').partition('func removeDotCompletely()')[2].partition('fallback.runModal()\n    }')[0],
    'typed text, clipboard text and screen text never reach the public log': 'DiagnosticChatLogger.record(role: "user", text: Self.loggableUserText(text))' in chat and 'target: "\\(textToType.count) characters, text not logged"' in chat and 'logAs: "I found \\(lines.count) lines of text on screen (text not logged).")' in chat and 'logAs: "Read the clipboard aloud (\\(content.count) characters, text not logged).")' in chat and 'guard !holdsConcealedItem else { return nil }' in read('src/InteractionCore.swift') and "Typed '\\(text)'" not in read('src/InteractionCore.swift') and 'logAs: "I offered help with a persistent error in' in chat and 'for \\(Int(elapsed))s: \\"\\(signature)\\""' not in read('src/InteractionCore.swift'),
    'log lines are masked for secrets and personal details and capped in size': 'LogRedaction.capped(LogRedaction.masked(trimmed))' in read('src/InteractionCore.swift') and all(m in read('src/InteractionCore.swift') and m in read('scripts/redact_log.pl') for m in ('hf_[A-Za-z0-9]{20,}', '(?!git@)', '(?!Shared', 'mysql[a-z]*', '[sr]k_(?:live|test)_')),
    'R19 every error reaches the uploaded log': 'DiagnosticChatLogger.record(role: "dot (error)", text: "\\(message) [preparation]")' in read('src/OfflinePreparation.swift') and '[voice]")' in chat and 'verifyOnLaunch(beforeAlert: { DotLogSync.shared.start() })' in read('src/App.swift'),
    'the log token is read from Keychain once per launch': 'if let cachedToken { return cachedToken }' in read('src/DotLogSync.swift') and 'keychainDeclined = true' in read('src/DotLogSync.swift'),
    'only a movement verb or a bare direction moves Dot': 'static func detectMovementCommand(_ text: String) -> DotMovementCommand? {' in chat and '} else if !bareMovementPhrases.contains(clean) {' in chat and 'if otherMovementTargets.contains(where: { clean.contains($0) }) { return nil }' in chat and 'clean.contains("up")' not in chat.partition('static func detectMovementCommand(')[2].partition('func handleTaskProgress(')[0] and 'testMovementNeedsAVerbOrABareDirection' in read('Tests/DotCoreTests/TypedInteractionTests.swift'),
    'speaking resumes only the music Dot paused': 'return error == nil && result.booleanValue' in read('src/InteractionCore.swift') and 'Self.pauseIfPlaying("Music")' in read('src/InteractionCore.swift') and 'to if player state is playing then pause' not in read('src/InteractionCore.swift'),
    'the model download resumes: verified parts are reused and cancels keep resume data': '// A part verified on an earlier attempt or launch is reused, never fetched again.' in read('src/OfflinePreparation.swift') and 'task?.cancel(byProducingResumeData:' in read('src/OfflinePreparation.swift') and '!(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)' in read('src/OfflinePreparation.swift'),
    'a refused resume is deleted and retried fresh': 'throw PartHTTPFailure(status: response?.statusCode ?? 0, resumed: resumeData != nil)' in read('src/OfflinePreparation.swift') and 'if http.resumed, attempt < 5 { continue }' in read('src/OfflinePreparation.swift'),
    'the free-space check counts purgeable space like Finder': '.volumeAvailableCapacityForImportantUsageKey' in read('src/OfflinePreparation.swift') and '.systemFreeSize' not in read('src/OfflinePreparation.swift'),
    'removal works offline and clears the per-app /var/folders caches': 'let offlineCommand = "DOT_INSTALL_DIR=' in read('src/App.swift') and 'for darwin_dir in DARWIN_USER_CACHE_DIR DARWIN_USER_TEMP_DIR; do' in read('scripts/uninstall-dot.sh'),
    'lock screen locks instead of sleeping the Mac, and interactive screenshots keep Dot hidden': 'keystroke \\"q\\" using {control down, command down}' in read('src/InteractionCore.swift') and 'to sleep"' not in read('src/InteractionCore.swift').partition('case .lockScreen:')[2].partition('case .findFile')[0] and 'self?.hideTemporarilyForScreenshot(seconds: 10)' in read('src/App.swift'),
    'page reading works with default browser settings and never reads Dot itself': 'set pageText to text of curTab' in read('src/InteractionCore.swift') and 'do JavaScript' not in read('src/InteractionCore.swift') and 'let previous = InPlaceAppTyping.lastExternalApplication()' in read('src/InteractionCore.swift') and 'message.localizedCaseInsensitiveContains("javascript")' in read('src/InteractionCore.swift'),
    'the installer warns about the hardware minimum before downloading, never refuses': 'check_minimum\n' in read('scripts/install-dot.sh') and 'WARNING: Dot needs Apple Silicon M5 Pro class or newer, 48 GB Unified Memory and macOS 27.0 or newer.' in read('scripts/install-dot.sh') and 'exit' not in read('scripts/install-dot.sh').partition('check_minimum() {')[2].partition('\ncheck_minimum\n')[0],
    'mv, cp and trash run in-process inside the selected folder and never overwrite without -f': '["rm", "rmdir", "mkdir", "touch", "mv", "cp", "trash"].contains(name)' in chat and 'guard force else { return "Refused: \\(destination) already exists; add -f to replace it." }' in chat and 'fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)' in chat,
    'highlight active window outlines the real window': 'ScreenGuideLaserOverlay.shared.highlightRect(Self.activeExternalWindowFrame() ?? centerBox)' in chat and 'return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)' in chat,
    'R5 memory: no raw per-turn capture, each conversation part summarised once, forget matches every word': 'PersistentMemoryBrain.extractImportantFacts(from: text)' not in chat and 'history.filter { !summarisedMessageIDs.contains($0.id) }' in chat and 'summarisedMessageIDs = snapshotIDs' in chat and 'strictOnly: true' in chat and 'if !strictResults.isEmpty || strictOnly { return strictResults }' in read('src/LocalFTSStore.swift'),
    'delete_file follows the selected-folder rules': chat.count('Self.deleteInAllowedFolder(') == 2 and 'try FileManager.default.removeItem(atPath: path)' not in chat and 'try FileManager.default.removeItem(atPath: target)' not in chat,
    'R19 one-off failures clear by themselves; R14 battery alerts are not silenced by paused comments': 'private func block(_ message: String, issue: CompanionIssue, clearsAfter seconds: Double? = nil) {' in chat and 'clearsAfter: reason == .permissionLost ? nil : 12)' in chat and chat.count('clearsAfter: 15)') == 2 and chat.index('self.checkBatteryAlerts() { continue }') < chat.index('if !self.screenPaused, self.visible, !self.proactive.paused, self.phase == .idle,'),
    'a pending card is withdrawn when the owner moves on': 'DiagnosticChatLogger.recordTool(name: "approval_withdrawn", target: req.command,' in chat and chat.index('approval_withdrawn') < chat.index('let copyPhrase = Self.commandPhrase(text)'),
    'R16 file-writing programs keep the card': '"rsync", "ditto", "unzip", "tar", "sqlite3", "wget", "patch", "shred"' in read('src/InteractionCore.swift') and 'if name == "sed", later.contains(where:' in read('src/InteractionCore.swift') and 'case "restore", "rm":' in read('src/InteractionCore.swift'),
    'R11 engine stages update only a progress banner and a finished check clears it': 'if let current = self.phase.blockedMessage, Self.isProgressMessage(current) {' in chat and 'self.block(Self.progressMessage(for: stage ?? ""), issue: .unknown)' not in chat,
    'R22 the chosen folder is kept across launches as a security-scoped bookmark': 'url.bookmarkData(options: [.withSecurityScope]' in read('src/ActionPanel.swift') and 'URL(resolvingBookmarkData: data, options: [.withSecurityScope]' in read('src/ActionPanel.swift') and 'NativeActionPanel(model: NativeActionPanelModel(folderBookmarks: .standard))' in read('src/App.swift') and 'await self.actionPanel.model.restoreSavedFolder()' in read('src/App.swift') and 'selectFolder(docDir, remember: false)' in read('src/App.swift') and '        return await selectFolder(url)\n    }' in read('src/ActionPanel.swift'),
    'removal also deletes the Keychain log token': 'while security delete-generic-password -s dot-github-token >/dev/null 2>&1; do :; done' in read('scripts/uninstall-dot.sh') and 'dot-github-token' in read('src/DotLogSync.swift'),
    'removal also clears .dot-actions folders, Dot Dock tiles, download history rows and crash records': 'Self.recordActionFolder(canonical)' in read('src/ActionPanel.swift') and '[ -f "$target/owner.lock" ] || continue' in read('scripts/uninstall-dot.sh') and '[ ! -L "$target" ]' in read('scripts/uninstall-dot.sh') and 'defaults import com.apple.dock "$DOCK_PLIST"' in read('scripts/uninstall-dot.sh') and "LSQuarantineDataURLString LIKE '%github.com/Emin-dev/Dot/%'" in read('scripts/uninstall-dot.sh') and '/CrashReporter/Dot_' in read('scripts/uninstall-dot.sh'),
    'voice approve and deny end the listening turn first': re.search(r'cancelTurn\(\)\s+approvePendingAction\(\)\s+return', chat) is not None and re.search(r'cancelTurn\(\)\s+denyPendingAction\(\)\s+return', chat) is not None,
    'every command that is not read-only passes the R16 safety approver': re.search(r'!FileOperationPolicy\.isReadOnlyCommand\(command\),\s*let refusal = await self\.safetyRefusal\(for: command\)', chat) is not None
        and 'testOnlyReadOnlyCommandsSkipTheApprover' in read('Tests/DotCoreTests/InteractionCoreTests.swift')
        and '"security", "open"' in read('src/InteractionCore.swift')
        and 'testNetworkCredentialAndLauncherCommandsKeepTheCard' in read('Tests/DotCoreTests/InteractionCoreTests.swift'),
    'scoped file operations parse options and paths inside the selected folder': 'let words = FileOperationPolicy.tokenize(trimmed)' in chat and 'if word == "--recursive" { recursive = true }' in chat and 'if !optionsEnded, word == "--" { optionsEnded = true; continue }' in chat and 'let directory = UserFolderScope.shared.current' in chat and 'currentDirectory: directory' in chat,
    'every launch is queued for log upload before the token check': re.search(r'writeMetadataIfNeeded\(\)\s+enqueueCurrentFiles\(\)\s+guard let token = token\(\) else', read('src/DotLogSync.swift')) is not None,
    'Remove Dot always leaves the command and says what happened': re.search(r'NSPasteboard\.general\.setString\(offlineCommand, forType: \.string\)\s+let fallback = NSAlert\(\)\s+fallback\.messageText = opened \? "Removal opened in Terminal" : "Terminal could not be opened"', read('src/App.swift')) is not None,
    'real Xcode XCTest target': 'com.apple.product-type.bundle.unit-test' in read('Dot.xcodeproj/project.pbxproj'),
    'default app safety approver finds the downloaded aux model': (
        'OfflinePreparation.shared.root' in read('src/SafetyApprover.swift')
        and 'OfflineModels' in read('src/SafetyApprover.swift')
        and 'aux/gemma-3-4b-it-Q4_K_M.gguf' in read('src/SafetyApprover.swift')
    ),
    'log bytes are re-masked immediately before upload': (
        'LogRedaction.masked(raw)' in read('src/DotLogSync.swift')
        and 'public static func masked(_ data: Data) -> Data' in read('src/InteractionCore.swift')
    ),
    'release cannot clobber published assets or run off main': (
        '--clobber' not in read('.github/workflows/release.yml')
        and 'refs/heads/main' in read('.github/workflows/release.yml')
        and 'git merge-base --is-ancestor HEAD refs/remotes/origin/main' in read('.github/workflows/release.yml')
        and 'git ls-remote --tags origin' in read('.github/workflows/release.yml')
        and 'refs/remotes/origin/main' in read('.github/workflows/release.yml')
        and '--target "$GITHUB_SHA"' in read('.github/workflows/release.yml')
        and 'case "$OUTPUT" in' in read('packaging/join-dot-dmg.command')
    ),
    'default-release provenance matches the pending parts plan': (
        "parts.get('status') == 'ready'" in read('scripts/package_default_release.sh')
        and "Emin-dev/Dot parts pending" in read('scripts/package_default_release.sh')
        and "schema_version') == 1" in read('scripts/package_default_release.sh')
        and "releases/download/{tag}/" in read('scripts/package_default_release.sh')
    ),
    'manual override requires three refusals of the same action': (
        'func armForce() -> Bool' in read('src/SafetyApprover.swift')
        and 'consumeForce(for action: String)' in read('src/SafetyApprover.swift')
        and 'forceNext' not in read('src/SafetyApprover.swift')
        and 'SafetyApprover.shared.armForce()' in chat
    ),
    'manual log script refuses non-log branches and redacts multiline PEM': (
        'refusing to push logs to branch' in read('scripts/dot_log_sync.sh')
        and '    dot-logs) ;;' in read('scripts/dot_log_sync.sh')
        and 'dot-*' not in read('scripts/dot_log_sync.sh')
        and 'redact_log.pl' in read('scripts/dot_log_sync.sh')
        and 'PRIVATE KEY(?: BLOCK)?' in read('scripts/redact_log.pl')
        and 'PRIVATE KEY(?: BLOCK)?' in read('src/InteractionCore.swift')
    ),
    'all-in-one joiner rejects traversal and foreign part URLs': (
        'def safe_name(' in read('scripts/join_release.py')
        and 'def safe_url(' in read('scripts/join_release.py')
        and 'refusing a part URL' in read('scripts/join_release.py')
    ),
    'force override policy is executable in DotCore': (
        'public struct ForceOverridePolicy' in read('src/InteractionCore.swift')
        and 'policy.arm(now: ProcessInfo.processInfo.systemUptime)' in read('src/SafetyApprover.swift')
        and 'policy.consume(action, now: ProcessInfo.processInfo.systemUptime)' in read('src/SafetyApprover.swift')
        and 'policy.registerStrike(key)' in read('src/SafetyApprover.swift')
    ),
    'exhausted log uploads retry at the backoff cap, not after a year': (
        'min(entries[index].attempts + 1, LogSyncPolicy.maximumRetries)' in read('src/InteractionCore.swift')
        and 'nextAttempt = now + 365 * 86_400' not in read('src/InteractionCore.swift')
    ),
    'both redactors mask JWT tokens': (
        '[REDACTED_JWT]' in read('src/InteractionCore.swift')
        and '[REDACTED_JWT]' in read('scripts/redact_log.pl')
    ),
    'split and join refuse silent overwrite; redirects stay on GitHub': (
        'refusing to overwrite existing part output' in read('scripts/split_release.py')
        and 'refusing to replace existing output' in read('scripts/join_release.py')
        and 'class SafeRedirectHandler' in read('scripts/join_release.py')
        and '--force' in read('scripts/join_release.py')
    ),
    'forced split removes stale parts so they cannot be uploaded': (
        'asset_pattern.fullmatch(name)' in read('scripts/split_release.py')
        and 'candidate.unlink()' in read('scripts/split_release.py')
    ),
    'owner packaging is safe under macOS bash 3.2 nounset': (
        '${FORCE_ARGS[@]+"${FORCE_ARGS[@]}"}' in read('scripts/package_all_in_one.sh')
    ),
    'legacy year-parked upload entries are retried after upgrade': (
        'public mutating func normalize(now: Double)' in read('src/InteractionCore.swift')
        and 'state.normalize(now: now)' in read('src/DotLogSync.swift')
    ),
    'app sandbox entitlements are minimal and enforced': (
        (lambda e: e.get('com.apple.security.app-sandbox') is True
         and e.get('com.apple.security.network.client') is True
         and e.get('com.apple.security.network.server') is True
         and e.get('com.apple.security.device.audio-input') is True
         and e.get('com.apple.security.files.user-selected.read-write') is True
         and e.get('com.apple.security.personal-information.calendars') is True
         and e.get('com.apple.security.automation.apple-events') is True
         # R21 (owner answer 2026-10-22): exactly these read-only and Apple-event exceptions.
         and {k for k in e if k.startswith('com.apple.security.temporary-exception')} == {
             'com.apple.security.temporary-exception.files.home-relative-path.read-only',
             'com.apple.security.temporary-exception.apple-events'}
         and e.get('com.apple.security.temporary-exception.files.home-relative-path.read-only') == ['/Desktop/', '/Documents/']
         and e.get('com.apple.security.files.downloads.read-only') is True
         # R22 (owner answer 2026-10-23): the chosen folder is kept as a bookmark.
         and e.get('com.apple.security.files.bookmarks.app-scope') is True
         and len(e) == 11)(
            plistlib.loads((root / 'Resources/Dot.entitlements').read_bytes()))
        and '--entitlements "$ENTITLEMENTS"' in read('scripts/sign_sandbox_app.sh')
        and '--options runtime' in read('scripts/sign_sandbox_app.sh')
    ),
    'every packaging path signs the sandbox entitlements': all(
        'sign_sandbox_app.sh' in read(path) for path in
        ('build.sh', 'scripts/package_default_release.sh', 'scripts/build_complete.sh',
         'scripts/build-and-sign-on-mac.sh', 'scripts/install_local.sh',
         'scripts/package_public_release.sh')),
    'installer is per-user and never uses admin': (
        'INSTALL_DIR="${DOT_INSTALL_DIR:-$HOME/Applications}"' in read('scripts/install-dot.sh')
        and re.search(r'(?m)^\s*sudo\b', read('scripts/install-dot.sh')) is None
        and 'com.apple.security.app-sandbox' in read('scripts/install-dot.sh')
        and 'macOS refused to open Dot' in read('scripts/install-dot.sh')
    ),
    'uninstaller removes app, container, data and privacy grants': (
        'tccutil reset All "$BUNDLE_ID"' in read('scripts/uninstall-dot.sh')
        and 'Library/Containers/$BUNDLE_ID' in read('scripts/uninstall-dot.sh')
        and 'Library/Group Containers/group.$BUNDLE_ID' in read('scripts/uninstall-dot.sh')
        and 'PASS: your Mac is back to how it was' in read('scripts/uninstall-dot.sh')
        and re.search(r'(?m)^\s*sudo\b', read('scripts/uninstall-dot.sh')) is None
    ),
    'in-app removal and sandbox self-check exist without a helper': (
        'removeDotCompletely()' in read('src/App.swift')
        and 'DOT_SANDBOX_SELF_CHECK' in read('src/App.swift')
        and 'outside_write_denied' in read('src/App.swift')
        and 'SMAppService' not in read('src/App.swift')
        and 'SMJobBless' not in read('src/App.swift')
    ),
    'privacy CI snapshots installs tests uninstalls and diffs': (
        'privacy_snapshot.py .tmp/snapshot-before.json' in read('.github/workflows/privacy-clean.yml')
        and 'install-dot.sh" | bash' in read('.github/workflows/privacy-clean.yml')
        and 'uninstall-dot.sh" | bash' in read('.github/workflows/privacy-clean.yml')
        and 'privacy_diff.py .tmp/snapshot-before.json .tmp/snapshot-after.json' in read('.github/workflows/privacy-clean.yml')
        and 'app.dot.local' not in read('scripts/privacy_allowlist.txt')
    ),
    'R23 screen change is measured by Apple Vision feature prints': (
        'VNGenerateImageFeaturePrintRequestRevision2' in read('src/ScreenContext.swift')
        and 'func captureFeaturePrint() async -> ScreenFeaturePrint?' in read('src/ScreenContext.swift')
        and 'current.differs(from: $0)' in read('src/ChatView.swift')
        and 'captureFingerprint' not in read('src/ScreenContext.swift') + read('src/ChatView.swift')
        and 'testFeaturePrintIgnoresATickingClockButSeesANewWindow' in read('Tests/DotCoreTests/InteractionCoreTests.swift')
        and not re.search(r'record\w*\(|\.notice\(|\.log\(|\.write\(|print\(|NSLog\(',
                          read('src/ChatView.swift').split('private func startAdaptiveScreenWatch')[1].split('    /// R5:')[0]
                          + read('src/ScreenContext.swift').split('func captureFeaturePrint()')[1].split('func captureSilentScreenSnapshot')[0]
                          + read('src/ScreenContext.swift').split('struct ScreenFeaturePrint')[1])
    ),
    'audit 2026-10-23 security: & splits commands, exact approvals, whole card command, fenced approver, folder root kept, subprocess limits': (
        '.replacingOccurrences(of: "&", with: "\\n")' in read('src/InteractionCore.swift')
        and 'lower.hasPrefix("approve")' not in chat and 'lower.hasPrefix("confirm")' not in chat
        and '.lineLimit(2)' not in chat.split('struct ActionApprovalOverlay')[1].split('struct ')[0]
        and 'command.unicodeScalars.count > ActionApprovalRequest.maximumShownCommand' in chat and '.format, .lineSeparator' in chat
        and 'fenced(conversation)' in read('crates/dot-safety/src/main.rs')
        and 'starts_with("yes")' not in read('crates/dot-safety/src/main.rs')
        and 'guard !removedPaths.contains(rootPath)' in chat
        and 'storage.append(chunk.prefix(max(0, limit - storage.count)))' in read('src/InteractionCore.swift')
        and '!trimmed.contains("=(")' in read('src/InteractionCore.swift')
        and 'static func systemCommandName' in read('src/InteractionCore.swift')
        and 'Refused: \\(source) is already there.' in chat
        and 'static func isSameFile' in chat and 'try await Task.detached(priority: .userInitiated)' in chat
        and 'curlOptionSendsOrWrites' in read('src/InteractionCore.swift')
        and 'replace("<<", "< <")' in read('crates/dot-safety/src/main.rs')
        and 'kill(process.processIdentifier, SIGKILL)' in read('src/InteractionCore.swift')
        and 'testEndlessOutputAndEndlessRunsAreStopped' in read('Tests/DotCoreTests/InteractionCoreTests.swift')
        and 'Audit S7' in read('Tests/DotCoreTests/TypedInteractionTests.swift')
    ),
    'dead code removed on 2026-10-23 stays removed': not any(
        name in read(path)
        for path in ('src/InteractionCore.swift', 'src/OfflinePreparation.swift', 'src/PlacementCapture.swift')
        for name in ('wakeMissedNotice', 'shutdownNotice(dropped', 'extractImportantFacts', 'persistFacts',
                     'ExtractedMemoryFact', 'InteractiveWalkthroughManager', 'ModelPartProgress',
                     'consumeLastDiagnostic')
    ),
    'a push to main cannot cancel the release no-trace gate': (
        'group: dot-privacy-${{ github.workflow }}-' in read('.github/workflows/privacy-clean.yml')
        and 'uses: ./.github/workflows/privacy-clean.yml' in read('.github/workflows/release.yml')
    ),
    'inner runtime sandbox is not nested under the App Sandbox': (
        'DOT_PARENT_APPLICATION_SANDBOX' in read('src/BundledSplash.swift')
        and "os.environ.get('DOT_PARENT_APPLICATION_SANDBOX') == '1'" in read('Resources/Runtime/dot_runtime.py')
    ),
}
plistlib.loads((root / 'Resources/Info.plist').read_bytes())
ET.parse(root / 'Dot.xcodeproj/xcshareddata/xcschemes/Dot.xcscheme')
for label, result in checks.items(): print(('PASS' if result else 'FAIL') + ': ' + label)
if not all(checks.values()): raise SystemExit(1)
print(f'{len(checks)} static guardrails passed; Swift/macOS execution is separate.')

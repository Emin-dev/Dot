# Local helper boundary verification

Source: `2db5aa9a1ecc744d57ef6c7478e5eab901d155de`. This increment restricts existing helpers; it does not replace Qwen/Splash, British Kokoro or the installed app.

## Changes and exact-source checks

Voice reads canonical bundled helper/runtime paths and writes only its private output directory; network is denied. Splash uses a standard-library-only bootstrap to retain its owned backend/TLS sockets across sandbox execution before model imports. Only its exact IPv4 TCP endpoints are permitted; unrelated/IPv6/UDP/external traffic is denied. Runtime/model reads and private-state writes remain available. Personal-file, symlink-escape and outside-write canaries are denied. Existing process/Mach permissions remain allow-default; this is not complete deny-default containment.

The verified phonemizer dependency copies its eSpeak library into a private temporary subdirectory. Real startup exposed the need to map that copy as executable. The exception is restricted to the private `tmp…/libespeak-ng.dylib` pattern; tests deny other names/directories and a matching-name symlink escape. No wider readable/writable roots or networking were restored.

Clean detached exact-source `verify_macos.sh` passed **136 Python, 175 SwiftPM, 277 native XCTest, 49 static guards**, both native sandbox probes, Debug/Release and development packaging, with zero warning diagnostics and strict signature verification. Suites overlap. The development package lacks neural assets and is not a complete owner bundle or public release.

## Real component acceptance

A separately hashed frozen integration harness used existing verified assets and the exact new launch/runtime policies, with the corrected voice-policy overlay recorded explicitly. Actual British `bf_isabella` → native Whisper → Qwen/Splash → two AVAudioPlayer segments → final-question invitation passed. An intermediate playback drain did not invite. Final audio to invitation was 419 ms. Actual microphone activity was detected; capture ended after exactly 3,000 ms trailing silence, and microphone audio/text were discarded. This is not classification as intentional human speech or proof against echo. All owned processes exited.

The component snapshot is broader than this commit and is not exact-current full-app/UI acceptance. Local receipts are under `/private/tmp/dot-runtime-tightened-20261013-01/`; the voice-policy SHA-256 is `0d64eeeb3fec6ee111987a1ac2cb46962ab0886147363fd5fe0de1cefe261d26`. No installation, model downloads or voice substitutions occurred.

## Remaining acceptance

The single cold diagnostic run took 84.868 seconds from synthetic speech-end to the model-generated question's player start, including 3.169 seconds selected silence. Engine readiness accounted for 70.210 seconds. Concurrent verification/cache effects were not controlled; this is not comparable speed evidence or p50/p95. A resident-runtime benchmark is being prepared. Player-start is not measured acoustic onset.

No new-policy near-deadline spoken reply, no-speech hardware result, quiet/noise/echo/headphone/Bluetooth quality, full current-candidate acceptance or owner heard-audio judgment follows from this component run. The installed app remains unchanged.

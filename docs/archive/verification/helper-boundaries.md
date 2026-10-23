# Local helper boundary verification

Current as of 2026-10-17. The runtime helpers are now three Rust binaries plus the retained Python
Splash supervisor. See the [Rust runtime reference](../rust-runtime.md). This page describes the
boundaries that exist in the current source; the dated evidence below is kept unchanged as a record
of what was run at the time.

## Current boundaries

- **`dot-fetch` (source reader).** The only helper with a Seatbelt profile:
  `Resources/Research/source_fetch.sb` denies file reads, file writes, executable mapping, all network
  access and process execution by default, then re-allows the reader binary, public system/TLS
  material and a null device. It cannot resolve a name, open a socket or run another program; the host
  supplies one already-connected, vetted socket as stdin. The profile remains deny-network even for
  the pinned peer. Full Mach/process containment is not claimed. Contract:
  [source transport](../source-transport.md).
- **`dot-search` (search).** One process per search, loopback `POST /search` only, gated by a
  per-launch 64-hex capability token; the host owns the child and escalates from stdin EOF to SIGTERM
  to SIGKILL. There is **no Seatbelt profile for `dot-search`** in the bundle (the retired
  `Resources/Search/search.sb` was deleted), so its containment is process ownership, the loopback
  capability and the bounded protocol, not OS policy. Contract: [search runtime](../search-helper.md).
- **`dot-voice` (speech).** An owned child launched with two pipes and `PATH=/usr/bin:/bin` only, from
  a private 0700 temporary directory that is removed on shutdown. There is **no Seatbelt profile for
  `dot-voice`** (the retired `Resources/Voice/voice.sb` was deleted), so it is not OS-restricted. Its
  binary links no runtime HTTP client: `cargo tree -p dot-voice -e normal` contains no `reqwest`, and
  the `any-tts` Hugging Face downloader is behind a `download` feature that `crates/dot-voice/Cargo.toml`
  does not enable. Contract: [voice bridge](../voice-bridge.md).
- **Splash supervisor/TLS relay (retained Python).** `Resources/Runtime/dot_runtime.py`,
  `dot_process.py`, `dot_tls.py` under `Resources/Runtime/splash.sb`. The supervisor keeps the bound
  listener descriptor open across the sandboxed Splash child, permits only its exact IPv4 TCP
  endpoints, and fails closed on unrelated/IPv6/UDP/external traffic. Process/Mach permissions there
  remain allow-default; this is not complete deny-default containment. Contract:
  [authenticated Splash transport](../authenticated-splash-transport.md).
- Nothing above establishes that an unprivileged local process cannot reach a helper; the helpers do
  not accept ambient connections, and the search/voice children are addressed only through owned
  pipes.

Sandboxing `dot-voice` and `dot-search`, and porting the Splash supervisor to Rust, are open work
rather than implemented controls.

## Historical record (Python-era, superseded 2026-10-17)

The following records a past state and its numbers are unchanged. It described a Python voice helper,
its phonemizer dependency and a Search proxy profile; none of those files exist today.

Source: `2db5aa9a1ecc744d57ef6c7478e5eab901d155de`. That increment restricted the then-existing
helpers; it did not replace Qwen/Splash, British Kokoro or the installed app.

Voice read canonical bundled helper/runtime paths and wrote only its private output directory; network
was denied. Splash used a standard-library-only bootstrap to retain its owned backend/TLS sockets
across sandbox execution before model imports. Only its exact IPv4 TCP endpoints were permitted;
unrelated/IPv6/UDP/external traffic was denied. Runtime/model reads and private-state writes remained
available. Personal-file, symlink-escape and outside-write canaries were denied. Existing process/Mach
permissions remained allow-default; that was not complete deny-default containment.

The verified phonemizer dependency copied its eSpeak library into a private temporary subdirectory.
Real startup exposed the need to map that copy as executable. The exception was restricted to the
private `tmp…/libespeak-ng.dylib` pattern; tests denied other names/directories and a matching-name
symlink escape. No wider readable/writable roots or networking were restored.

Clean detached exact-source `verify_macos.sh` passed **136 Python, 175 SwiftPM, 277 native XCTest,
49 static guards**, both native sandbox probes, Debug/Release and development packaging, with zero
warning diagnostics and strict signature verification. Suites overlap. The development package lacked
neural assets and was not a complete owner bundle or public release.

### Real component acceptance (historical)

A separately hashed frozen integration harness used existing verified assets and the exact new
launch/runtime policies, with the corrected voice-policy overlay recorded explicitly. Actual British
`bf_isabella` → native Whisper → Qwen/Splash → two AVAudioPlayer segments → final-question invitation
passed. An intermediate playback drain did not invite. Final audio to invitation was 419 ms. Actual
microphone activity was detected; capture ended after exactly 3,000 ms trailing silence, and microphone
audio/text were discarded. This was not classification as intentional human speech or proof against
echo. All owned processes exited.

The component snapshot was broader than that commit and was not exact-current full-app/UI acceptance.
Local receipts are under `/private/tmp/dot-runtime-tightened-20261013-01/`; the voice-policy SHA-256 is
`0d64eeeb3fec6ee111987a1ac2cb46962ab0886147363fd5fe0de1cefe261d26`. No installation, model downloads
or voice substitutions occurred.

### Remaining acceptance at that time (historical)

The single cold diagnostic run took 84.868 seconds from synthetic speech-end to the model-generated
question's player start, including 3.169 seconds selected silence. Engine readiness accounted for
70.210 seconds. Concurrent verification/cache effects were not controlled; this was not comparable
speed evidence or p50/p95. A resident-runtime benchmark was being prepared. Player-start is not
measured acoustic onset.

No new-policy near-deadline spoken reply, no-speech hardware result, quiet/noise/echo/headphone/Bluetooth
quality, full current-candidate acceptance or owner heard-audio judgment followed from that component
run. That installed app was unchanged.

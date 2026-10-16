# dot-voice bridge, protocol 1

Current as of 2026-10-17. The voice engine is the Rust binary `dot-voice`, built from
`crates/dot-voice/src/main.rs` (Rust `any-tts` crate with the `kokoro` feature) and copied into
`Contents/MacOS` by `build.sh` and `scripts/build_complete.sh`. The retired Python helper
(`Resources/Voice/bionic_helper.py`) and its Seatbelt profile (`Resources/Voice/voice.sb`) no longer
exist. See the [Rust runtime reference](rust-runtime.md) for the full runtime picture.

The minimum host is `src/BionicVoice.swift`: it launches the sibling executable
`Contents/MacOS/dot-voice` with `--root <model directory> --output <private WAV directory>`, gives it
the two pipes it needs and the environment `PATH=/usr/bin:/bin`, sends protocol frames on stdin and
reads protocol events on stdout. A missing or non-executable binary is an honest setup failure; there
is no system-TTS or Python fallback. The private output directory is created with mode 0700 under the
temporary directory and removed when the voice shuts down.

## Startup and model

The binary takes `--root` (required; the Kokoro model tree, or a directory containing `model/`) and
`--output` (required; where finished WAV files are written). Missing arguments or a model that fails
to load emit an `unavailable` event and exit with status 2. Exactly one model is loaded and one
worker thread synthesizes requests, so the model stays warm across sentences in one launch.

The binary does **not** currently run under a Seatbelt profile: the host starts it directly as an
owned child with a minimal environment and no inherited entitlements. The retired Python voice path
was the only component with a `voice.sb` profile, and that file is deleted. Sandboxing the Rust voice
process is open work, not an implemented control.

## Protocol

Bounded UTF-8 JSON lines over the owned child's stdin/stdout. Every frame carries `protocol: 1`.

Requests (stdin, one JSON object per line; a line longer than 8,192 bytes or an empty line is
ignored):

- `{"protocol":1,"type":"speak","id":"<uuid>","turn":"<uuid>","text":"…"}` — queued for synthesis.
- `{"protocol":1,"type":"cancel"}` — advances the cancellation generation and answers `cancelled`.
- `{"protocol":1,"type":"shutdown"}` — ends the loop cleanly. Closing stdin does the same.

Events (stdout):

- `hello` — `{"protocol":1,"event":"hello","engine":"kokoro","voice":"bf_isabella","sample_rate":24000,"offline":true}`.
- `audio` — `{"protocol":1,"event":"audio","id":…,"turn":…,"file":"audio-<uuid>.wav","samples":N,"sample_rate":24000}`.
- `cancelled` — `{"protocol":1,"event":"cancelled"}`.
- `error` — `{"protocol":1,"event":"error","id":…,"turn":…,"code":…}` with fixed codes
  (`synthesis_failed`, `write_wav_failed`, `queue_full`, `unsupported_request`).
- `unavailable` — `{"protocol":1,"event":"unavailable","code":…}` for `missing_root_argument`,
  `missing_output_argument`, `local_voice_setup_failed`, `invalid_protocol_request` or
  `unsupported_protocol`. The process exits after these.

The queue holds at most 24 pending `speak` requests; a full queue is reported as `queue_full` rather
than blocking. Cancellation invalidates queued work and discards a synthesis result whose generation
changed, but it cannot preempt a synthesis kernel already running — the current call finishes before
the worker observes the new generation. WAV files are written once per accepted request and the host
reads, validates and deletes each one. No text or audio is logged.

## Evidence and limits

Recorded on 2026-10-17 ([PROGRESS](PROGRESS.md)): `dot-voice` loaded the bundled `bf_isabella` assets
and synthesized one turn fully offline, emitting `samples: 78000` at `sample_rate: 24000` into a
156,044-byte WAV.

Not established by that run, and not claimed here: audible/acoustic verification, cold/warm latency,
voice quality, cancellation timing under a running kernel, multi-sentence playback order, memory or
energy cost, sandbox containment, and any installed-app or device acceptance. The retired Python
helper was adapted from the MIT-licensed Bionic Kokoro synthesis; its notice is still bundled at
`Resources/Voice/BIONIC-LICENSE.txt`, and the Rust binary links the `any-tts` crate declared in
`crates/dot-voice/Cargo.toml`. The Python-era helper design and its assembly pipeline are kept only
as [history](offline-voice-assembly.md).

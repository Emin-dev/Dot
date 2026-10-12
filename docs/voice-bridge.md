# Bionic voice bridge, protocol 1

Dot bundles its own warm helper, adapted from the MIT-licensed CPU Kokoro synthesis in [Emin-dev/Bionic at 5166bf4915d436c505f4731667daf5b9375b5e77](https://github.com/Emin-dev/Bionic/blob/5166bf4915d436c505f4731667daf5b9375b5e77/voice/tts.py). Original source SHA256: cb2a485bf84eb93dc6fb6df49a2742d2d5005d4d2df917a742d78bb6100abca9. The original MIT notice is bundled as Resources/Voice/BIONIC-LICENSE.txt. No weights or Python packages are redistributed. This is a new, versioned bridge, not a claim of compatibility with the owner's locally modified socket daemon.

## Setup and limits

In Connection, choose an existing Bionic voice-engine folder. Dot executes that folder's env/bin/python, so choose only your trusted existing installation. Required local files: model/config.json, model/kokoro-v1_0.pth, model/voices/bf_isabella.pt. Supported Kokoro and Misaki versions: 0.9.4. The environment must already contain Torch, NumPy, spaCy, en_core_web_sm and working eSpeak G2P support from Bionic's pinned requirements. Nothing is installed or downloaded. The full Python environment and models are not yet bundled; a clean Mac without Bionic cannot use this mode yet.

The helper runs CPU-only in an owned subprocess behind macOS sandbox-exec with network access denied. Missing sandbox, packages, language data or assets fail closed. Offline flags and disabled spaCy downloader add defense in depth. These flags alone are not a network isolation claim. No arbitrary daemon is adopted or killed. Only Dot's own Process object is terminated on shutdown/reconfiguration. The default voice is Bionic; built-in English is a separately selected, explicitly interim mode, never an automatic fallback.

## Protocol

Bounded UTF-8 JSON lines over the owned subprocess's stdin/stdout. Every frame includes protocol:1. Hello must name engine:kokoro, voice:bf_isabella, sample_rate:24000 and offline:true. Speak requests contain UUID id and turn plus at most 1000 characters. A single worker uses one cached model/pipeline for ordered synthesis. Maximum 24 queued items, 60 seconds of audio per item, and 60 seconds between expected synthesis responses. Standard output is reserved for protocol data even during library diagnostics; text and audio are not logged.

Cancel advances the helper's generation, discards queued work and suppresses old results after the current model operation yields. The Swift host stops audio immediately, clears all queued output and rejects stale turn IDs. Cancellation does not preempt a CPU inference kernel; a new answer can wait for that kernel to return. Shutdown closes pipes and terminates only the owned process. WAV files are unique, stored in a per-process owner-only temporary directory, validated and loaded into bounded memory, then deleted. Process exit removes the directory. Playback is serialized mono 24 kHz PCM. No response cache retains private text/audio.

## Diagnosis and verification

The public baseline constructs its model for each CLI invocation. Keeping one model/pipeline warm removes that repeated initialization from subsequent sentences; this is a source-level optimization, not a measured latency claim. Dot logs durations only for final transcript, first reasoning, first answer, first audio and completion. Thinking remains on at low effort, separately visible in timing.

Python protocol tests and pure Swift event-validation tests require no model. CI checks the actual no-network sandbox using a standard-library local socket probe and builds the full client. These do not validate the neural voice. Still required on a configured Mac: cold/warm first-audio measurements, voice quality, queue ordering, interruption during synthesis/playback, repeated clicks, corrupt assets, daemon failure and an end-to-end conversation. No claim that these device/audio checks have passed.

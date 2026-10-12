# Bionic voice integration status

The owner's installed Bionic voice skill has local changes unavailable in this cloud checkout. Reported baseline: Emin-dev/Bionic commit `5166bf4915d436c505f4731667daf5b9375b5e77`. Reported local direction: Kokoro 82M CPU, `bf_isabella`, a warm Unix-socket daemon, bounded serialized requests, cancellation, unique audio files and ordered chunk playback. These reports are context, **not an executable compatibility contract**.

Do not connect to an arbitrary socket, execute a guessed Python environment, or silently download voice weights. This app currently identifies its built-in English voice as interim. It must not claim to use the installed Bionic skill.

Before enabling an adapter, recover/review the exact daemon code and license, or bundle a reviewed helper based on the public baseline. A future versioned interface must define: handshake and protocol version; engine/voice identity; offline readiness; owner-only socket permissions; maximum request and output sizes; monotonic request IDs; ordered audio frames or private output-file paths; cancellation acknowledgement; no stale playback after cancellation; restart behavior; and errors that never fall back to network synthesis. These are required design constraints, not an assertion that the current daemon implements them.

Acceptance tests: cold and warm first-audio latency, multiple sentence ordering, interruption before/after audio starts, repeated clicks, missing/corrupt model files, unsupported protocol version, daemon failure, and no network traffic. Only then may the UI select “Bionic / Kokoro” as an available voice.

> **SUPERSEDED (2026-10-17).** This document describes the retired Python SearXNG search stack and its
> canary workflow, which no longer exist. See [the Rust-only runtime](../rust-runtime.md) for the
> current runtime. `.github/workflows/search-proxy-canary.yml`, `packaging/search/**`,
> `Tests/Portable/**` and the pinned interpreter/SearXNG inputs are deleted; the historical lock,
> receipt and payload numbers below are kept unchanged as the record of that CI work.

# Hosted native Search proxy canaries

This is a separate build-only workflow with manual dispatch and a bounded main-branch push trigger:
`.github/workflows/search-proxy-canary.yml`. Pushes trigger it only when one of
28 exact canary dependency paths changes. Documentation-only and unrelated
product source changes do not trigger it. It neither edits nor replaces the
native companion/package workflow. It is restricted to a public repository and
the standard `macos-15` runner. No user Mac, release credentials, private transfer,
model payload, production CONNECT broker, artifact upload, or release is involved.

## Exact historical input, reconstructed rather than uploaded

The reviewed input is the independent, unaccepted native-owner Search assembly.
The historical lock is `packaging/search/search-lock-native-owner.json`:

- Canonical lock SHA-256: `0f094efe0cd2dc4d459a87ec9618884bd4f05bacd6c834ddd1036e813f2a4b80`
- Raw lock-file SHA-256: `25394a63db4084d606e56e25c7cec6a8fc979b03901c3b9739f2754e104a8920`
- Assembly-receipt SHA-256: `4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab`
- Receipt inventory: 4,824 regular files, excluding the receipt itself

The existing offline `search_payload.py` assembler consumes exactly 33 public
artifacts: 31 wheels, one Python install-only archive, and the exact SearXNG
revision archive, totaling 59,551,997 compressed bytes. The original lock records
HTTPS URL, byte count, and SHA-256 for every artifact. The existing HTTPS-only
allowlisted transport verifies each byte count and digest before use. There is
no package resolution, source build hook, or execution of downloaded payload code
during assembly. The existing hash-pinned `packaging==26.3` build/test parser is
installed only into the CI controller toolchain, never into Search.

Five small historical helper files are preserved byte-for-byte under
`Tests/Fixtures/search-proxy-native-owner/helpers`. They are inert reconstruction
inputs and are not replacements for `Resources/Search`. The helper loader,
production sandbox and dependency metadata must retain their historical bytes
because changing any of them changes the reviewed receipt.

The full acquisition command's 79-input closure also includes corresponding-source
and publisher-build inputs needed by other verification/distribution work. Those
46 extra inputs are not consumed by this build-only assembly and are deliberately
not downloaded here. Similarly, the historical lock's two `build_inputs` are not
compiled by this assembler. The current production bootstrap must not be passed
off as the historical build source. The bootstrap canary separately compiles its
own `Tests/Native/search-proxy-bootstrap-canary.c` and records its own identity.

Two independent local offline reconstructions using the already cached inputs
reproduced the exact historical receipt before this workflow was proposed.
CI must nevertheless reconstruct and compare the complete receipt and every
payload file before it may execute any native canary. Production locks are not
interchangeable with this historical lock. Both canonical JSON identity and raw
lock-file provenance are retained in evidence.

## Execution order and evidence

1. Record actual Darwin/arm64, macOS version/build, kernel, runner image, controller
   Python, and exact source commit. Refuse another OS or architecture.
2. Run portable fixture, lock-identity, and reconstruction regression tests.
3. Acquire the exact 33 inputs and reconstruct into a new runner temporary folder.
   Refuse mismatched receipt, file set, hashes, historical helpers, or source lock.
4. Run the independent native fixture profile.
5. Only after that passes, compile, ad-hoc sign, and run the fixture bootstrap.
6. Only after that passes, run the actual pinned curl/SearXNG request path against
   owned synthetic loopback CONNECT/TLS endpoints using the independent profile.

Default success gating stops the sequence at the first failure. Exit 77 is not a
pass. The final always-run step prints only already-produced, sanitized JSON
reports to the job log, including partial evidence on failure. It does not upload
the runtime tree, fixture certificates, or capabilities. Payload and fixture
source identities are recorded by the existing canaries and rechecked afterward.

The build controller intentionally follows the supported Python 3.13 patch line,
matching the existing CI toolchain policy. Its actual patch version is recorded.
It is a test tool only, with the pure-Python parser pinned by version and hash;
the complete reconstruction receipt is independent of the controller patch.
Native requests use only the reconstructed pinned CPython 3.11.17 and locked
curl/SearXNG dependencies. A controller change that changes assembled bytes fails
the exact historical receipt comparison before any native canary runs.

## Local offline reproduction

With the existing pinned parser available in a build controller:

```sh
python3 -B scripts/prepare_search_proxy_canary_payload.py \
  --inputs /path/to/verified-input-cache \
  --output /new/independent/search-canary-payload --offline
```

The output must be new, outside the checkout and any app bundle. `--offline`
strictly fails on missing or changed inputs without attempting network access.
The command assembles and verifies bytes only. It never executes the payload.

## Limits

A hosted macOS 15 result is evidence for the actual host it records. It is not
owner macOS 26.4 acceptance, full-neural app acceptance, production bootstrap or
broker acceptance, full SearXNG/Waitress/DDG engine acceptance, or release evidence.
No sandbox permission has been widened. A first native failure requires diagnosis
and another independently reviewed change; this workflow provides no bypass.

GitHub currently documents `macos-15` as a standard arm64 runner and standard
public-repository runner usage as free:
https://docs.github.com/en/actions/reference/runners/github-hosted-runners
The image contents are independently documented at:
https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
The runtime host checks remain authoritative if those labels change.

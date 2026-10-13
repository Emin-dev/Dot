# Dot bundled offline voice: technical research

Research date: 12 October 2026. Historical snapshot: at that research stage dependency closure, licensing closure, imports, signing and end-to-end audio were unverified. Later personal-app assembly and component evidence is recorded in [PROGRESS](PROGRESS.md); this inventory is not a live status feed or release lock. The [future roadmap](BUILD_CHECKLIST.md) governs speech candidates, the stricter product hardware target and public downloader; the no-provisioning design below describes the complete offline owner bundle.

## Product requirement

The complete Dot app requires macOS 26.4 and Apple M3 or newer because of Splash. That integration requirement was supplied by the integration owner and was not independently audited here. Voice/STT components supporting older macOS versions do not reduce the complete app requirement or establish Intel support.

The installation must contain every runtime and model needed for first use: no external Bionic/Python folders, user-installed packages, localhost server, post-install model downloads, or OS speech-asset provisioning.

## Recommended feasible architecture

- TTS: the Bionic-derived stdio helper, a private bundled relocatable CPython distribution, full installed wheel layouts, Kokoro v1.0 on CPU, British-English Misaki and bf_isabella.
- STT: native whisper.cpp with an explicitly selected bundled English model; AVFoundation microphone capture and conversion to 16 kHz mono floating-point audio. Microphone permission remains necessary.
- Resolve paths from the app bundle at runtime. Keep model/code resources read-only and transient output outside the signed bundle. Fail closed if any asset or required dependency is missing.
- Preserve package data and .dist-info. Exact Misaki 0.9.4 checks spacy.util.is_package before loading en_core_web_sm; copying only a model directory can trigger its downloader.

Source baseline: [Bionic commit 5166bf4 requirements](https://github.com/Emin-dev/Bionic/blob/5166bf4915d436c505f4731667daf5b9375b5e77/requirements.txt).

## Exact model and runtime assets

Publisher-only hashes below are expected SHA-256 values, not local verification of the large files. Only Kokoro config.json and the small eSpeak loader wheel were independently hashed. Full structured records and provenance are in ../packaging/voice-source-manifest.json.

### Kokoro model (9871713c6a29032f914cee65b617e2b6b3323770)

- File: kokoro-v1_0.pth
- Size: 327,212,226 bytes
- SHA-256: 496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4
- Verification: publisher_metadata_only
- [Download](https://huggingface.co/hexgrad/Kokoro-82M/resolve/9871713c6a29032f914cee65b617e2b6b3323770/kokoro-v1_0.pth)
- [Publisher metadata](https://huggingface.co/api/models/hexgrad/Kokoro-82M/tree/9871713c6a29032f914cee65b617e2b6b3323770?recursive=true)

### Kokoro British female Isabella voice (9871713c6a29032f914cee65b617e2b6b3323770)

- File: voices/bf_isabella.pt
- Size: 523,440 bytes
- SHA-256: cdd4c37003805104d1d08fb1e05855c8fb2c68de24ca6e71f264a30aaa59eefd
- Verification: publisher_metadata_only
- [Download](https://huggingface.co/hexgrad/Kokoro-82M/resolve/9871713c6a29032f914cee65b617e2b6b3323770/voices/bf_isabella.pt)
- [Publisher metadata](https://huggingface.co/api/models/hexgrad/Kokoro-82M/tree/9871713c6a29032f914cee65b617e2b6b3323770?recursive=true)

### Kokoro configuration (9871713c6a29032f914cee65b617e2b6b3323770)

- File: config.json
- Size: 2,351 bytes
- SHA-256: 5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f
- Verification: downloaded_bytes_sha256_verified
- [Download](https://huggingface.co/hexgrad/Kokoro-82M/resolve/9871713c6a29032f914cee65b617e2b6b3323770/config.json)
- [Publisher metadata](https://huggingface.co/api/models/hexgrad/Kokoro-82M/tree/9871713c6a29032f914cee65b617e2b6b3323770?recursive=true)

### Whisper English base model (5359861c739e955e79d9a303bcbc70fb988958b1)

- File: ggml-base.en.bin
- Size: 147,964,211 bytes
- SHA-256: a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
- Verification: publisher_metadata_only
- [Download](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin)
- [Publisher metadata](https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1?recursive=true)

### Whisper English small model (5359861c739e955e79d9a303bcbc70fb988958b1)

- File: ggml-small.en.bin
- Size: 487,614,201 bytes
- SHA-256: c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d
- Verification: publisher_metadata_only
- [Download](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.en.bin)
- [Publisher metadata](https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1?recursive=true)

### spaCy small English pipeline (3.8.0)

- File: en_core_web_sm-3.8.0-py3-none-any.whl
- Size: 12,806,118 bytes
- SHA-256: UNRESOLVED: publisher release did not expose a digest; file not downloaded
- Verification: not_downloaded_publisher_digest_absent
- [Download](https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl)
- [Publisher metadata](https://api.github.com/repos/explosion/spacy-models/releases/tags/en_core_web_sm-3.8.0)

### CPython standalone ARM64 runtime (3.11.17+20261009)

- File: cpython-3.11.17+20261009-aarch64-apple-darwin-install_only.tar.gz
- Size: 27,105,320 bytes
- SHA-256: 7b6068989d9b6a0e2a883352b7d0d141ce8670a61360bf4ddabac0e046a08e10
- Verification: publisher_metadata_only
- [Download](https://github.com/astral-sh/python-build-standalone/releases/download/20261009/cpython-3.11.17%2B20261009-aarch64-apple-darwin-install_only.tar.gz)
- [Publisher metadata](https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/20261009)

### whisper.cpp official XCFramework (v1.7.6)

- File: whisper-v1.7.6-xcframework.zip
- Size: 41,291,976 bytes
- SHA-256: 9fcb28106d0b94a525e59bec057e35b57033195ac7408d7e1ab8e4b597cdfeb5
- Verification: publisher_metadata_only
- [Download](https://github.com/ggml-org/whisper.cpp/releases/download/v1.7.6/whisper-v1.7.6-xcframework.zip)
- [Publisher metadata](https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/v1.7.6)

The three Kokoro files total 327,738,017 bytes. Together with base.en, the TTS/STT neural asset floor is 475,702,228 bytes, excluding spaCy, Python, native runtimes and all other app models. Archive sizes do not establish installed app size.

## Python constraints and directly pinned packages

Use Python 3.11 or 3.12: published Kokoro/Misaki 0.9.4 require Python below 3.13, while NumPy 2.4.6 requires at least 3.11. The interpreter candidate above targets ARM64/macOS 11+ according to its [pinned build source](https://github.com/astral-sh/python-build-standalone/blob/20261009/cpython-unix/targets.yml). Bionic Torch 2.14.1 offers a CPython 3.11 ARM64 wheel tagged macOS 14+.

The following exact versions are Bionic direct pins. They are not a recursively complete lock. Full recorded wheel names, SHA-256 values, sizes, first-hop dependency lists and metadata sources are in the JSON.

- kokoro 0.9.4: [publisher metadata](https://pypi.org/pypi/kokoro/0.9.4/json); 32,592 bytes; SHA-256 a129dc6364a286bd6a92c396e9862459d3d3e45f2c15596ed5a94dcee5789efd
- misaki 0.9.4: [publisher metadata](https://pypi.org/pypi/misaki/0.9.4/json); 3,617,774 bytes; SHA-256 90e2eeb169786c014c429e5058d2ea6bcd02d651f2a24450ba6c9ffc0f8da15a
- torch 2.14.1: [publisher metadata](https://pypi.org/pypi/torch/2.14.1/json); 127,281,154 bytes; SHA-256 b6074b130fd26bc50f5d171f07dfed70db22dd0c354ab34767729249f9e0f042
- transformers 5.19.0: [publisher metadata](https://pypi.org/pypi/transformers/5.19.0/json); 12,599,123 bytes; SHA-256 afcd2dd5f603ed28c1e1fcb00a338ccbb4ef5f878ed289635df8b58187afb518
- tokenizers 0.23.3: [publisher metadata](https://pypi.org/pypi/tokenizers/0.23.3/json); 3,101,381 bytes; SHA-256 68649e97d5b43c44c031d8d848874a6eecae8f8fe40ea989aa777a5a83aca716
- huggingface-hub 2.2.0: [publisher metadata](https://pypi.org/pypi/huggingface-hub/2.2.0/json); selected wheel size/hash/filename not retained
- safetensors 0.8.0: [publisher metadata](https://pypi.org/pypi/safetensors/0.8.0/json); 484,562 bytes; SHA-256 c80201d22cbf405b80647a60ada77bba06c8fba2da2743ba1e89cdcc39a81f25
- numpy 2.4.6: [publisher metadata](https://pypi.org/pypi/numpy/2.4.6/json); 5,469,159 bytes; SHA-256 4cfe66903cc32a9921a6733d96b19bb6abf310397581bbad89c228f5abaf0ee8
- regex 2026.9.29: [publisher metadata](https://pypi.org/pypi/regex/2026.9.29/json); 292,123 bytes; SHA-256 066d0e3dbfdd739bce2bf8c2a41dd16f73e3d8adc2eb06dd803a36a307f56075
- loguru 0.7.3: [publisher metadata](https://pypi.org/pypi/loguru/0.7.3/json); 61,595 bytes; SHA-256 31a33c10c8e1e10422bfd431aeb5d351c7cf7fa671e3c4df004162264b28220c
- spacy 3.8.16: [publisher metadata](https://pypi.org/pypi/spacy/3.8.16/json); 6,891,423 bytes; SHA-256 cb07d4b8255be6b6ff3a34ada93173176d0937d2023b35302a34eed3364681c0
- espeakng-loader 0.2.4: [publisher metadata](https://pypi.org/pypi/espeakng-loader/0.2.4/json); 9,892,565 bytes; SHA-256 d27cdca31112226e7299d8562e889d3e38a1e48055c9ee381b45d669072ee59f
- num2words 0.5.14: [publisher metadata](https://pypi.org/pypi/num2words/0.5.14/json); 163,525 bytes; SHA-256 1c8e5b00142fc2966fd8d685001e36c4a9911e070d1b120e1beb721fa1edb33d
- phonemizer-fork 3.3.2: [publisher metadata](https://pypi.org/pypi/phonemizer-fork/3.3.2/json); 82,700 bytes; SHA-256 97305c76f4183b3825dae8f4c032265fe78c9946ce58c47d4b62161349264b74

For some wheels, a direct files.pythonhosted.org URL was not retained in the earlier output. Those JSON download_url fields are deliberately null; the official versioned metadata endpoint and exact wheel filename identify the artifact. No missing URLs or hashes were invented and no additional PyPI query was made to prepare these deliverables.

## Transitive dependency closure: unresolved

A read-only metadata resolver was attempted for CPython 3.11/macOS 15/ARM64. It was canceled before completion; no complete candidate lock was produced. It has not been retried. The app minimum was subsequently clarified to macOS 26.4/M3+.

A concrete incompatibility is already known: spacy-curated-transformers 2.1.2 requires Thinc >=9.0.0.dev4,<9.2.0, while pinned spaCy 3.8.16 requires Thinc >=8.3.12,<8.4.0. A resolver must backtrack to a compatible release and lock all remaining dependencies.

Observed older candidate: spacy_curated_transformers-0.3.1-py2.py3-none-any.whl, 237,943 bytes, SHA-256 503559b6a1d6e44ec2c978e18ed871ce5c3d56871dc9216c0e1523428204e610. Its metadata dependencies are curated-transformers >=0.1.0,<0.2.0, curated-tokenizers >=0.0.9,<0.1.0 and torch >=1.12.0. This is not an import-tested selection or a completed solver result. [Version metadata](https://pypi.org/pypi/spacy-curated-transformers/0.3.1/json).

## eSpeak binary audit

The 9,892,565-byte official espeakng_loader 0.2.4 ARM64 wheel was read into memory, its SHA-256 was checked, and its Mach-O headers were parsed. No binary was executed.

- The wheel advertises macOS 11, but the three copies/names of its eSpeak 1.52.0 dylib actually declare macOS 14.0 minimum and SDK 14.5.
- Each inspected dylib is 504,168 bytes. The install ID is @rpath/libespeak-ng.1.dylib.
- Load dependencies are /usr/lib/libSystem.B.dylib and /usr/lib/libc++.1.dylib.
- It retains the obsolete RPATH /Users/runner/work/espeakng-loader/espeakng-loader/espeak-ng/_dynamic/lib. Review/remove it and re-sign during packaging.
- The loader resolves its dylib and espeak-ng-data relative to its own package, supporting a feasible relocatable layout.
- No LICENSE/COPYING file was found inside the wheel. The wrapper MIT license does not cover eSpeak NG GPL obligations.
- Exact corresponding source for that binary remains unverified. The observed [publishing workflow](https://github.com/thewh1teagle/espeakng-loader/blob/main/.github/workflows/pypi.yml) downloads binary/data archives from releases/latest, so a reproducible source build or an exact source-correspondence audit is needed.

## whisper.cpp packaging constraints

The verified v1.7.6 source commit is a8d002cfd879315632a579e73f0148d06959de36. It is a candidate pin; this research did not establish that it is the newest or a security-reviewed release.

The [official XCFramework build script](https://github.com/ggml-org/whisper.cpp/blob/v1.7.6/build-xcframework.sh) targets macOS 13.3 and arm64+x86_64; the framework uses @rpath/whisper.framework/Versions/Current/whisper. It combines whisper/GGML libraries and links Apple Foundation, Metal, Accelerate and CoreML plus the C++ runtime. Metal resources are embedded.

CoreML is enabled with WHISPER_COREML_ALLOW_FALLBACK=ON. The [initialization source](https://github.com/ggml-org/whisper.cpp/blob/v1.7.6/src/whisper.cpp) falls back locally if the optional encoder cannot load; it does not fetch one. A minimal source build can disable CoreML, Metal and OpenMP and use Accelerate. Neither route requires a server or Python STT installation. Actual release Mach-O contents, signature, target-Mac imports and transcription were not tested here.

## Licensing and redistribution review

This inventory identifies engineering compliance work; it is not legal clearance for the combined product.

- Bionic helper source: MIT. Retain copyright/license and modification provenance. [Source 1](https://github.com/Emin-dev/Bionic/blob/5166bf4915d436c505f4731667daf5b9375b5e77/LICENSE)
- Kokoro code, model and voice; Misaki: Apache-2.0. Retain license and applicable notices; record modified files. Audit included data/component notices. [Source 1](https://pypi.org/pypi/kokoro/0.9.4/json) [Source 2](https://pypi.org/pypi/misaki/0.9.4/json) [Source 3](https://huggingface.co/hexgrad/Kokoro-82M/tree/9871713c6a29032f914cee65b617e2b6b3323770)
- espeakng-loader wrapper: MIT. Wrapper MIT terms do not relicense bundled eSpeak NG. [Source 1](https://github.com/thewh1teagle/espeakng-loader/blob/main/LICENSE)
- eSpeak NG: GPL-3.0-or-later. Provide applicable license/copyright and satisfy corresponding-source obligations for the distributed binary. Exact corresponding source is not yet verified. [Source 1](https://github.com/espeak-ng/espeak-ng#license-information)
- phonemizer-fork: GPL; published license text version 3. Review distribution/combined-work obligations, preserve license and provide required source. Helper process separation alone does not establish compatibility. [Source 1](https://pypi.org/pypi/phonemizer-fork/3.3.2/json)
- num2words: LGPL; project COPYING text version 2.1. Preserve licensing and satisfy applicable source/modification/replacement obligations. [Source 1](https://github.com/savoirfairelinux/num2words/blob/master/COPYING)
- spaCy and en_core_web_sm: MIT plus applicable bundled data notices. Retain software/model/data notices; do not bundle source training corpora. [Source 1](https://github.com/explosion/spacy-models/blob/master/meta/en_core_web_sm-3.8.0.json)
- CPython standalone distribution: Python licenses and bundled dependency licenses. Audit the full distribution metadata/licenses and the exact subset shipped. install_only omits the full PYTHON.json build manifest. [Source 1](https://gregoryszorc.com/docs/python-build-standalone/main/distributions.html)
- PyTorch, NumPy and remaining dependency closure: Multiple; selected metadata recorded above where retained. Preserve actual wheel third-party notices and inventory nested libraries; top-level package metadata is not a complete SBOM. [Source 1](https://pypi.org/pypi/torch/2.14.1/json) [Source 2](https://pypi.org/pypi/numpy/2.4.6/json)
- whisper.cpp and Whisper model weights: MIT. Retain code/model copyright/license notices. [Source 1](https://github.com/ggml-org/whisper.cpp/blob/v1.7.6/LICENSE) [Source 2](https://github.com/openai/whisper#license)

GPL components are redistributable under their terms, but Bionic MIT attribution alone is insufficient. A private helper process does not by itself settle combined-work licensing. Preserve actual wheel/distribution notices, inventory native libraries, and provide required corresponding source or other compliant fulfillment before publishing.

## Release gates

1. Complete a reproducible recursively pinned and hashed ARM64 wheel/runtime/model lock; fill all null artifact/hash/license fields.
2. Audit every shipped Mach-O architecture, minimum OS, load dependency and RPATH; no unresolved external non-system library paths.
3. Verify source correspondence and license obligations, especially eSpeak/phonemizer/num2words and bundled native libraries.
4. Build/sign/notarize the app and nested code; relocation and signature verification are required after any Mach-O changes.
5. Cold-start from a relocated app on clean supported M3+ macOS 26.4 or later with networking disabled, no external Python/Bionic/Homebrew and empty model caches.
6. Demonstrate bf_isabella CPU synthesis and microphone STT without Apple speech assets, including first-run, cancellation, repeated requests and relaunch.
7. Measure latency, peak memory and final installed/download size on target hardware. None is established by publisher archive sizes.

## Work performed and limits

Read-only source/metadata research, exact Misaki 0.9.4 source inspection, eSpeak loader wheel/header inspection and small Kokoro config hashing were performed. No repository files were changed, packages installed, large models downloaded, model inference executed, or Mac runtime tests performed. The standalone artifacts were created outside repositories. All unresolved fields are explicit in the JSON.

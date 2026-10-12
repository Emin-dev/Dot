# Offline voice assembly

The complete static dependency lock is `packaging/voice/complete-voice-lock.json`.
Its SHA-256 is `6e8f8aa951fdafe30f575537e2ef4a17fe918758685d0766a89bf5fe452c02a5`.
The matching audit SHA-256 is
`de5f5649fd90e088b2c536152855e93a0829521c5dc474ea2e508172a68572c7`.
It recomputes every active dependency from actual wheel metadata,
including extras and target markers. All 92 distributions are reachable from
the 14 original Bionic pins plus the English pipeline. The three curated
constraints are preserved. Total wheel bytes: 220,445,695.

This is a verified set of assembly inputs. It is not an installed environment,
an inference test, or evidence that the complete app works offline.

## Inputs

- CPython 3.11.17 ARM64 install-only archive: 27,105,320 bytes, SHA-256
  `7b6068989d9b6a0e2a883352b7d0d141ce8670a61360bf4ddabac0e046a08e10`.
- Exactly the 92 wheels in the lock, each with its bound full CRC/RECORD
  inspection report. Keep all `.dist-info` directories and package/model data.
- The original docopt 0.6.2 source, its MIT license, and local deterministic
  repack provenance. `scripts/build_docopt_wheel.py` never runs `setup.py`.
- Captured upstream licenses/notices, including eSpeak NG GPL/source provenance
  and SentencePiece notices. Preserve wheel-provided licenses too.
- The already pinned Kokoro model/config and `bf_isabella` voice assets.

The voice interpreter is separate from Splash's Python 3.13 runtime. Do not
merge their dependency environments or use a pre-existing user installation.

## Native preparation

1. Verify the transfer archive hash and every member hash. Extract regular
   files only into a fresh assembly directory after rejecting absolute paths,
   traversal, aliases, links, duplicates and excessive member/byte counts.
   Rebase the portable inventory's wheel/report paths to that directory.
   Use this revision's `packaging/voice/complete-closure-audit.json` as the
   planner audit input. The initial transfer archive preserves an earlier
   audit with the same wheel/graph proof but an outdated planner-source label;
   retain that original evidence rather than overwriting it. The corrected
   audit above binds the final planner and its independent schema check.
2. Verify and safely extract the original CPython archive into a separate fresh
   root. Audit its archive paths/types and internal relative links before
   extraction. Record the exact regular-file hashes/sizes and link targets in
   a `verified_standalone_python_tree` manifest tied to the archive above.
   Never reuse an existing environment or claim a post-hoc file inventory
   proves archive provenance.
3. Run `scripts/prepare_voice_install.py` with `--lock`, `--audit`, `--inventory`,
   `--python-root`, `--python-manifest`, `--python-sha256`, and a fresh `--output`.
   It validates the full input closure and emits a local wheelhouse, hashed
   requirements, and an inert `install-plan.json`; it does not run pip.
4. On macOS, smoke-test the emitted sandbox profile using the verified
   interpreter: writes succeed only inside the assembly interpreter/output
   roots, writes elsewhere and network access fail with permission errors.
   A timeout is not proof of network denial. Use a clean environment populated
   from the plan. Run its required preflight argv, then its install argv.
   The plan pins the install prefix, disables all pip configuration and cache,
   denies network access, uses only local hash-locked wheels, and disables
   bytecode compilation. Do not add resolver or source-build fallbacks.
5. Run same-interpreter `pip check`, verify all locked distribution versions,
   import package data, audit Mach-O internal/system dependencies and sign
   nested native code. Check the phonemizer's private temporary dylib loading.
6. Run actual local `bf_isabella` synthesis through the app helper with clean
   HOME/TMPDIR and network denied. Check PCM WAV output, cancellation, EOF
   cleanup and relocation to a path containing spaces, commas and Unicode.
   No voice tensor or model may be downloaded. Python uses `-I -B`.

Only after those native gates pass may the immutable runtime manifest be
created. Complete app assembly still requires Splash, its owned-listener patch,
Qwen target/draft/vision assets, Whisper, and all payload manifests. Use
`scripts/build_complete.sh`, followed by genuine native offline acceptance and
`scripts/package_complete.sh`. The shipped app has no provisioning download
path. Missing payload remains a compact, honest error on the floating dot.

## Verification limits

Static wheel metadata and archive checks do not establish ABI compatibility,
successful neural inference, latency, microphone/screen permissions, or safe
relocation. Those are native acceptance gates. Personal ad-hoc test builds are
not notarized distribution releases.

## OpenMP sandbox compatibility

The exact Torch wheel's `torch/lib/libomp.dylib` (SHA-256
`6256bee09e93c28d71c65711cc69224d69994c6965648b628b70a22772fe98d4`)
probes global `/tmp` with `opendir`, not a writability test. A readable but
write-denied directory can trigger a misleading truncate warning. Both the
assembly profile and product voice policy deny directory data reads for only
`/tmp` and `/private/tmp`, selecting OpenMP's existing environment-registration
fallback. Duplicate-runtime checks remain enabled; no warnings are filtered.

The product's exact policy is `Resources/Voice/voice.sb`; supply the canonical
private HOME/TMPDIR/output directory through sandbox-exec's `DOT_OUTPUT`
parameter. It denies network access and all writes outside that private root.
Installation has its separate verified Python-prefix write allowance; the
finalized runtime must synthesize without writing to the Python/model tree.
Use the product policy for final import/synthesis acceptance. Check native
registration via libc `getenv` if needed, since Python's cached `os.environ`
can miss native `setenv` updates.

A target-device bounded probe verified clean Torch import, denied global temp
enumeration, private mmap success and unchanged outside-write/network denial.
Full neural synthesis remains a separate gate. Source rationale:
[LLVM directory detection](https://github.com/llvm/llvm-project/blob/llvmorg-19.1.7/openmp/runtime/src/z_Linux_util.cpp#L2838-L2859),
[registration fallback and duplicate checks](https://github.com/llvm/llvm-project/blob/llvmorg-19.1.7/openmp/runtime/src/kmp_runtime.cpp#L6296-L6404).
Relevant machine instructions were checked in the actual wheel; its compiler
identifier alone does not prove complete LLVM source-version provenance.

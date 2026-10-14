# Offline runtime reconstruction: portable implementation boundary

This command prepares inert runtime bytes. It does not make a runnable release,
prove native functionality, sign anything, or accept the current installed app.
The source policy contains **zero accepted historical baselines**. The reported
historical manifest digest is an unaccepted observation only.

## Implemented commands and current results

- `prepare --basis-id ID --inputs LOCATORS.json --stage NEW_STAGE`: portable,
  descriptor-bounded historical admission and copy, current Splash patcher from
  exactly pinned pristine upstream files, exact v1-to-v2 substitutions, exact
  baseline-hashed affected bytecode deletions, and deterministic prepared state.
  A real independently approved historical entry must be added first.
- `status --stage STAGE`: read-only rehash of the complete payload and retained
  bounded input/evidence bytes against the source-owned basis and current source
  identities. A rewritten checkpoint cannot authorize different bytes.
- `finalize --stage STAGE --evidence-dir EVIDENCE`: strict **unsupported interface**.
  Portable hosts return `NATIVE_REQUIRED` (exit 4) without writes. On macOS it
  checks the prepared stage and existence of the source-owned native approval,
  then returns `NATIVE_FINALIZER_NOT_IMPLEMENTED` (exit 4). There is no pass switch.
- `copy --payload PAYLOAD --destination NEW_DESTINATION`: reserved admission
  interface. It refuses an existing destination or any `.app` ancestor and
  requires independent native admission; accepted copy is not implemented yet.

Successful prepare is `runtime_reconstruction_prepared`, never
`verified_runtime_payload`. No production operation here writes
`runtime-manifest.json`, `accepted-runtime.json`, native success, or a native
approval. Replacing `supported: false` with `true` cannot enable these interfaces.

The archive ID `pinned-local-archives-v1` returns
`ARCHIVE_LAYOUT_UNREVIEWED` (exit 4). The exact Splash and standalone CPython
archive pins and complete 92-wheel lock/audit pins are retained in source policy,
but archive extraction and installation are not implemented. An arbitrary Python
tree plus a newly written extraction report is never an alternate input route.
The existing Voice install planner remains the owner of wheel preparation.

## Historical basis and inventory

The CLI accepts no policy, source-root, trust digest, platform override, repair,
force-replace, wildcard cache removal, network, signing, or download option.
Its source root is the directory containing this tracked module. Source-owned
policy selects phase-specific source identities, as detailed below.
The Python `Context` class permits isolated source trees for unit tests only;
integrators must use fixed-source public entry points. A source tree is trusted
code and policy, not an untrusted input inventory.

An inventory contains exactly:

```json
{"schema_version":1,"locations":{"runtime":"/absolute/read-only/Offline","collector_report":"/absolute/reviewed-collector-directory","upstream":"/absolute/pristine-Splash-source"}}
```

Locations convey no trust. A source-owned historical entry must name an explicit
personal-candidate reviewer decision, exact raw historical manifest and seven individual collector
artifact pins, the complete actual physical closure (including all directory modes
and links), component ownership and licenses, exact permitted stale-bytecode
removals, reviewed absence of alternate affected modules, and native inventory.
The original manifest is copied unchanged into evidence and ignored as pass proof.
Its regular bytes and raw hash still must match the independent baseline.

Every entry in the historical closure has exactly one component owner (Splash,
Voice, STT), except the root directory. Shared license references are allowed;
notices must be nonempty regular hashed files. This is technical attribution
coverage, not legal clearance. The baseline must be reviewed against actual
collector observations before it can be added to policy; self-generated digests
or a successful collector run alone do not provide the reviewer decision.

Three source files must match exact old v1 hashes. The current source-pinned
`patch_splash_listener.py` is the only source transformation owner: its existing
function operates on exact pinned pristine sources, never directly on v1 bytes.
A minimal read-only Path adapter supplies the bounded descriptor-read source
bytes in memory, so the patcher's legacy reads cannot reopen mutable input paths. Both privately retained
upstream and output v2 hashes are checked. Bytecode removals must individually
match baseline path, size and hash for those affected modules. Unrelated cache
bytes are retained. Affected bytecode detection uses NFC/casefolded paths: noncanonical case variants
are rejected, even on case-sensitive preparation hosts. Affected modules'
`__pycache__` directory symlinks are unsupported and rejected, so an otherwise
contained link cannot expose stale caches stored under another component. The reserved root manifest
name is also reserved under casefolding. The original app/tree is never modified
or executed.

## Source dependency phases

Portable `prepare` and `status` require exactly these source paths:

- `scripts/reconstruct_runtime_payload.py` and this source-owned policy at
  `packaging/runtime/reconstruction-policy.json`
- `scripts/patch_splash_listener.py` and
  `Resources/Runtime/splash-managed-listener-patch.json`

The patch record must agree with the policy's overlay ID, upstream revision and
three output hashes. The pristine upstream files remain independently pinned
inputs. No candidate artifact supplies expected source hashes.

A `native` Context adds `Resources/Runtime/{dot_runtime.py,dot_process.py,
dot_tls.py,splash.sb}`, `Resources/Voice/{bionic_helper.py,voice.sb}`,
`packaging/voice/{complete-voice-lock.json,complete-closure-audit.json}` and
`packaging/voice-source-manifest.json`. `verify_native_contract` requires this
phase. Future native probe implementation dependencies must be reviewed and added
before any native finalizer can be enabled.

Known builder, host Swift, Search auditor, held signing policy, model, Whisper and
archive-planner pins are retained as context in the policy but their current files
are not opened during preparation. Their owning integrations remain separate.
This does not authorize publishing held files to satisfy irrelevant hashes.

Checkpoints intentionally bind the **raw full policy hash**, in addition to the
selected phase's source identities. Editing or removing an inactive current file
therefore does not invalidate portable status. Editing any policy byte, including
an inactive/native source pin, does invalidate an existing checkpoint. There is
no cross-policy resume or subset-policy identity promise.

The four reconstruction files alone are still insufficient on the published v4
snapshot: its existing Splash patcher and patch-record bytes differ from these
required v2 pins. Native validation additionally needs the current runtime and
process helpers. Synthetic fixture tests do not prove that a published checkout
has these dependencies or has an approved historical baseline.

## Bounded collector-v2 observations

`read_collector_v2` reads the reviewed collector protocol whose source digest is
`c9af9c56a4a89707110e53bce1007d0cc8bef301a024eafd020140eda37a7f9a`.
It returns `unaccepted_collector_observation`, with `native_accepted: false` and
`trust_conclusion: not_established`. An eligibility flag only reports checked
observation conditions; it is not provenance, seal coverage or baseline approval.
The digest records the reviewed collector implementation, not proof that supplied
JSON was actually produced by it.

A source-owned accepted basis must pin a `collector_bundle` with schema version 2,
that collector source digest, and an `artifacts` map containing raw byte size and
SHA-256 for each of exactly seven files:

| Artifact | Maximum bytes |
| --- | ---: |
| collection-start.json | 65,536 |
| runtime-manifest.original.json | 16,000,000 |
| runtime-inventory.json | 120,000,000 |
| support-inventory.json | 120,000,000 |
| apple-tools.json | 120,000,000 |
| report.json | 120,000,000 |
| COMPLETE.txt | 4,096 |

The entire bundle is capped at 120,000,000 bytes. Preflight sizes, initial file
identities, per-read remaining aggregate allowance, cumulative actual bytes and
final identities/pin totals are checked. Paths are descriptor-opened; symlinks,
mutable hardlinks, unknown or case-aliased artifacts and missing artifacts reject.
Preparation retains all seven exact original files under `evidence/collector/`;
status rechecks them. No merged or flattened report is written. The separate
historical-manifest evidence must exactly equal the collector's original copy and
the supplied runtime's manifest bytes.

Inventory normalization checks stat/type/size congruence, complete physical path
and link graphs (including reported resolution), original-manifest correspondence,
and speech pins. Bounds include 100,000 aggregate nonroot nodes, 16,000,000
cumulative path bytes, 2,048 native objects, 32-level JSON nesting, 262,144 raw
output bytes per tool event and 32,000,000 raw tool-output bytes in total.
Canonical normalized closure identity remains capped at 16,000,000 bytes even
when an individual collector artifact is larger.

Duplicate keys, nonfinite values, integers exceeding 20 digits, unsupported keys
and numeric locations reject. A separate Decimal parser allows finite diagnostic
numbers only at:

- `apple-tools.json`: each `result.elapsed_seconds`, from 0 through 1802
- `report.json`: `metadata["Contents/_CodeSignature/CodeResources"].rules` under
  `rules` or `rules2`, each rule's `weight`, from 0 through 1,000,000,000

Decimal lexemes are at most 64 characters, with adjusted exponent from -100 to 12;
seal-rule keys are at most 4,096 UTF-8 bytes. Other metadata decimal locations
remain unsupported pending actual-layout evidence. Strict canonical identity and
native-receipt JSON still reject all decimals. Elapsed values and seal-rule
weights do not determine native/provenance/seal approval or normalized closure
identity. They remain in the byte-exact pinned raw report for later review.

A missing-artifact partial run rejects. A complete-shaped seven-artifact exit-1 or
exit-2/incomplete report can be inspected but is ineligible for preparation.
`COMPLETE.txt` is emitted even for some failures and is never pass evidence.
Successful observation requires nonvacuous event coverage: chip identification,
three exact outer-signature events, plus architecture/dependencies/load-commands/
signature-display/strict-signature events for every observed native file across
runtime and support inventories. Tool argv must have the fixed system-tool and
argument structure; native events must bind the observed hash and descriptor.
Zero integer exits, absent errors, sandbox observations and full coverage are
checked independently of the report's summary flags. Replacement-decoded Unicode
is supported while accounting for raw output bytes. No native tool is run by this
portable reader, and text claiming an observation is not cryptographic proof.

## Filesystem and failure contract

A stage must be fresh, outside all inputs and the source checkout, and have no
`.app` ancestor. Before creating anything, bounded no-follow physical directory
traversal compares source/runtime/upstream/collector directory identities against every held
destination-parent ancestor. This rejects identity overlap hidden by different
pathnames, including a descendant-rooted alias. Bind-mount/macOS firmlink behavior
has only a simulated-capability portable regression, not native validation. An existing destination is never replaced. The tool opens roots,
parents and files with no-follow descriptor-relative access, refuses nonregular
special nodes and mutable hardlinks, checks descriptors against before/after
identity, and copies and hashes from the same descriptor. All regular output
inodes are independent. Actual bytes, count, metadata, path depth, JSON nesting,
wall-time and disk reserve are bounded. JSON integers are limited to 20 decimal
digits before conversion; malformed or oversized numbers follow the declared
rejection/exit contract rather than leaking a parser exception. The entire physical namespace is checked
before copying for case/NFC aliases, collisions, external, dangling and cyclic
links. Contained framework directory links are inventoried but never traversed.

Read-only baseline directories and source files are supported. Only the direct
transform-parent directory in the private copy temporarily gains owner-write,
and its exact original mode is restored in a finally block before checkpoint or
closure comparison. Source file modes are preserved; no permission on the input
app/tree is changed. Failed transactions stay unaccepted.

Preparation uses a new hidden sibling at mode 0700, fsyncs files and directories,
and publishes with Linux `renameat2(RENAME_NOREPLACE)` or Darwin
`renameatx_np(RENAME_EXCL)`. Unsupported kernels fail closed; no check-then-rename
fallback is used. Darwin publication behavior is not yet native-tested. Inputs
are never rewritten. A failure may retain its hidden unaccepted transaction; it
is named in the error when possible. The tool deliberately avoids unsafe recursive
cleanup through a pathname that another writer might have exchanged.

Read-only status verifies the complete prepared boundary; arbitrary partial pip,
signing, unknown work/evidence files, altered source, and unexplained tree deltas
are refused. There is no native resume or in-place repair. Preparation is private
and single-writer; concurrent final publications have one no-replace winner.

This protects against detected substitution and accidental corruption in a
trusted build workspace. It does not defeat an actively malicious same-UID writer
after verification. It does not solve the app's separate verification-to-later-
pathname-execution problem, establish OS immutability, or isolate app user data.

## Native evidence interface and remaining implementation

`verify_native_contract` is a pure structural admission interface. It requires a
separate source-owned `packaging/runtime/runtime-native-build.json` pinning the
exact signed closure, complete native-phase source identity map, policy and basis
identities, and every receipt's raw bytes/hash. Receipt schemas reject missing
gates, wrong sources/closure, duplicate gates, timeout/signal/launch-error outcomes,
missing arm64 macOS host observations, missing argv/environment identities, and
unbound raw output bytes. This helper never returns native acceptance. A text
report cannot itself cryptographically prove it came from a Mac.

A future reviewed native implementation still needs:

1. Exact actual distribution inventory/pip check and bootstrap exceptions; clean
   offline Kokoro/Misaki import, genuine bf_isabella synthesis and PCM metadata,
   cancellation/EOF/process cleanup, and actual Splash v2 product-profile probes.
2. Fixed-path bounded system signature, ABI/minimum-OS and dyld/linkage verification
   across all native objects/bundles, binding preserved versus changed signatures.
3. Explicit exact install/relocation/signing deltas and final signed closure;
   post-sign immutable-input probes and relocation with spaces, commas and Unicode.
4. Actual independently reviewed receipts and tracked native approval in a coherent
   source snapshot; source changes invalidate observations. No fake portable native
   receipt may be promoted into production policy.
5. Deterministic schema-1 manifest generation, atomic acceptance commit and
   full re-audit; a fresh-build-owned directory capability for accepted runtime
   copy; independent audit/build integration. A writable child of an installed
   `.app` is not a valid build capability.

The intended noncircular identity graph is basis/source/policy → signed closure
(excluding only the future root manifest) → receipts → independent native approval
→ final manifest → host seal. The implementation already uses canonical UTF-8
JSON with sorted keys, compact separators, no duplicate keys or floats (except the separately parsed raw collector diagnostics), and one
trailing newline. Directory and file modes and exact relative links are covered.
No stage path, timestamp, random stage name, inode or local device enters prepared
identity material. Native signatures are not claimed to be reproducible.

Exit codes: 0 named portable operation completed, 2 invalid/untrusted input,
3 independent accepted evidence missing, 4 unsupported/native required,
5 resource/deadline/cancellation or observed filesystem mutation failure.

## Verification and unchanged owners

Run `python3 -m unittest discover -s Tests/Python -p test_runtime_reconstruction.py`.
Synthetic tiny historical source policies exist only inside temporary test trees.
Tests cover deterministic inert prepare, exact source/cache transforms, read-only
status, no self-manifest authority, graph/path hazards, bound failures, mutations,
no-replace publication and fail-closed interfaces. They do not test actual native
execution, actual archive layouts, production historical admission, accepted
finalization/copy or whole-app behavior.

`audit_runtime_payload.py` and `build_complete.sh` are unchanged and do not yet
consume this independent admission interface. Existing Whisper original-ZIP,
Search, separate complete model hash/copy, outer-signature and clean-source gates
remain. Do not restart the model hash process or copy the 19.93 GB model set here.
Public provenance, notarization, license/source clearance, supported hardware,
full app conversation, data-preserving install and owner acceptance remain open.

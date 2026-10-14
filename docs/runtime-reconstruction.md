# Offline runtime reconstruction and guarded native finalization

This command prepares inert runtime bytes and provides guarded owner-run native
finalization. It does not sign, make a release or accept the current installed app.
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
- `finalize --stage STAGE --evidence-dir EVIDENCE`: guarded Darwin finalization.
  Portable hosts return `NATIVE_REQUIRED` (exit 4) without writes. Actual macOS
  execution requires independently approved source-owned schema-2 evidence, all
  nine gates and fresh static verification before atomic manifest/marker commit.
- `copy --payload PAYLOAD --destination NEW_DESTINATION`: reserved admission
  interface. It refuses an existing destination or any `.app` ancestor and
  requires independent native admission; accepted copy is not implemented yet.

Successful prepare is `runtime_reconstruction_prepared`, never native acceptance.
Only fully validated native finalization may write `runtime-manifest.json` and
`accepted-runtime.json`; it never generates approval. No production runtime has
been accepted. Policy support flags and self-manifests grant no authority.

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
phase for its structural-only legacy interface. Full finalization uses schema-2
admission. Actual probe source dependencies must be reviewed and added before
their evidence can satisfy its gates.

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
are refused. Prepared status cannot resume arbitrary partial signing. Exact native finalization
retry/revalidation is supported; there is no in-place repair. Preparation is private
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

The executable native path is described below. Actual owner inventory, genuine
native harnesses/observations, independent native approval and separate accepted
copy/build/auditor integration remain mandatory and unavailable here.

The intended noncircular identity graph is basis/source/policy → signed closure
(excluding only the future root manifest) → receipts → independent native approval
→ final manifest → host seal. The implementation already uses canonical UTF-8
JSON with sorted keys, compact separators, no duplicate keys or floats (except the separately parsed raw collector diagnostics), and one
trailing newline. Directory and file modes and exact relative links are covered.
No stage path, timestamp, random stage name, inode or local device enters prepared
identity material. Native signatures are not claimed to be reproducible.

Exit codes: 0 named operation completed, 2 invalid/untrusted input,
3 independent accepted evidence missing, 4 unsupported/native required,
5 resource/deadline/cancellation or observed filesystem mutation failure.

## Verification and unchanged owners

Run `python3 -m unittest discover -s Tests/Python -p test_runtime_reconstruction.py`.
Synthetic tiny historical source policies exist only inside temporary test trees.
Tests cover deterministic inert prepare, exact source/cache transforms, read-only
status, no self-manifest authority, graph/path hazards, bound failures, mutations,
no-replace publication and fail-closed interfaces. They do not test actual native
execution, actual archive layouts, production historical admission, production native
acceptance, accepted copy or whole-app behavior.

`audit_runtime_payload.py` and `build_complete.sh` are unchanged and do not yet
consume this independent admission interface. Existing Whisper original-ZIP,
Search, separate complete model hash/copy, outer-signature and clean-source gates
remain. Do not restart the model hash process or copy the 19.93 GB model set here.
Public provenance, notarization, license/source clearance, supported hardware,
full app conversation, data-preserving install and owner acceptance remain open.


## Guarded native finalization

`finalize` is implemented for owner-run Darwin execution with exact reviewed
schema-2 source-owned approval and genuine evidence. Portable execution fails
before writes. The production policy still has zero accepted historical bases
and no native approval. `supported` describes code availability, never authority.

The source-owned approval is excluded from both phase source identities and policy
source bindings. It pins basis/policy/native sources, prepared and signed physical
closures, the complete sorted signing diff, component ownership, native inventory,
fixed probe contract, nine receipts and every raw artifact. Canonical JSON is
bounded to 16 MB. The existing schema-1 `verify_native_contract` remains structural
only and cannot authorize a manifest or acceptance. Source changes invalidate
checkpoints and observations; real evidence must never be relabelled to new hashes.

Signing accepts only same-mode existing Mach-O resign, exact annotated relocation,
exact bundle CodeResources writes and their missing signature directories.
Independently parsed old/new facts bind hashes and signatures. Resign preserves
all non-LC_CODE_SIGNATURE commands. Relocation requires exact per-command and
per-edge before/after differences and reasons; architecture/platform/minimum OS/SDK
stay unchanged. Source/data/package/link/bytecode/license/ownership changes and
unknown signing layouts reject. Multiarch scalar-signature identity is unsupported.

Nine concrete semantic gates require:

1. Reviewed historical/collector/prepared identity chain.
2. Exact current 92-distribution lock, physical dist-info/METADATA coverage,
   contained origins/sys.path, fixed CPython 3.11.17 arm64, actual raw pip check.
3. Strict nested signatures, ordered signer authorities, load commands, launch
   contexts, resolved dependencies, system-target availability and empty metadata.
4. Current product-profile offline imports, exact module/data origins, empty
   private roots and observed EPERM/EACCES network/read/write denials.
5. Exact helper/model/config/bf_isabella pins, actual protocol events, ordered
   fresh-output causality and independently parsed nonempty PCM WAV.
6. Distinct cancellation/recovery/EOF/shutdown, same-process recovery, and complete
   process/pipe/output cleanup with source-bound subject/observer events.
7. Owned literal IPv4 listener adoption, private one-shot secret pipe, authenticated
   real inference SSE, native URLSession positive/reconnect/wrong-pin and teardown.
8. Equivalent Voice/Splash cases under spaces/comma/Unicode, long eSpeak path and
   unchanged closure. Copied model-owner receipts may have different artifact paths
   only with identical owner/model facts and exact identical raw receipt bytes.
9. All nine before/after closures, no-follow metadata and complete independently
   admitted target/draft/vision model-input rechecks.

Expected roots, identities, lock versions and resolved required interpreters are
derived privately. Only fixed per-gate expectation fields enter from approval.
Actual argv/environment/source/target/raw outputs must match exact reviewed
invocations. Receipt headers bind a concrete validated event, macOS/arm64 host,
wall diagnostics, integer duration, exited-zero outcome and complete cleanup.
Arbitrary nonempty observations, echo-prefix probes or self-approved markers fail.

Actual observation harnesses remain prerequisites. Distribution/import/immutable
observers must emit their own canonical facts. Voice observers must emit ordered
causality. Splash supervisor private stdout contains an API key: it stays only in
memory, never an artifact/log or a redacted stream labelled raw evidence. Retain
only the reviewed observer's own nonsecret stdout. Native URLSession needs reviewed
Swift source and compiled binary plus build provenance. A source-pinned Python
builder observer uses the fixed bundled interpreter and executes fixed
`/usr/bin/swiftc`; exact compiler/SDK/source/output identities, raw outcomes and
fresh output creation are validated. Two independent source/binary hashes are
insufficient. These genuine harnesses, owner inventory/model admission and native
receipts are absent; this implementation does not invent them or authorize runs.

Fresh static verification uses only fixed root-owned Apple tools in deny-write,
deny-network, deny-fork sandboxing and held descriptors. It retains exact raw
bytes; timeout/signal/nonzero/launch error never means pass. Non-reaping child
observation precedes bounded owned-process-group teardown. Containment depends on
actual Darwin fork/posix_spawn denial; a tool requiring child creation fails closed.
No-follow xattrs reject nonempty/unsupported metadata and are never cleared.
System dependencies require fixed trusted disk-file identity or exact current
arm64 dyld shared-cache membership/UUID, with ambiguity and missing targets rejected.
Fresh raw events are reparsed and inventory/edges/system availability must exactly
match the retained, already-admitted static gate before writer entry.

Bounds: 30 seconds per command, 300 seconds for static inspection, 600 seconds for
finalization, 2 MiB combined raw streams per command, 32 MB fresh raw aggregate,
4096 native objects, 100000 dependency edges and 120 MB retained evidence/attempt
aggregate. System checks cap unique targets at 4096 and disk hashing at 1 GB.
Apple `/dev/fd`, no-follow xattrs, dyld APIs/cache layout, output grammars, signing
layout and sandbox compatibility remain native-unverified; unsupported rejects.
The dyld API signatures were checked against Apple's primary header, but that is
not execution evidence: https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld_priv.h

Finalization holds an exclusive nonblocking flock on the original owned checkpoint
inode. Evidence goes to a unique bounded private attempt. Deterministic legacy
schema-1 manifest publication is atomic/no-replace; source/payload are reaudited,
then the acceptance marker is published last. The marker only binds independent
source approval and a transcript; it never authorizes itself. Resume recognizes
only exact manifest bytes, replays the prior committed raw transcript, performs
fresh static checks, retains a new attempt and preserves the original marker.
Abandoned attempts remain unaccepted; no recursive cleanup or unexpected overwrite
occurs. Failed static captures may be retained while resource/time budget remains.
No failure triggers repair/signing or a weaker retry. Same-UID mutation after the
last checked edge is not claimed preventable; later use must independently recheck.

Complete synthetic nine-gate admission tests exercise actual semantic validators
and raw static parsers without mocks. Separate transaction tests explicitly mock
native boundaries. Neither is production admission or genuine Darwin evidence.
Accepted-copy/archive/build/auditor/whole-app integration remains separately owned.

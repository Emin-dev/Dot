# Passive research recovery and explicit local completion

## Scope and baseline

This source slice is based on published commit `4e631b2612868b18561342d4ee8370e0e26ade62` (228 tracked files). It implements the current checklist's persistent-mission restart, explicit Resume, checked-output, cancellation and stale-view requirements. It is a prepared source candidate, not evidence of publication, native execution, installation or product completion.

The original bug treated every active record absent from one store instance's local ownership set as interrupted and rewrote its revision during passive list/load. A second live reader could therefore invalidate a legitimate writer's next compare-and-swap checkpoint.

## Recovery contract

- Passive list/load validate raw records and return a conservative paused projection for locally unowned active checkpoints. In-flight queries appear uncertain; in-flight reads appear pending. Saved bytes, revision, update timestamp and reconciliation timestamp stay unchanged.
- Create/save/delete/deleteAll reload raw records under the existing transaction lock. Unrelated mutations cannot persist another record's projection. Failed target writes do not reconcile other records as a side effect.
- An explicit target save uses the raw expected revision and existing replacement checks. Only a successful target write records reconciliation metadata. Deletion and stale-write fences remain; saving is never an upsert.
- Resume checks the displayed selection's revision before binding work. A ready retrieval can explicitly commit its awaiting-local-synthesis barrier before provider-free local synthesis. It cannot skip unqueued source results unless the saved source-slot cap is already reached.
- Unknown search outcomes, reviewed retries, cooldown, per-query attempts, total search budget and transient retention retain their existing behavior. Browsing never starts work. The existing evidence-eligibility helper and retrieval workflow are unchanged in this slice.

Local ownership does not establish process death. This is not a cross-process execution lease or an at-most-once network guarantee. A request issued by another owner may still finish; its next stale checkpoint is rejected after a competing explicit commit.

## Required checked-output and ownership prerequisites

The recovery tests depend on the existing separately reviewed durable-output implementation. This slice therefore adds its optional pending/checked output receipt, immutable completed-payload replacement guard, exact original-output and checked-receipt readbacks, explicit local-only verification Resume, and follow-up receipt clearing. Legacy answers lacking the optional field remain readable with unknown verification. A checked receipt certifies structural/citation checks and exact local storage readback, not semantic truth.

The model captures an admitted write before checking cancellation. A synchronous observer's Stop/Close cannot lose that receipt, publish a late success notice or overlap a replacement operation. The operation handle owns admission before Published callbacks; an idle-publication reservation prevents reentrant replacement during cleanup.

The existing ResearchTaskProgress value adapter supplies the accepted event/receipt contract and is registered in SwiftPM and native app/test targets. Its single LongTaskProgress elapsed-time accessor is imported as a dependency. No task presentation controller, new visible halo, task speech, App wiring, Engine change, source transport, PDF change, new service, database or scheduler is included. The only presentation addition is the receipt-specific message telling the user to Resume a pending final local check.

## Regression coverage and evidence limits

The prepared source has 38 store, 44 native interface and 17 value-adapter test declarations, 99 total. That is 56 added names and one replaced obsolete test name relative to the base. All 16 requested recovery regression method bodies remain identical to their reviewed implementation. Interface progress tests exercise the value adapter directly rather than importing the separate presentation controller. Fixture sources retain the current published constructors and evidence rules.

Portable checks on the candidate:

- 286 Python tests: 282 passed, 4 skipped.
- The skips are two macOS Seatbelt checks and optional pinned SearXNG/Waitress fixtures not provided to this run.
- 52 repository source guardrails passed.
- 25 focused recovery/durable-output source-contract checks passed within that aggregate.
- Base identities, bounded changed paths, native registration edges and unique declarations were checked independently of filename presence.

These are source-contract/Python results. They do not execute or type-check Swift. SwiftPM, native XCTest, Debug/Release builds, packaging, native UI, real process restart, provider/device acceptance and installation remain unrun for this exact closure. Earlier reviews are provenance for the imported behavior; they do not certify the adapted combination.

On an authorized macOS exact-source checkout, run `scripts/verify_macos.sh`. At minimum the SwiftPM WebResearchStoreTests and ResearchTaskProgressTests plus native DotTests/WebResearchInterfaceTests must pass, including held-request interleavings, concurrent CAS loss/deletion, admitted-save Stop, final readback faults and synchronous Published callbacks. Preserve the installed application until separately authorized replacement.

## Independent-review corrections in v2

The first prepared candidate had two source-review blockers, now corrected in this isolated successor:

1. The cancelled-task adapter test resumed an already settled local-synthesis plan but expected unknown progress. It now expects the actual measured 0.5 fraction and retains cancellation plus rejection of late verification.
2. Stop cleanup used an incomplete readiness check and could skip an unqueued third result while retaining two already-read sources. Cleanup now normalizes to paused and reuses the same complete local-ready predicate as explicit Resume, including unread-result/source-cap semantics. Already-ready local receipts retain provider-free continuation.

A new synchronous selected-publication regression holds two completed source receipts and one distinct unqueued result, Stops the first explicit Resume before new work, and verifies the next Resume reads only the third source without re-searching or changing the saved query attempts. Its source-cap variant requires no extra read and resumes without a provider. The result is added before the first completed-query save, respecting immutable query-result replacement rules.

Both new source guards reject the frozen first candidate. This is an expected-red source witness; native behavioral red/green remains unrun. The original 16 recovery regression bodies are unchanged.

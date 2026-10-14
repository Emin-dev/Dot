# EngineManager client-inference admission

## Scope and publication gate

This seven-file candidate is staged against published
`1fbd42f4855fafdc0a204215c0e61fc948794397`. It retains the reviewed manager
admission policy and replaces the inference async-bytes transport with an
explicitly owned suspended data task. It has not been compiled or run on macOS.
Independent concurrency/security review and exact-source native acceptance are
required before integration/publication. Existing native CI results for other
revisions do not validate these bytes.

The changed files are Engine.swift, ChatView.swift, InteractionCore.swift,
ResearchEngineTests.swift, EngineIntegrationTests.swift,
test_engine_admission_contract.py and this document. No project membership,
workflow, package, runtime helper, alternate engine, download or installed app
changes are included. Published `research.sources` evidence semantics remain.
ChatView changes are limited to explicit passive-background purpose and the
exhaustive busy diagnostic; the question result gains Sendable conformance.

## Admission and the three lifetimes

One `@MainActor EngineManager` owns at most one inference and one foreground
waiter. Research synthesis and optional passive suggestions are background;
normal chat defaults to foreground. A foreground request reserves the waiting
slot before cancelling background work. It never evicts foreground work.
Background requests do not queue. Excess callers receive `EngineError.busy`.
Cancellation/removal/release are token-checked so stale work cannot remove a
new reservation. Shutdown closes new inference/readiness admission first.

These lifetimes remain separate:

1. The manager-owned Swift child includes readiness, screen setup, parsing,
   validation and delivery cleanup. The manager joins it even when the caller
   is cancelled, and rechecks preemption before publishing a result.
2. A per-inference URLSession and exact URLSessionDataTask. Consumers wake on
   cancellation, but admission remains held until the exact resumed task emits
   its completion callback and its session acknowledges invalidation.
3. Backend generation/GPU/model resources. A client transport receipt does not
   prove backend cancellation, resource release or measured preemption latency.

The manager is not a global lock across independently created managers. Its
existing readiness session remains separate from inference traffic and retains
its bounded status parser. Readiness rechecks shutdown after awaited setup.

## Explicit task ownership

Request assembly, pin snapshot and configuration precede transport start. The
production initializer creates one session whose session/data delegate is the
transfer, calls `dataTask(with:)` to obtain a suspended task, and installs that
exact handle before any `resume()`. There is no dependency on `didCreateTask`,
`bytes(for:delegate:)` ordering, a late task-discovery callback, or an ambiguous
no-task fast path. Readiness alone still uses the existing async-bytes API.

A serial lifecycle queue owns start, suspend/resume, cancellation, buffering,
waiters and callbacks. The single-operation delegate queue uses that same
underlying queue. Nested callbacks execute inline when already on it, avoiding
synchronous dispatch deadlock. State is committed before external task/session
calls. No semaphore, spin loop or synchronous network wait runs on MainActor.

Cancellation before start cancels the known never-resumed task and invalidates
its session without ever resuming network work. It still awaits invalidation.
Once started, task completion and session invalidation are independent receipts;
both are required. Cancelling the settlement waiter cannot substitute for either.
No timer manufactures settlement. A missing resumed-task receipt fails closed.

Completion drops the retained task; invalidation drops the retained session.
The immutable session identity remains so an exact late task receipt can be
accepted after invalidation without retaining the session/delegate cycle.
Foreign and duplicate receipts cannot replace/reopen the lifecycle.

A narrowly internal receipt-test initializer installs a test-supplied session
and never-resumed task through the same state initialization/installation path.
It checks suspended state and zero sent/received byte counts. Those observations
cannot prove the pair's provenance or that it was never resumed previously;
manual-receipt tests supply that authenticity themselves. EngineManager and
request input cannot select this seam. It is not evidence of Foundation receipt
ordering and does not replace production-route URLProtocol or TLS tests.

## Streaming bounds and backpressure

A single coalesced Data buffer feeds one async byte consumer in chunks of at
most 16,384 bytes. Before retaining each callback's data, the transfer enforces
both a 4,000,000-byte lifetime receive budget and a 4,000,000-byte buffer bound.
An oversized callback or queued callback burst fails and cancels; it cannot be
silently truncated into success. No unbounded AsyncStream/chunk array is used.

At 262,144 buffered bytes the task is suspended once. Draining to 131,072 bytes
resumes it. Already queued callbacks may still arrive, so the hard cap applies
even while suspended. Cancellation balances only a suspension issued by this
transfer, after requesting cancellation; a never-started task is never resumed
for teardown. Natural completion removes the need to resume a terminal task.

Pending header/body consumers fail promptly on cancellation. Existing parser
limits remain: 262,144 bytes per SSE line, 4,000,000 total parsed bytes, and the
64,000-byte output budget. UTF-8 handling, terminal markers, HTTP/runtime/model
identity checks, synthesis validation and StreamDelivery cleanup remain. Early
DONE, parser/output failure, HTTP rejection and caller cancellation all enter
the same cancellation-and-receipt settlement path before manager release.
A separate sticky terminal failure survives consumer cancellation and buffer
clearing. The shared result-after-settlement fence preserves an existing parser
failure, and rejects parser success if a receive/transport failure arrived while
the parser held an already-detached chunk. Intentional post-DONE cleanup and its
expected cancelled receipt do not become failures; an unexpected cancelled
receipt before this transfer requested cancellation remains a genuine failure.

## Security preservation

Each inference uses a fresh session and the existing NoRedirects policy for
certificate pinning and redirect refusal. The production transfer is the actual
session/data delegate; no wrapper session supplies a fallback pin. Both
readiness and inference share explicit direct-loopback configuration disabling
HTTP, HTTPS, SOCKS, PAC and proxy autodiscovery. Cache, cookies and stored
credentials remain disabled. Existing endpoint validation and authorization
assembly are unchanged. Per-inference sessions trade connection-pool reuse for
small explicit ownership; no backend/runtime owner is added.

Native TLS tests use the existing model-free TLS endpoint through this exact
production transfer. They require two fresh correct-pin connections, wrong-pin
rejection before any Authorization bytes reach the endpoint, both settlement
receipts, and released handles. Redirect tests intercept every proposed
same-origin/cross-origin destination and assert that no redirected request is
submitted. Direct configuration assertions do not prove behavior under a real
system proxy or PAC; installed-device acceptance remains separate.

## Test coverage and limits

Existing manager regressions retain foreground/background admission, one waiter,
noncooperative setup, cancelled/replaced waiters, shutdown, early DONE/HTTP
failure, pre-header failure and follow-on admission. Added transport tests cover:

- Installed suspended task before start; cancellation before start and an
  already-cancelled caller without a submitted request; never-resumed teardown
- Cancelled header/body consumers while settlement remains held, with body
  cancellation gated on actual chunk-waiter registration; cancellation of
  the settlement waiter; completion before waiting; duplicate/foreign receipts
- Invalidation before exact completion; inline response callback reentrancy into
  cancellation/completion/invalidation without blocking MainActor
- Synchronous callback bursts, byte-split UTF-8/SSE lines, slow-consumer balanced
  suspension/resumption, cancellation while suspended, delegate-cycle release
- Exact-limit large callbacks, callback overflow after suspension and oversized
  single callbacks rejected before retention; a fully production-valid detached
  answer/stop/DONE sequence (including QuestionIntentStream validation) after overflow,
  connection failure or unexpected cancellation cannot bypass the shared final
  result fence, while intentional post-DONE cleanup still succeeds
- Actual WebResearchModel pre-header-failure flush; cancellation and the same
  panel-close-admissions/model-flush sequence used by applicationShouldTerminate

The quit test exercises the real panel/model/engine drain boundary. A source
contract connects that sequence to the application's termination callback. It
does not terminate a running installed application or prove full OS quit/device
behavior. Suspended transfer cancellation is tested separately through the
production transport. URLProtocol stop barriers are supporting integration
evidence, not a standalone proof of manager serialization: separate continuation
barriers test manager ownership and manual receipts test the transport state.

Portable validation on the staged source: 336 Python tests discovered, four
skips (two macOS-only and two optional pinned inputs absent), no failures;
16 focused admission source contracts and 52 aggregate static guardrails passed.
A Swift tree-sitter grammar scan of the three changed engine/test files found no
parse errors. None of these compiles Swift, runs XCTest or proves Foundation
behavior. Native Debug/Release warning-as-error compilation, all native tests,
real backend release/performance, full application quit, installed-device and
owner acceptance remain unrun for this candidate.

"""Source-contract guards for the two-owner research reconciliation regression.

These do not execute or type-check Swift. The continuation-gated native store and
controller XCTest cases remain the behavioral acceptance gate.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def body(source, signature, next_signature):
    return source.split(signature, 1)[1].split(next_signature, 1)[0]


class ResearchReconciliationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store = (ROOT / 'src/WebResearchStore.swift').read_text()
        cls.durable = cls.store.split('actor WebResearchSessionStore:', 1)[1].split('actor TransientWebResearchStore:', 1)[0]
        cls.panel = (ROOT / 'src/WebResearchPanel.swift').read_text()
        cls.workflow = (ROOT / 'src/WebResearch.swift').read_text()

    def test_public_reads_only_project_validated_raw_records(self):
        listing = body(self.durable, '    func list() throws', '    func load(id:')
        loading = body(self.durable, '    func load(id:', '    /// IDs are minted')
        self.assertIn('try read(folder).sessions.map(recoveryProjection)', listing)
        self.assertIn('try read(folder).sessions.first', loading)
        self.assertIn('return recoveryProjection(stored)', loading)
        for operation in (listing, loading):
            self.assertIn('try transaction { folder in', operation)
            self.assertNotIn('persist(', operation)
            self.assertNotIn('rememberOwned(', operation)

    def test_projection_preserves_identity_time_and_durable_bytes(self):
        self.assertIn('private func recoveryProjection(', self.durable)
        projection = body(self.durable, 'private func recoveryProjection(', 'private func needsReconciliation(')
        self.assertIn('revision: stored.revision, session: session, recoveredAt: stored.recoveredAt', projection)
        self.assertIn('session.stage = .paused', projection)
        self.assertIn('.status = .uncertain', projection)
        self.assertIn('.failure = .interruptedOutcomeUnknown', projection)
        self.assertIn('.status = .pending', projection)
        for token in ['persist(', 'UUID()', 'now()', 'updatedAt =', 'rememberOwned(', 'await ']:
            self.assertNotIn(token, projection)

    def test_every_mutation_reloads_raw_under_transaction(self):
        for start, end in [
            ('    func create(question:', '    /// Compare-and-swap'),
            ('    func save(_ session:', '    func delete(id:'),
            ('    func delete(id:', '    /// Explicitly deletes'),
            ('    func deleteAll()', '    /// An unowned active'),
        ]:
            with self.subTest(method=start):
                operation = body(self.durable, start, end)
                self.assertIn('try transaction { folder in', operation)
                self.assertIn('try read(folder)', operation)
                self.assertLess(operation.index('try read(folder)'), operation.index('try persist('))
                self.assertNotIn('recoveryProjection(', operation)
                self.assertNotIn('readAndRecover(', operation)

    def test_reconciliation_receipt_only_follows_target_cas(self):
        saving = body(self.durable, '    func save(_ session:', '    func delete(id:')
        self.assertLess(saving.index('previous.revision == expectedRevision'), saving.index('needsReconciliation(previous)'))
        self.assertLess(saving.index('validResearchReplacement(previous:'), saving.index('needsReconciliation(previous)'))
        self.assertIn('needsReconciliation(previous) ? now() : previous.recoveredAt', saving)
        self.assertLess(saving.index('document.sessions[index] = stored'), saving.index('try persist('))
        self.assertLess(saving.index('try persist('), saving.index('rememberOwned(document, adding: stored.revision)'))
        self.assertIn('not an execution lease', self.durable)

    def test_explicit_resume_binds_the_selected_revision_before_work(self):
        resume = body(self.panel, '        begin(selected.session.stage', '    func retryReviewedService()')
        guard = resume.index('guard current.revision == selected.revision')
        self.assertLess(guard, resume.index('model.activeStored = current'))
        self.assertLess(guard, resume.index('model.researchSessionID = current.id'))
        self.assertLess(guard, resume.index('store.save('))
        self.assertLess(guard, resume.index('model.research('))

    def test_local_terminal_reconciliation_commits_before_synthesis_and_captures_write(self):
        resume = body(self.panel, '        begin(selected.session.stage', '    func retryReviewedService()')
        self.assertIn('session.stage = .awaitingLocalSynthesis', resume)
        self.assertIn('store.save(session, expectedRevision: selected.revision)', resume)
        self.assertLess(resume.index('store.save('), resume.index('model.research('))
        after_save = resume.split('current = try await store.save(', 1)[1]
        self.assertLess(after_save.index('model.activeStored = current'), after_save.index('try model.check(token)'))
        self.assertNotIn('provider.search', resume)
        self.assertNotIn('workflow.run', resume)

    def test_terminal_readiness_does_not_skip_unqueued_bounded_reads_or_retry_gates(self):
        terminal = body(self.panel, 'private static func hasTerminalRetrieval(', 'private static func canFinishRetrievalLocally(')
        self.assertIn('session.queries.allSatisfy', terminal)
        self.assertIn('session.reads.allSatisfy', terminal)
        self.assertEqual(terminal.count('$0.status == .completed || $0.status == .failed'), 2)
        local = body(self.panel, 'private static func canFinishRetrievalLocally(', 'private static func hasSynthesisEvidence(')
        self.assertIn('hasTerminalRetrieval(session)', local)
        self.assertIn('hasSynthesisEvidence(session)', local)
        self.assertIn('session.unreadResultCount == 0 || session.reads.count >= session.limits.maxSources', local)
        admission = body(self.panel, '    var canResume:', '    var canFollowUp:')
        self.assertLess(admission.index('session.retryRequiresReview != true'), admission.index('Self.canFinishRetrievalLocally(session)'))
        self.assertLess(admission.index('session.retryNotBefore.map'), admission.index('Self.canFinishRetrievalLocally(session)'))
        self.assertLess(admission.index('Self.canFinishRetrievalLocally(session)'), admission.index('guard configured'))

    def test_stop_cleanup_reuses_complete_local_readiness_after_normalizing_stage(self):
        cleanup = body(self.panel, '    func foregroundPause()', '    func reload()')
        self.assertIn('session.stage = .paused', cleanup)
        self.assertIn('if Self.canFinishRetrievalLocally(session) { session.stage = .awaitingLocalSynthesis }', cleanup)
        self.assertLess(cleanup.index('session.stage = .paused'), cleanup.index('Self.canFinishRetrievalLocally(session)'))
        self.assertLess(cleanup.index('Self.canFinishRetrievalLocally(session)'), cleanup.index('store.save(session'))
        self.assertNotIn('session.stage = Self.hasSynthesisEvidence(session)', cleanup)
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchInterfaceTests.swift').read_text()
        case = body(tests, 'func testStopRetainsEvidenceAndReadsUnqueuedResultBeforeSynthesisUnlessAtSourceCap()',
                    'func testExplicitResumeRejectsChangedSelectedRevisionBeforeAnyNewWork()')
        for token in ['for atSourceCap in [false, true]', 'retainedSources.count, 2',
                      'active.session.unreadResultCount, 1', 'model.$selected.sink',
                      'stopped = true; model.cancel()', 'session.searchAttempts, attempts',
                      'atSourceCap ? [] : ["/third"]']:
            self.assertIn(token, case)
        self.assertNotIn('retrieved.reads = []', case)

    def test_cancelled_local_synthesis_resume_keeps_known_progress_and_stale_fence(self):
        tests = (ROOT / 'Tests/DotCoreTests/ResearchTaskProgressTests.swift').read_text()
        case = body(tests, 'func testCancelledTaskRejectsLateVerificationAndCanBeExplicitlyResumed()',
                    'func testStoredDoneStatusAloneNeverCompletes()')
        self.assertIn('XCTAssertEqual(model.progress.halo, .hidden)', case)
        self.assertIn('XCTAssertFalse(model.receive(event(op, 2, .verifying(session)), now: 123))', case)
        self.assertIn('XCTAssertEqual(model.progress.halo, .determinate(0.5))', case)
        self.assertNotIn('.indeterminate', case)

    def test_workflow_keeps_attempt_caps_and_initial_checkpoint_before_request(self):
        run = body(self.workflow, '    func run(_ original:', '    private func checkActive()')
        self.assertIn('session.retryPolicy == .retryUncertainWithinBudget', run)
        self.assertIn('session.queries[index].attempts < 2, session.searchAttempts < session.limits.maxSearchAttempts', run)
        self.assertIn('session.queries[index].attempts += 1', run)
        self.assertLess(run.index('try await checkpoint(&session, onCheckpoint)'), run.index('provider.searchResponse('))
        self.assertIn('throw WebResearchError.checkpointFailed', self.workflow)

    def test_output_verification_and_deletion_fences_remain(self):
        replacement = self.store.split('private func validResearchReplacement(', 1)[1]
        self.assertIn('guard payload == previous else { return false }', replacement)
        self.assertIn('previous.outputVerification == .pending, next.outputVerification == .checked', replacement)
        self.assertIn('guard next.outputVerification == .pending else { return false }', replacement)
        saving = body(self.durable, '    func save(_ session:', '    func delete(id:')
        self.assertIn('else { throw WebResearchStoreError.notFound }', saving)
        self.assertNotIn('sessions.append(', saving)
        deletion = body(self.durable, '    func delete(id:', '    /// Explicitly deletes')
        self.assertIn('revision == expectedRevision', deletion)
        self.assertIn('document.sessions.remove(at: index)', deletion)

    def test_transient_store_keeps_its_no_disk_boundary(self):
        memory = body(self.store, 'actor TransientWebResearchStore:', 'private func validResearchReplacement(')
        for token in ['FileManager', 'persist(', 'directory', 'recoveryProjection(', 'openat(', 'write(', 'recoveredAt: now()']:
            self.assertNotIn(token, memory)
        self.assertIn('let retention = WebResearchRetention.transient', memory)
        self.assertIn('session.storageMode == .transient', memory)

    def test_meaningful_native_interleavings_and_ui_cases_exist(self):
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchStoreTests.swift').read_text()
        for name in ['testForeignReadProjectsUnknownOutcomeWithoutChangingBytesOrOwnerRevision',
                     'testForeignMutationsPreserveRawUnrelatedActiveRecord',
                     'testFailedForeignMutationsDoNotCommitRecoveryAsASideEffect',
                     'testExplicitRecoverySaveCommitsOnlyTargetAndFencesOldRevision',
                     'testStaleRecoveryCannotReplaceCommitOrResurrectDeletedRecordOrDispatchSearch',
                     'testForeignReadDuringSuspendedSearchCannotInvalidateLiveWorkflowCheckpoint',
                     'testForeignReadDuringSuspendedSourceCannotInvalidateLiveWorkflowCheckpoint',
                     'testExplicitResumeReconcilesBeforeRequestsAndPreservesUncertainAttemptCaps',
                     'testRecoveryProjectionRetainsRetryGatesUntilExplicitAction',
                     'testForeignObservationPreservesExactPendingAndCheckedOutputReceipts']:
            self.assertIn('func ' + name, tests)
        self.assertIn('try await waitForRequest { await provider.waiting() }', tests)
        self.assertIn('try await waitForRequest { await reader.waiting() }', tests)
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchInterfaceTests.swift').read_text()
        for name in ['testExplicitResumeReconcilesTerminalRetrievalBeforeProviderFreeLocalSynthesis',
                     'testExplicitResumeWithTerminalQueriesStillReadsUnqueuedResults',
                     'testExplicitResumeRejectsChangedSelectedRevisionBeforeAnyNewWork',
                     'testLostReconciliationCASCannotStartSynthesisOrRestoreDeletedTarget',
                     'testStopDrainsAdmittedReconciliationBeforeLaterLocalResume',
                     'testUncertainOnlyPreservePolicyStillNeedsNoAutomaticOrExplicitReplay']:
            self.assertIn('func ' + name, tests)


if __name__ == '__main__':
    unittest.main()

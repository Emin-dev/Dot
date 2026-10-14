"""Source-contract guards only. Native XCTest is the behavior acceptance gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class DurableResearchOutputContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.session = (ROOT / 'src/WebResearch.swift').read_text()
        cls.store = (ROOT / 'src/WebResearchStore.swift').read_text()
        cls.panel = (ROOT / 'src/WebResearchPanel.swift').read_text()

    def test_optional_legacy_field_and_strict_enum(self):
        self.assertIn('var outputVerification: WebResearchOutputVerification?', self.session)
        self.assertIn('enum WebResearchOutputVerification: String, Codable, Sendable { case pending, checked }', self.session)
        self.assertIn('(outputVerification == nil || stage == .completed)', self.session)

    def test_completion_pending_followup_clears(self):
        completion = self.session.split('func completing(')[1].split('func addingQueries(')[0]
        followup = self.session.split('func addingQueries(')[1].split('func evidenceJSON(')[0]
        self.assertIn('copy.outputVerification = .pending', completion)
        self.assertIn('copy.outputVerification = nil', followup)

    def test_receipt_bound_to_unchanged_payload(self):
        replacement = self.store.split('private func validResearchReplacement(')[1]
        self.assertIn('payload.outputVerification = previous.outputVerification', replacement)
        self.assertIn('guard payload == previous else { return false }', replacement)
        self.assertIn('previous.outputVerification == .pending, next.outputVerification == .checked', replacement)
        self.assertIn('guard next.outputVerification == .pending else { return false }', replacement)

    def test_explicit_resume_only_without_network_or_synthesis(self):
        completed = self.panel.split('func resume()')[1].split('begin(selected.session.stage')[0]
        self.assertIn('selected.session.outputVerification == .pending', completed)
        self.assertIn('model.pendingVerification = selected', completed)
        self.assertIn('model.verifyCompleted(selected', completed)
        self.assertNotIn('model.research(', completed)
        self.assertNotIn('synthesize(', completed)
        loading = self.panel.split('func reload()')[1].split('func start()')[0]
        self.assertNotIn('verifyCompleted', loading)

    def test_original_readback_precedes_receipt_write(self):
        check = self.panel.split('private func verifyCompleted(')[1].split('private func checkpoint(')[0]
        self.assertLess(check.index('guard reloaded == expected'), check.index('store.save(checked'))
        self.assertLess(check.index('guard selected == expected'), check.index('store.save(checked'))
        self.assertLess(check.index('guard receipt == verified'), check.index('emitProgress(.verified'))
        self.assertLess(check.index('guard selected == verified'), check.index('emitProgress(.verified'))
        self.assertIn('reloaded: checkedReadback', check)

    def test_admitted_write_captured_before_cancellation(self):
        check = self.panel.split('verified = try await store.save(checked')[1]
        self.assertLess(check.index('activeStored = verified; pendingVerification = verified'), check.index('try check(token)'))

    def test_refresh_rechecks_synchronous_observer_cancellation(self):
        check = self.panel.split('private func verifyCompleted(')[1].split('private func checkpoint(')[0]
        for identifier in ['expected', 'verified']:
            tail = check.split(f'preferred: {identifier}.id, token: token)')[1]
            self.assertLess(tail.index('try check(token)'), tail.index(f'guard selected == {identifier}'))

    def test_completion_callback_rechecks_before_receipt_cleanup_or_notice(self):
        check = self.panel.split('private func verifyCompleted(')[1].split('private func checkpoint(')[0]
        after_callback = check.split('emitProgress(.verified(expected: verified, reloaded: checkedReadback), token: token)')[1]
        self.assertIn('try check(token)', after_callback)
        self.assertLess(after_callback.index('try check(token)'), after_callback.index('pendingVerification = nil'))
        self.assertLess(after_callback.index('try check(token)'), after_callback.index('notice ='))
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchInterfaceTests.swift').read_text()
        self.assertIn('testVerifiedCallbackStopOrCloseCannotPublishLateSuccessOrLoseReadbackRetry', tests)

    def test_operation_handle_owns_admission_before_published_callbacks(self):
        self.assertIn('var busy: Bool { operation != nil || publishingIdle }', self.panel)
        begin = self.panel.split('private func begin(')[1].split('private func emitProgress(')[0]
        self.assertLess(begin.index('operation = Task'), begin.index('self.activity = activity'))
        self.assertIn('if cancellationRequested { self.activity = .pausing }', begin)
        finish = self.panel.split('private func finish(')[1].split('private static func hasSynthesisEvidence(')[0]
        self.assertLess(finish.index('publishingIdle = true'), finish.index('operation = nil'))
        self.assertLess(finish.index('operation = nil'), finish.index('activity = nil'))
        self.assertLess(finish.index('activity = nil'), finish.index('publishingIdle = false'))
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchInterfaceTests.swift').read_text()
        for name in ['testAdmissionActivityObserverStopOrCloseDrainsOwnedTaskBeforeAnyWork',
                     'testAdmissionActivityObserverCannotReplaceOperationBeforeHandleInstallation',
                     'testIdleActivityObserverCannotAdmitWorkDuringOldHandleCleanup']:
            self.assertIn(name, tests)

    def test_progress_requires_checked_receipt(self):
        adapter = (ROOT / 'src/ResearchTaskProgress.swift').read_text()
        self.assertIn('reloaded.session.outputVerification == .checked', adapter)

    def test_ui_pending_status_is_explicit(self):
        self.assertIn('Saved answer awaits its final local check. Use Resume;', self.panel)

    def test_runtime_regression_cases_exist(self):
        tests = (ROOT / 'Tests/DotCoreTests/WebResearchInterfaceTests.swift').read_text()
        for name in ['testRestartOffersOnlyExplicitLocalVerificationOfPendingAnswer',
                     'testRestoredPendingReceiptRejectsDeletedOrChangedRevision',
                     'testStopDrainsAdmittedCheckedReceiptWriteWithoutReplayingAnswer']:
            self.assertIn(name, tests)
        self.assertIn('.thirdReadRevision, .fourthReadRevision, .checkedSaveFailure', tests)

if __name__ == '__main__':
    unittest.main()

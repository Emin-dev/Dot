"""Source-contract regressions, not execution of Swift concurrency or URLSession.

Native request/receipt behavior lives in ResearchEngineTests and TLS integration
checks. Those require macOS, and must pass before claiming the gate is verified.
"""
from pathlib import Path
import unittest
import re

ROOT = Path(__file__).resolve().parents[2]


def section(source, begin, end):
    return source.split(begin, 1)[1].split(end, 1)[0]


class EngineAdmissionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = (ROOT / 'src/Engine.swift').read_text()
        cls.chat = (ROOT / 'src/ChatView.swift').read_text()
        cls.native = (ROOT / 'Tests/DotCoreTests/ResearchEngineTests.swift').read_text()
        cls.tls = (ROOT / 'Tests/DotCoreTests/EngineIntegrationTests.swift').read_text()
        cls.admit = section(cls.engine, 'private func admitInference(', 'private func cancelActiveInference(')
        cls.owned = section(cls.engine, 'private func withInference<Value: Sendable>', 'private static let log')
        cls.release = section(cls.engine, 'private func releaseInference(', 'private func withInference<Value: Sendable>')
        cls.transfer = section(cls.engine, 'final class InferenceTransfer:', 'enum EngineError:')
        cls.chunks = section(cls.engine, 'private func withInferenceChunks<Value: Sendable>', 'nonisolated private static func boundedStatus')

    def test_both_entry_points_share_one_owned_admission(self):
        chat = section(self.engine, 'func chat(history:', 'private func performChat(')
        research = section(self.engine, 'func researchSynthesis(session', 'private func performResearchSynthesis(')
        self.assertIn('purpose: InferencePurpose = .foreground', chat)
        self.assertIn('withInference(purpose: purpose)', chat)
        self.assertIn('withInference(purpose: .background)', research)
        self.assertEqual(self.engine.count('return try await withInferenceChunks(request: request)'), 2)
        self.assertNotIn('bytes(for:', self.chunks)
        self.assertIn('try await transfer.start()', self.chunks)

    def test_pending_is_one_foreground_slot_reserved_before_preemption(self):
        self.assertIn('private var pendingForeground: PendingInference?', self.engine)
        self.assertIn('purpose == .foreground, pendingForeground == nil', self.admit)
        self.assertLess(self.admit.index('pendingForeground = PendingInference('), self.admit.index('cancelActiveInference()'))
        self.assertIn('activeInference?.purpose == .background', self.admit)
        self.assertNotIn('[PendingInference]', self.engine)
        self.assertNotIn('Task.currentPriority', self.engine)

    def test_owned_child_is_joined_and_preemption_checked_after_join(self):
        self.assertLess(self.owned.index('admitInference('), self.owned.index('let request = Task'))
        self.assertIn('defer { releaseInference(id: id) }', self.owned)
        self.assertIn('activeInference?.cancel = { request.cancel() }', self.owned)
        self.assertIn('onCancel: { request.cancel() }', self.owned)
        self.assertLess(self.owned.index('await request.result'), self.owned.rindex('activeInference?.cancellationRequested == false'))
        self.assertLess(self.owned.rindex('activeInference?.cancellationRequested == false'), self.owned.index('return try result.get()'))

    def test_stale_release_and_cancel_are_token_checked(self):
        self.assertLess(self.release.index('activeInference?.id == id'), self.release.index('activeInference = nil'))
        self.assertLess(self.release.index('activeInference = ActiveInference(id: pending.id'), self.release.index('pending.continuation.resume()'))
        cancel = section(self.engine, 'private func cancelPendingInference(', 'private func releaseInference(')
        self.assertLess(cancel.index('pending.id == id'), cancel.index('pendingForeground = nil'))
        active_cancel = section(self.engine, 'private func cancelActiveInference(', 'private func cancelPendingInference(')
        self.assertNotIn('activeInference = nil', active_cancel)
        self.assertNotIn('releaseInference', active_cancel)

    def test_shutdown_closes_admission_before_cancellation_and_warmup(self):
        shutdown = section(self.engine, 'func shutdown() {', '\n}')
        self.assertLess(shutdown.index('inferenceClosed = true'), shutdown.index('cancelPendingInference'))
        self.assertIn('if Task.isCancelled || inferenceClosed', self.admit)
        readiness = section(self.engine, 'func verifyConnection()', '@discardableResult')
        self.assertLess(readiness.index('guard !inferenceClosed'), readiness.index('BundledSplash.shared.connection()'))
        self.assertIn('let connection = try await BundledSplash.shared.connection()\n            try Task.checkCancellation()\n            guard !inferenceClosed', readiness)
        self.assertIn('try await Self.boundedStatus(session: session, request: request)\n                try Task.checkCancellation()\n                guard !inferenceClosed', readiness)

    def test_client_completion_and_invalidation_fence_all_outcomes(self):
        self.assertIn('catch { result = .failure(error) }', self.chunks)
        self.assertLess(self.chunks.index('process(chunks, response)'), self.chunks.index('transfer.resultAfterSettlement(result)'))
        self.assertIn('onCancel: { transfer.cancel() }', self.chunks)
        fence = section(self.transfer, 'func resultAfterSettlement<Value: Sendable>', 'private func checkForFailure()')
        self.assertLess(fence.index('cancel()'), fence.index('await waitForCompletion()'))
        self.assertLess(fence.index('await waitForCompletion()'), fence.index('try await checkForFailure()'))
        self.assertLess(fence.index('try await checkForFailure()'), fence.index('return try result.get()'))
        self.assertIn('if case .success = result', fence)
        self.assertIn('invalidated && (!started || completed)', self.transfer)
        wait = section(self.transfer, 'func waitForCompletion()', 'func resultAfterSettlement')
        for forbidden in ['Task.isCancelled', 'Task.sleep', 'wait(timeout:', 'task == nil']:
            self.assertNotIn(forbidden, wait)
        self.assertIn('if settled { continuation.resume() }', wait)
        self.assertIn('if recordFailure && terminalFailure == nil', self.transfer)
        self.assertIn('recordFailure: !(error is CancellationError)', self.transfer)
        self.assertIn('recordFailure: !cancelled || !Self.isCancellation(error)', self.transfer)

    def test_explicit_suspended_handle_is_installed_before_resume(self):
        creation = section(self.transfer, 'convenience init(request:', '/// Internal receipt-test seam')
        self.assertIn('delegate: self, delegateQueue: callbackQueue', creation)
        self.assertIn('install(session: ownedSession, suspendedTask: ownedSession.dataTask(with: request))', creation)
        self.assertNotIn('.resume()', creation)
        installation = section(self.transfer, 'private func install(', '/// Callbacks use')
        self.assertIn('suspendedTask.state == .suspended', installation)
        self.assertIn('task = suspendedTask', installation)
        start = section(self.transfer, 'func start()', 'struct Chunks:')
        self.assertLess(start.index('started = true'), start.index('task.resume()'))
        self.assertIn('guard !cancelled, !invalidated, let task', start)
        self.assertNotIn('didCreateTask', self.transfer)
        self.assertNotIn('testSession:', self.chunks)
        self.assertNotIn('testRequest:', self.chunks)

    def test_serialized_lifecycle_preserves_identity_after_session_release(self):
        self.assertIn('callbackQueue.maxConcurrentOperationCount = 1', self.transfer)
        self.assertIn('callbackQueue.underlyingQueue = lifecycle', self.transfer)
        self.assertIn('DispatchQueue.getSpecific(key: queueKey)', self.transfer)
        self.assertNotIn('lifecycle.sync', self.transfer)
        self.assertNotIn('DispatchSemaphore', self.transfer)
        complete = section(self.transfer, 'didCompleteWithError error: Error?)', 'didBecomeInvalidWithError error: Error?)')
        self.assertIn('sessionIdentity == ObjectIdentifier(session), self.task === task, !completed', complete)
        self.assertIn('completed = true; self.task = nil', complete)
        invalid = section(self.transfer, 'didBecomeInvalidWithError error: Error?)', 'didReceive challenge:')
        self.assertIn('invalidated = true; self.session = nil', invalid)
        self.assertNotIn('completed = true', invalid)
        cancel = section(self.transfer, 'private func cancelOnLifecycle(', 'private func invalidateSession(')
        self.assertIn('cancelled = true', cancel)
        self.assertNotIn('completed = true', cancel)
        self.assertLess(cancel.index('failConsumers(error,'), cancel.index('ownedTask?.cancel()'))
        self.assertIn('if wasPaused { ownedTask?.resume() }', cancel)
        self.assertNotIn('if !started', cancel)

    def test_coalesced_receive_buffer_and_backpressure_are_bounded(self):
        self.assertIn('private var buffer = Data()', self.transfer)
        self.assertNotIn('AsyncStream', self.transfer)
        self.assertNotIn('[Data]', self.transfer)
        data = section(self.transfer, 'didReceive data: Data)', 'didCompleteWithError error: Error?)')
        self.assertLess(data.index('data.count <= BoundedSSELines.maximumStreamBytes - receivedBytes'), data.index('buffer.append(data)'))
        self.assertLess(data.index('data.count <= Self.maximumBufferedBytes - buffer.count'), data.index('buffer.append(data)'))
        self.assertIn('paused = true; suspendCount += 1', data)
        self.assertIn('task?.suspend()', data)
        self.assertIn('buffer.count <= Self.lowWaterBytes', self.transfer)
        self.assertIn('let count = min(Self.chunkBytes, buffer.count)', self.transfer)
        self.assertIn('onCancel: { self.cancel() }', self.transfer)

    def test_chunk_sequence_removes_per_byte_async_boundary_without_extra_buffer(self):
        chunks = section(self.transfer, 'struct Chunks:', 'private func nextChunk(')
        self.assertIn('typealias Element = Data', chunks)
        self.assertIn('mutating func next() async throws -> Data?', chunks)
        self.assertIn('return try await transfer.nextChunk(consumer: id)', chunks)
        self.assertIn('if Task.isCancelled { transfer.cancel(); throw CancellationError() }', chunks)
        for forbidden in ['UInt8?', 'private var chunk', 'private var offset', 'AsyncStream', 'Task.detached']:
            self.assertNotIn(forbidden, chunks)
        self.assertIn('consumerID == nil || consumerID == consumer, chunkWaiter == nil', self.transfer)
        self.assertIn('for byte in detached', self.native)
        self.assertIn('XCTAssertEqual(detached, Data(wire.utf8))', self.native)
        benchmark = section(self.native, 'func testExactLimitLargeCallbackAndPostSuspendOverflowAreBounded()',
                            'func testOversizedSingleCallbackIsRejectedBeforeRetention()')
        self.assertIn('Data(repeating: 120, count: BoundedSSELines.maximumStreamBytes)', benchmark)
        self.assertIn('for byte in chunk', benchmark)
        self.assertIn('if byte != 120', benchmark)
        self.assertIn('drainedBytes += 1', benchmark)
        self.assertIn('XCTAssertEqual(drainedBytes, BoundedSSELines.maximumStreamBytes)', benchmark)

    def test_inference_delegate_forwards_existing_tls_and_redirect_policy(self):
        self.assertIn('policy = NoRedirects(certificateSHA256: certificateSHA256)', self.transfer)
        self.assertIn('policy.urlSession(session, task: task, didReceive: challenge)', self.transfer)
        self.assertIn('policy.urlSession(session, task: task, willPerformHTTPRedirection: response,', self.transfer)
        self.assertIn('InferenceTransfer(request: request, configuration: inferenceConfiguration()', self.chunks)
        self.assertIn('Self.directConfiguration()', self.engine)
        self.assertIn('guard protocolClasses?.isEmpty == false, let url = LocalEndpoint.validate(configuredEndpoint)', self.engine)
        self.assertNotIn('delegateFactory', self.engine)
        self.assertNotIn('skipVerification', self.engine)
        self.assertNotIn('ObservedInferenceDelegate', self.tls)

    def test_optional_work_explicitly_uses_background_without_prompt_priority(self):
        passive = section(self.chat, 'private func suggest(', 'private func ')  # next private operation
        self.assertIn('self.engine.chat(history: snapshot, purpose: .background', passive)
        summary = section(self.chat, 'private func summariseConversationIntoKeyPoints',
                          'func startProactivity')
        self.assertIn('purpose: .background', summary)
        self.assertIn('onDelta: { delta in output += delta }', summary)
        self.assertNotIn('purpose: .foreground', summary)
        # Two optional background jobs exist: the proactive suggestion and the
        # conversation key-point summary. Neither may take foreground priority.
        self.assertEqual(self.chat.count('purpose: .background'), 2)
        self.assertEqual(self.chat.count('self.engine.chat(history: snapshot, onDelta:'), 1)

    def test_existing_stream_terminal_budgets_and_delivery_remain(self):
        self.assertEqual(self.engine.count('stream: for try await chunk in chunks'), 2)
        self.assertEqual(self.engine.count('for byte in chunk'), 2)
        self.assertEqual(self.engine.count('for try await byte in bytes'), 1)  # bounded status only
        self.assertEqual(self.engine.count('break stream'), 2)
        self.assertEqual(self.engine.count('try Task.checkCancellation()\n                    guard let line = try lines.feed(byte)'), 2)
        self.assertIn('guard sawDone else { throw EngineError.response }', self.engine)
        self.assertIn('guard done else { throw EngineError.response }', self.engine)
        self.assertIn('defer { updates.cancel() }', self.engine)
        self.assertIn('updates.finish()', self.engine)
        self.assertIn('try budget.accept(delta.content); try budget.accept(delta.reasoning)', self.engine)
        self.assertIn('try textBudget.accept(delta.content)', self.engine)
        self.assertIn('try capturedImage?.validateFreshness(now: clock())', self.engine)
        self.assertIn('ResearchSynthesisContract.decode(text, research: research)', self.engine)

    def test_engine_error_switches_cover_every_case_including_busy(self):
        declaration = section(self.engine, 'enum EngineError:', 'var errorDescription:')
        cases = set(re.search(r'case ([a-z, ]+)', declaration).group(1).replace(' ', '').split(','))
        localized = section(self.engine, 'var errorDescription:', '@MainActor\nfinal class EngineManager')
        diagnostics = section(self.chat, 'else if let value = error as? EngineError {', 'else if error is ResponseLimit')
        for switch in (localized, diagnostics):
            handled = set()
            for names in re.findall(r'case ([.a-z, ]+):', switch):
                handled.update(names.replace('.', '').replace(' ', '').split(','))
            self.assertEqual(cases, handled, 'EngineError switch is nonexhaustive')
        self.assertIn('.busy: reason = .unavailable', diagnostics)

    def test_task_result_is_sendable_without_unchecked_value_cast(self):
        core = (ROOT / 'src/InteractionCore.swift').read_text()
        self.assertIn('struct Question: Equatable, Sendable { let text: String }', core)
        self.assertIn('withInference<Value: Sendable>', self.engine)
        self.assertNotIn('unsafeBitCast', self.engine)

    def test_native_regressions_registered_and_distinguish_both_fences(self):
        names = [
            'testForegroundWaitsForResearchClientTransportSettlement',
            'testCancelBeforeAdmissionDoesNotProbeStatusOrSubmitInference',
            'testOwnedChildCancellationWaitsForSetupToActuallyReturn',
            'testOnlyOneForegroundWaiterAndBackgroundCannotPreemptOrQueue',
            'testCancelledWaiterAndLateOldCancellationCannotRemoveNewWaiter',
            'testForegroundPreemptsPassiveSetupWithoutWaitingForItsSchedulerPriority',
            'testSetupFailureAndFailureBeforeHeadersReleaseAdmission',
            'testURLSessionFailureBeforeHeadersCompletesExplicitTaskAndInvalidatesSession',
            'testDoneBeforeHTTPCompletionAndInvalidResponseStillSettleTransport',
            'testShutdownCancelsQueuedRequestAndRetainsActiveUntilSetupSettles',
            'testKnownSuspendedTaskCancellationBeforeStartNeverSubmitsRequest',
            'testAlreadyCancelledStartTearsDownNeverResumedSession',
            'testCancellationWakesHeadersButBothReceiptsFenceSettlement',
            'testCompletionBeforeWaitDuplicateAndForeignReceiptsAreSafe',
            'testInlineResponseCallbackCanReenterCancellationAndReceipts',
            'testSynchronousCallbackBurstPreservesSplitUTF8AndSSELines',
            'testFixedChunkBoundariesPreserveUTF8AndCRLF',
            'testSecondChunkIteratorCannotConsumeOrPoisonFirstIterator',
            'testSlowConsumerSuspendsOnceThenDrainingBalancesResume',
            'testCancelSuspendedProductionTaskSettlesAndReleasesDelegateCycle',
            'testCancellationOfPendingChunkConsumerWakesBeforeTransportSettles',
            'testExactLimitLargeCallbackAndPostSuspendOverflowAreBounded',
            'testOversizedSingleCallbackIsRejectedBeforeRetention',
            'testDetachedDoneChunkCannotHideStickyReceiveOrTransportFailure',
            'testEarlyDoneIntentionalCleanupDoesNotBecomeTransportFailure',
            'testHeldHeaderDeliveryWithAndWithoutContentTypeHasAuthenticSettlement',
            'testResearchModelFlushReturnsAfterPreheaderFailure',
            'testResearchCancellationAndQuitDrainJoinActualTransport',
        ]
        for name in names:
            self.assertIn('func ' + name, self.native)
        self.assertIn('waitingForCompletion', self.native)
        self.assertIn('return priming == Data([32]) && state.waitingForChunk && state.receivedBytes == 1 && state.bufferedBytes == 0', self.native)
        self.assertIn('XCTAssertNil(try questionIntent.completed()', self.native)
        self.assertIn('await barrier.wait()', self.native)
        for name in ['testExplicitInferenceTransferPinsEveryReconnectAndSettles',
                     'testExplicitInferenceWrongPinReceivesNoAuthorizationBytesAndSettles',
                     'testExplicitInferenceTransferDeniesRedirectsWithoutForwardingAuthorizationAndSettles']:
            self.assertIn('func ' + name, self.tls)
        project = (ROOT / 'Dot.xcodeproj/project.pbxproj').read_text()
        self.assertIn('Tests/DotCoreTests/ResearchEngineTests.swift', project)
        self.assertIn('Tests/DotCoreTests/EngineIntegrationTests.swift', project)

    def test_real_receipt_gate_and_token_checked_final_diagnostic(self):
        self.assertIn('callbackQueue.operationCount == 0', self.transfer)
        self.assertIn('callbacks.isSuspended = true', self.native)
        self.assertIn('defer { callbacks.isSuspended = false; transfer.cancel() }', self.native)
        self.assertIn('addTeardownBlock { callbacks.isSuspended = false; transfer.cancel(); await transfer.waitForCompletion() }', self.native)
        self.assertIn('XCTAssertFalse(held.completed); XCTAssertFalse(held.invalidated); XCTAssertFalse(held.settled)', self.native)
        self.assertLess(self.chunks.index('transfer.resultAfterSettlement(result)'), self.chunks.index('let snapshot = await transfer.snapshot()'))
        self.assertLess(self.chunks.index('if activeInference?.id == admissionID'), self.chunks.index('lastInferenceTransportSettlement = (admissionID, snapshot)'))
        self.assertLess(self.chunks.index('lastInferenceTransportSettlement = (admissionID, snapshot)'), self.chunks.index('return try settledResult.get()'))
        self.assertLess(self.owned.index('lastInferenceTransportSettlement = nil'), self.owned.index('try Task.checkCancellation()'))
        self.assertIn('await receipts.wait(requiresCompletion: state.started)', self.native)
        self.assertIn('task.cancel(); task.resume()', self.native)
        self.assertIn('DOT_TEST_HEADER_DELIVERY typed=', self.native)
        self.assertIn('return priming == Data([32]) && state.waitingForChunk && state.receivedBytes == 1 && state.bufferedBytes == 0', self.native)
        self.assertLess(self.chunks.index('transfer.resultAfterSettlement(result)'), self.chunks.index('inferenceTransportSettlements.append((admissionID, snapshot))'))
        self.assertIn('inferenceTransportSettlements.removeFirst(inferenceTransportSettlements.count - 2)', self.chunks)
        self.assertIn('if inferenceTransportSettlements.count > 2', self.chunks)
        overlap = section(self.native, 'func testDoneBeforeHTTPCompletionAndInvalidResponseStillSettleTransport()', 'func testShutdownCancelsQueuedRequestAndRetainsActiveUntilSetupSettles()')
        self.assertLess(overlap.index('let next = Task'), overlap.index('manager.inferenceAdmission.pendingForeground'))
        self.assertLess(overlap.index('manager.inferenceAdmission.pendingForeground'), overlap.index('fixture.releaseHeaders()'))
        self.assertIn('firstAdmissionID = receipt.admissionID', overlap)
        self.assertIn('assertRealSettlementSnapshot(receipt.snapshot)', overlap)
        self.assertIn('[second.admissionID, third.admissionID]', overlap)

    def test_quit_closes_admission_and_joins_real_research_model_before_reply(self):
        app = (ROOT / 'src/App.swift').read_text()
        quit_path = section(app, 'func applicationShouldTerminate(', 'func applicationWillTerminate(')
        self.assertLess(quit_path.index('webResearchPanel?.closeAdmissions()'), quit_path.index('await webResearchPanel?.model.flush()'))
        self.assertLess(quit_path.index('await webResearchPanel?.model.flush()'), quit_path.index('reply(toApplicationShouldTerminate: true)'))
        self.assertIn('WebResearchPanel(model: model).closeAdmissions()', self.native)
        self.assertIn('let flush = Task { await model.flush(); drained = true }', self.native)


if __name__ == '__main__':
    unittest.main()

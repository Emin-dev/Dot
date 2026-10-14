"""Portable source-path guardrails only; native Swift regressions execute in macOS CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HTTPSEvidenceContractTests(unittest.TestCase):
    def test_archival_compatibility_does_not_admit_live_http(self):
        reader = (ROOT / 'src/ResearchNotebook.swift').read_text()
        admission = reader.split('static func allowed(', 1)[1].split('static func validArchivedURL(', 1)[0]
        self.assertIn('== "https" && validArchivedURL(url)', admission)
        workflow = (ROOT / 'src/WebResearch.swift').read_text()
        self.assertIn('Self.validResult($0, archived: true)', workflow)
        self.assertIn('guard ResearchWebReader.allowed(session.reads[index].url) else', workflow)
        self.assertIn('guard source.eligibleForSynthesis,', workflow)

    def test_model_envelope_schema_and_output_citations_use_eligible_sources(self):
        workflow = (ROOT / 'src/WebResearch.swift').read_text()
        self.assertIn('var synthesisSources: [ResearchSource] { sources.filter(\\.eligibleForSynthesis) }', workflow)
        self.assertIn('let sources = synthesisSources', workflow)
        self.assertIn('(!requireAuthenticatedTransport || source.eligibleForSynthesis)', workflow)
        self.assertIn('try validateEvidence(synthesis, requireAuthenticatedTransport: false)', workflow)
        engine = (ROOT / 'src/Engine.swift').read_text()
        self.assertNotIn('research.sources', engine)
        self.assertIn('schema(sourceIDs: research.synthesisSources.map(\\.id))', engine)
        self.assertIn('research.synthesisSources.first(where:', engine)

    def test_optional_policy_marker_and_display_warning_do_not_rewrite_archives(self):
        source = (ROOT / 'src/ProjectBrief.swift').read_text()
        self.assertIn('var transportReceipt: ResearchTransportReceipt? = nil', source)
        self.assertIn('transportReceipt == .httpsOnlyV1 && ResearchWebReader.allowed(originalURL) && ResearchWebReader.allowed(finalURL)', source)
        self.assertIn('guard source.eligibleForSynthesis else { continue }', source)
        self.assertIn('var presentedBriefMarkdown: String', source)
        store = (ROOT / 'src/ResearchNotebook.swift').read_text()
        self.assertIn('return notebook.presentedBriefMarkdown', store)
        read = store.split('    func read() throws -> [ResearchNotebook] {', 1)[1].split('    func textToCopy(', 1)[0]
        self.assertNotIn('save(', read)
        self.assertIn('return document.notebooks', read)

    def test_native_migration_and_pre_model_regressions_are_registered_in_existing_files(self):
        expected = {
            'ResearchHTTPTransportTests.swift': 'testDowngradeRedirectStopsBeforeSecondDNSOrConnection',
            'ResearchNotebookTests.swift': 'testLegacyHTTPNotebookRemainsReadableCopyableExportableWithoutRewritingReceipts',
            'WebResearchTests.swift': 'testMixedEvidenceExcludesLegacyTextAndRejectsCitationsToLegacySource',
            'ResearchEngineTests.swift': 'testLegacyWebEvidenceFailsBeforeAnyModelRequest',
            'WebResearchInterfaceTests.swift': 'testHistoricalAnswerCopyReportLabelsUnverifiedTransportWithoutLosingReceipts',
        }
        project = (ROOT / 'Dot.xcodeproj/project.pbxproj').read_text()
        for filename, method in expected.items():
            self.assertIn(method, (ROOT / 'Tests/DotCoreTests' / filename).read_text())
            self.assertIn(filename, project)


if __name__ == '__main__':
    unittest.main()

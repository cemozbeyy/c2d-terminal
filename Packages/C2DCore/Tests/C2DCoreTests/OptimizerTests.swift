import Foundation
import Testing
@testable import C2DCore

@Suite struct TokenEstimatorTests {
    private func within(_ estimate: Int, _ expected: Int, tolerance: Double = 0.3) -> Bool {
        abs(Double(estimate - expected)) <= Double(expected) * tolerance
    }

    @Test func asciiProseIsAboutFourCharsPerToken() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)   // 900 chars, ~225 tokens
        let e = TokenEstimator.estimate(text)
        #expect(e.source == .heuristicEstimate)
        #expect(within(e.tokens, 225), "got \(e.tokens)")
        #expect(e.confidence.contains("heuristic"))
    }

    @Test func codeIsDenserThanProse() {
        let code = String(repeating: "let x = foo(a, b); if (x > 0) { return [x]; }\n", count: 10)
        let e = TokenEstimator.estimate(code)
        #expect(e.confidence.contains("code-like"))
        #expect(within(e.tokens, 230), "got \(e.tokens)")
    }

    @Test func cjkIsOneTokenPerCharacterAndEmojiTwo() {
        let cjk = String(repeating: "日本語", count: 10)
        #expect(TokenEstimator.estimate(cjk).tokens == 30)
        #expect(TokenEstimator.estimate("🚀🚀🚀").tokens == 6)
        #expect(TokenEstimator.estimate("").tokens == 0)
    }
}

@Suite struct ContextOptimizerTests {
    private func item(_ content: String, mandatory: Bool = false, id: String = UUID().uuidString) -> ContextItem {
        ContextItem(id: id, kind: .file, path: nil, content: content, mandatory: mandatory)
    }

    @Test func removesExactDuplicatesButKeepsMandatoryOnes() {
        let payload = ContextPayload(items: [
            item("same content", id: "a"), item("same content   ", id: "b"), item("same content", mandatory: true, id: "c"), item("other", id: "d"),
        ])
        let r = ContextOptimizer.deduplicate(payload)
        #expect(r.payload.items.map(\.id) == ["a", "c", "d"])
        #expect(r.removedItemIDs == ["b"])
        #expect(r.preservedMandatory == 1)
        #expect(r.after.tokens < r.before.tokens)
        let removed = r.actions.first { $0.kind == .removedExactDuplicate }!
        #expect(removed.originalContent == "same content   ", "original kept for reversal")
        #expect(removed.reason.contains("a"))
    }

    @Test func whitespaceNormalizationIsRecordedAndReversible() {
        let original = "line one  \r\n\r\n\r\n\r\nline two\t\n"
        let r = ContextOptimizer.deduplicate(ContextPayload(items: [item(original, id: "x")]))
        #expect(r.payload.items[0].content == "line one\n\nline two\n")
        let action = r.actions.first { $0.kind == .normalizedWhitespace }!
        #expect(action.itemID == "x" && action.originalContent == original)
        #expect(action.tokensAfter <= action.tokensBefore)
        let clean = ContextOptimizer.deduplicate(ContextPayload(items: [item("already clean", id: "y")]))
        #expect(clean.actions.isEmpty)
    }

    @Test func budgetCheckReportsWithoutMutating() {
        let payload = ContextPayload(items: [item(String(repeating: "word ", count: 400), mandatory: true, id: "m"), item(String(repeating: "word ", count: 400), id: "o")])
        let big = ContextOptimizer.budgetCheck(payload, budgetTokens: 1_000_000)
        guard case .fits(let tokens, let budget) = big else { Issue.record("expected fits"); return }
        #expect(tokens == payload.estimate.tokens && budget == 1_000_000)
        guard case .exceedsBy(let over, let candidates, let mandatoryTokens) = ContextOptimizer.budgetCheck(payload, budgetTokens: 10) else { Issue.record("expected exceeds"); return }
        #expect(over == payload.estimate.tokens - 10)
        #expect(candidates == ["o"], "only optional items are offered for a decision")
        #expect(mandatoryTokens > 0)
        #expect(payload.items.count == 2, "nothing removed")
    }
}

@Suite struct SavingsReportTests {
    private func est(_ t: Int, _ s: MeasurementSource = .heuristicEstimate) -> TokenEstimate { TokenEstimate(tokens: t, source: s, confidence: "") }

    @Test func zeroBaselineAndMismatchedSourcesGiveNoPercent() {
        #expect(SavingsReport.make(baseline: est(0), optimized: est(0)).reductionPercent == nil)
        let mixed = SavingsReport.make(baseline: est(100, .providerConfirmed), optimized: est(50, .heuristicEstimate))
        #expect(mixed.reductionPercent == nil && mixed.source == .unavailable)
        #expect(mixed.label.lowercased().contains("not comparable"))
    }

    @Test func netReductionCanGoNegativeAndHeuristicLabelsNeverSaySaved() {
        let r = SavingsReport.make(baseline: est(100), optimized: est(80), optimizerCost: 50)
        #expect(r.reductionPercent == 20)
        #expect(r.netReduction == -30)
        #expect(r.label.hasPrefix("Estimated"))
        #expect(!r.label.lowercased().contains("saved"))
        #expect(r.label.contains("not provider-confirmed"))
        let confirmed = SavingsReport.make(baseline: est(100, .providerConfirmed), optimized: est(90, .providerConfirmed))
        #expect(confirmed.label.hasPrefix("Confirmed"))
        let worse = SavingsReport.make(baseline: est(100), optimized: est(120))
        #expect(worse.label.contains("increase 20%"))
    }
}

@Suite struct OptimizationStoreTests {
    @Test func roundTripAndAggregatePerSource() async throws {
        let store = try OptimizationStore.inMemory()
        let a = OptimizationRecord(projectPath: "/p", sourceDescription: "dedup", baselineTokens: 100, optimizedTokens: 70, measurementSource: .heuristicEstimate, actionsSummary: "1 duplicate removed", optimizerCostTokens: 2)
        let b = OptimizationRecord(projectPath: "/p", sourceDescription: "dedup", baselineTokens: 50, optimizedTokens: 50, measurementSource: .heuristicEstimate, actionsSummary: "nothing")
        let c = OptimizationRecord(projectPath: "/p", sourceDescription: "usage", baselineTokens: 10, optimizedTokens: 9, measurementSource: .locallyTokenized, actionsSummary: "")
        let other = OptimizationRecord(projectPath: "/q", sourceDescription: "x", baselineTokens: 1, optimizedTokens: 1, measurementSource: .heuristicEstimate, actionsSummary: "")
        for r in [a, b, c, other] { try await store.record(r) }
        let records = try await store.records(projectPath: "/p")
        #expect(Set(records) == Set([a, b, c]))
        #expect(try await store.records(projectPath: "/p", limit: 1).count == 1)
        let totals = try await store.aggregate(projectPath: "/p")
        #expect(totals[.heuristicEstimate] == SourceTotals(baseline: 150, optimized: 120, count: 2))
        #expect(totals[.locallyTokenized] == SourceTotals(baseline: 10, optimized: 9, count: 1))
        #expect(totals[.providerConfirmed] == nil, "sources are never summed together")
    }

    @Test func fileDatabasePersistsAcrossReopen() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-opt-\(UUID().uuidString)/optimizer.sqlite").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let first = try OptimizationStore(path: path)
        try await first.record(OptimizationRecord(projectPath: "/p", sourceDescription: "s", baselineTokens: 5, optimizedTokens: 4, measurementSource: .heuristicEstimate, actionsSummary: ""))
        let second = try OptimizationStore(path: path)   // migration must be idempotent
        #expect(try await second.records(projectPath: "/p").count == 1)
    }
}

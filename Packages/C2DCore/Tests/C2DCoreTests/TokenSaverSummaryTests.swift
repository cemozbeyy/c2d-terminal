import Foundation
import Testing
@testable import C2DCore

@Suite struct OptimizationEventTests {
    private func payload(_ text: String) -> ContextPayload { ContextPayload(items: [ContextItem(kind: .terminalOutput, path: "zsh", content: text)]) }
    private let repeated = (["start"] + Array(repeating: "retrying connection to build server", count: 10) + ["done"]).joined(separator: "\n")
    private let similar = (1...120).map { "Compiling module \($0)/120" }.joined(separator: "\n")

    @Test func eventCarriesMeasuredBytesAndHeuristicTokens() throws {
        let p = payload(repeated)
        let r = ContextOptimizer.optimize(p)
        let e = try #require(OptimizationRecord.event(original: p, result: r, stage: .prepared, projectPath: "/p"))
        #expect(e.originalBytes == repeated.utf8.count)
        #expect(e.resultBytes == r.payload.items[0].content.utf8.count && e.resultBytes! < e.originalBytes!)
        #expect(e.baselineTokens == r.before.tokens && e.optimizedTokens == r.after.tokens && e.measurementSource == .heuristicEstimate)
        #expect(e.mode == .lossless && e.stage == .prepared)
    }

    @Test func unchangedOutputIsNoEvent() {
        let p = payload("one line\nanother line")
        #expect(OptimizationRecord.event(original: p, result: ContextOptimizer.optimize(p), stage: .writtenToFile, projectPath: "/p") == nil)
        #expect(OptimizationRecord.event(original: ContextPayload(items: []), result: ContextOptimizer.optimize(ContextPayload(items: [])), stage: .prepared, projectPath: "/p") == nil)
    }

    @Test func losslessIsTheDefaultAndLossyOnlyWhenOptedInAndApplied() throws {
        let p = payload(similar)
        let byDefault = ContextOptimizer.optimize(p)
        #expect(!byDefault.lossyStepsApplied)
        #expect(OptimizationRecord.event(original: p, result: byDefault, stage: .prepared, projectPath: "/p")?.mode != .lossy)
        let optedIn = ContextOptimizer.optimize(p, output: .init())
        #expect(optedIn.lossyStepsApplied)
        #expect(try #require(OptimizationRecord.event(original: p, result: optedIn, stage: .prepared, projectPath: "/p")).mode == .lossy)
        // Opting in is not enough by itself: output with nothing lossy to fold stays lossless.
        let q = payload(repeated)
        #expect(try #require(OptimizationRecord.event(original: q, result: ContextOptimizer.optimize(q, output: .init()), stage: .prepared, projectPath: "/p")).mode == .lossless)
    }
}

@Suite struct TokenSaverSummaryTests {
    private func event(_ stage: OptimizationStage, _ before: Int, _ after: Int, at t: TimeInterval) -> OptimizationRecord {
        OptimizationRecord(projectPath: "/p", createdAt: Date(timeIntervalSince1970: t), sourceDescription: "s", baselineTokens: before / 4, optimizedTokens: after / 4,
                           measurementSource: .heuristicEstimate, actionsSummary: "condensedOutput", originalBytes: before, resultBytes: after, mode: .lossless, stage: stage)
    }

    @Test func preparedAndHandedOffAreCountedApart() async throws {
        let store = try OptimizationStore.inMemory()
        for r in [event(.prepared, 1000, 400, at: 1), event(.copiedToClipboard, 1000, 400, at: 2), event(.writtenToFile, 500, 250, at: 3)] { try await store.record(r) }
        let totals = try await store.eventTotals(projectPath: "/p")
        let s = TokenSaverSummary(eventTotals: totals, history: try await store.records(projectPath: "/p"), ledger: nil)
        #expect(s.prepared == EventTotals(count: 1, originalBytes: 1000, resultBytes: 400, originalTokens: 250, resultTokens: 100))
        #expect(s.handedOff == EventTotals(count: 2, originalBytes: 1500, resultBytes: 650, originalTokens: 375, resultTokens: 162))
        #expect(s.handedOff?.byteReductionPercent.map { Int($0.rounded()) } == 57)
        #expect(s.latest?.stage == .writtenToFile)
        #expect(s.verifiedSavedTokens == nil, "local byte reductions never become verified savings")
    }

    @Test func noMeasurementMeansNothingInsteadOfZero() {
        let s = TokenSaverSummary(eventTotals: [:], history: [], ledger: nil)
        #expect(s.handedOff == nil && s.prepared == nil && s.latest == nil && s.verifiedSavedTokens == nil)
        #expect(s.usage == nil && s.usagePeriod == nil, "missing provider usage stays missing")
        let unavailable = TokenSaverSummary(eventTotals: [:], history: [], ledger: .unavailable(reason: "no folder"))
        #expect(unavailable.usage == nil && unavailable.usageSessions == 0)
    }

    @Test func providerUsageIsNeverShownAsSavings() {
        let session = TranscriptSession(id: "a", fileURL: URL(fileURLWithPath: "/x/a.jsonl"), cwd: "/p", cliVersion: "2.1.306", models: ["m"], gitBranch: nil,
                                        firstTimestamp: Date(timeIntervalSince1970: 100), lastTimestamp: Date(timeIntervalSince1970: 900), messageCount: 3,
                                        usage: ProviderUsage(inputTokens: 10, outputTokens: 20, cacheReadInputTokens: 57_000_000, cacheCreationInputTokens: 30))
        let ledger = TranscriptLedger(projectPath: "/p", folder: URL(fileURLWithPath: "/x"), sessions: [session], unavailable: [], skippedRecords: 0, inProgressLines: 0)
        let s = TokenSaverSummary(eventTotals: [:], history: [], ledger: .available(ledger))
        #expect(s.usage?.total == 57_000_060 && s.usageSessions == 1)
        #expect(s.usagePeriod == Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 900))
        #expect(s.verifiedSavedTokens == nil && s.handedOff == nil && s.prepared == nil)
    }

    @Test func schemaV1RecordsSurviveMigrationAndAreNotEvents() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-opt-\(UUID().uuidString)/optimizer.sqlite").path
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        do {   // a v1 database as the previous build wrote it
            let db = try SQLiteDatabase(path: path)
            try db.exec("""
            CREATE TABLE optimization_records (id TEXT PRIMARY KEY, project_path TEXT NOT NULL, created_at REAL NOT NULL, source_description TEXT NOT NULL,
              baseline_tokens INTEGER NOT NULL, optimized_tokens INTEGER NOT NULL, measurement_source TEXT NOT NULL,
              actions_summary TEXT NOT NULL, optimizer_cost_tokens INTEGER NOT NULL DEFAULT 0);
            INSERT INTO optimization_records VALUES ('old', '/p', 1, 'manual', 100, 80, 'heuristicEstimate', 'x', 0);
            """)
            db.userVersion = 1
        }
        let store = try OptimizationStore(path: path)
        let old = try #require(try await store.records(projectPath: "/p").first)
        #expect(old.id == "old" && old.originalBytes == nil && old.stage == nil)
        #expect(try await store.eventTotals(projectPath: "/p").isEmpty)
        let new = event(.writtenToFile, 10, 5, at: 2)
        try await store.record(new)
        #expect(try await store.records(projectPath: "/p").contains(new))
        #expect(TokenSaverSummary(eventTotals: [:], history: try await store.records(projectPath: "/p"), ledger: nil).latest == new)
    }
}

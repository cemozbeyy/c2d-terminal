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

// MARK: - Token Saver TS-1: Claude transcript ledger

@Suite struct ClaudeTranscriptReaderTests {
    private let project = "/Users/someone/dev/My Project_1.2"

    /// A temp `claudeHome` with the project folder named the way Claude Code names it.
    private func makeHome() throws -> (home: URL, folder: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        let folder = ClaudeTranscriptReader.projectFolder(for: project, claudeHome: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (home, folder)
    }

    private func assistant(id: String, input: Int, output: Int, cacheRead: Int = 0, cacheCreate: Int = 0,
                           version: String = "2.1.303", cwd: String? = nil, ts: String = "2026-10-19T10:00:00.000Z", model: String = "claude-fable-5-1") -> String {
        let c = cwd ?? project
        return #"{"type":"assistant","cwd":"\#(c)","sessionId":"S1","version":"\#(version)","gitBranch":"main","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreate),"service_tier":"standard"}}}"#
    }

    private func write(_ lines: [String], to folder: URL, name: String = "S1.jsonl", trailingNewline: Bool = true) throws {
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func ledger(_ r: TranscriptLedgerResult) -> TranscriptLedger? { if case .available(let l) = r { return l }; return nil }

    @Test func folderNameReplacesEveryNonAlphanumericCharacter() {
        #expect(ClaudeTranscriptReader.projectFolderName(for: "/Users/someone/Desktop/projects/my_app_0532") == "-Users-someone-Desktop-projects-my-app-0532")
        #expect(ClaudeTranscriptReader.projectFolderName(for: "/a/b c.d") == "-a-b-c-d")
    }

    @Test func missingFolderIsUnavailableWithReason() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        guard case .unavailable(let reason) = ClaudeTranscriptReader.read(projectPath: project, claudeHome: home) else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("No Claude Code transcripts"))
    }

    @Test func validSessionSumsUsageAndCountsDuplicateMessageRecordsOnce() throws {
        let (home, folder) = try makeHome()
        try write([
            #"{"type":"user","cwd":"\#(project)","message":{"role":"user","content":"hi"}}"#,
            assistant(id: "m1", input: 10, output: 100, cacheRead: 1000, cacheCreate: 50, ts: "2026-10-19T10:00:00.000Z"),
            assistant(id: "m1", input: 10, output: 100, cacheRead: 1000, cacheCreate: 50, ts: "2026-10-19T10:00:01.000Z"),   // second content block, same message
            #"{"type":"attachment","attachment":{"type":"x"}}"#,
            #"{"type":"api-request-blob","blob":"assistant something that mentions assistant in content"}"#,
            assistant(id: "m2", input: 5, output: 7, ts: "2026-10-19T10:05:00.000Z"),
        ], to: folder)
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.count == 1 && l.unavailable.isEmpty)
        let s = try #require(l.sessions.first)
        #expect(s.messageCount == 2)
        #expect(s.usage == ProviderUsage(inputTokens: 15, outputTokens: 107, cacheReadInputTokens: 1000, cacheCreationInputTokens: 50))
        #expect(s.usage.total == 1172)
        #expect(s.peakContextTokens == 1060 && s.lastContextTokens == 5)   // m1 = 10 + 1000 + 50; newest (m2) = 5
        #expect(s.cliVersion == "2.1.303" && s.models == ["claude-fable-5-1"] && s.gitBranch == "main" && s.id == "S1")
        #expect(l.skippedRecords == 3)   // user + attachment skipped without decoding; the blob line was decoded (mentions "assistant") and skipped as non-assistant
        #expect(l.source == .providerConfirmed && l.formatLabel == "CLI v2.1.303 format (verified)")
    }

    @Test func trailingPartialLineIsInProgressNotMalformed() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2), #"{"type":"assistant","cwd":"x","message":{"id":"m2","usage":{"input_tokens":1"#], to: folder, trailingNewline: false)
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.first?.usage.outputTokens == 2)
        #expect(l.inProgressLines == 1)
    }

    @Test func malformedAssistantLineMakesThatSessionUnavailableOnly() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2), #"{"type":"assistant","message":{"id":"m2" BROKEN"#, assistant(id: "m3", input: 1, output: 2)], to: folder, name: "bad.jsonl")
        try write([assistant(id: "m1", input: 3, output: 4)], to: folder, name: "good.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.count == 1 && l.sessions.first?.usage.outputTokens == 4)
        #expect(l.unavailable.count == 1 && l.unavailable.first?.reason.contains("malformed JSON on line 2") == true)
        #expect(l.total.outputTokens == 4)   // unavailable sessions never leak into totals
    }

    @Test func shapeCheckedVersionsAreAccepted() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2, version: "2.1.305")], to: folder)
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.count == 1 && l.unavailable.isEmpty && l.sessions.first?.formatCheck == .handVerified)
    }

    // TSD-06: an unknown version is counted only when its records pass the shape check, and labelled as such.
    @Test func unknownCLIVersionIsCountedOnlyWhenShapeCheckPasses() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2, version: "9.9.9"), assistant(id: "m1", input: 1, output: 5, version: "9.9.9")], to: folder, name: "ok.jsonl")
        try write([assistant(id: "m1", input: 3, output: 4)], to: folder, name: "pinned.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.unavailable.isEmpty && l.sessions.count == 2)
        #expect(l.sessions.first { $0.cliVersion == "9.9.9" }?.formatCheck == .shapeChecked)
        #expect(l.sessions.first { $0.cliVersion == "9.9.9" }?.usage.outputTokens == 5)
        #expect(l.formatLabel == "CLI v2.1.303 format (verified) · CLI v9.9.9 format (shape-checked, not hand-verified)")
    }

    @Test func shapeCheckFailsClosed() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 5, version: "9.9.9"), assistant(id: "m1", input: 2, output: 5, version: "9.9.9")], to: folder, name: "input.jsonl")
        try write([assistant(id: "m1", input: 1, output: 5), assistant(id: "m1", input: 1, output: 4)], to: folder, name: "shrink.jsonl")
        for (name, value) in [("bool", "true"), ("fraction", "1.5"), ("negative", "-3")] {
            try write([#"{"type":"assistant","cwd":"\#(project)","version":"9.9.9","message":{"id":"m1","usage":{"input_tokens":\#(value),"output_tokens":1}}}"#], to: folder, name: "\(name).jsonl")
        }
        try write([#"{"type":"assistant","cwd":"\#(project)","message":{"id":"m1","usage":{"input_tokens":1,"output_tokens":1}}}"#], to: folder, name: "noversion.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.isEmpty && l.unavailable.count == 6)
        #expect(l.unavailable.filter { $0.reason.contains("disagree") }.count == 2)
        #expect(l.unavailable.filter { $0.reason.contains("unrecognised usage shape") }.count == 3)
        #expect(l.unavailable.contains { $0.reason.contains("no CLI version") })
    }

    @Test func unrecognisedUsageShapeAndForeignCwdAreUnavailable() throws {
        let (home, folder) = try makeHome()
        try write([#"{"type":"assistant","cwd":"\#(project)","version":"2.1.303","message":{"id":"m1","usage":{"input_tokens":"ten","output_tokens":1}}}"#], to: folder, name: "shape.jsonl")
        try write([assistant(id: "m1", input: 1, output: 2, cwd: "/somewhere/else")], to: folder, name: "foreign.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.isEmpty && l.unavailable.count == 2)
        #expect(l.unavailable.contains { $0.reason.contains("unrecognised usage shape") })
        #expect(l.unavailable.contains { $0.reason.contains("another directory") })
    }

    // A session that moved into a project subfolder stays the project's (it was dropped before: the popover froze).
    @Test func sessionsInProjectSubfoldersAreCounted() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2), assistant(id: "m2", input: 3, output: 4, cwd: project + "/docs"),
                   assistant(id: "m3", input: 5, output: 6, cwd: project + "/Website/src/")], to: folder, name: "moved.jsonl")
        try write([assistant(id: "m1", input: 7, output: 8, cwd: project + "/docs/../Tools")], to: folder, name: "dotdot.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.unavailable.isEmpty && l.sessions.count == 2)
        #expect(l.total == ProviderUsage(inputTokens: 16, outputTokens: 20))   // provider numbers unchanged, nothing estimated
    }

    // Another project must never be counted: textual prefix siblings, `..` escapes and mixed sessions are refused whole.
    @Test func pathsOutsideTheProjectAreRefused() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 1, cwd: project + "-other")], to: folder, name: "sibling.jsonl")
        try write([assistant(id: "m1", input: 1, output: 1, cwd: project + "/../My Project_1")], to: folder, name: "escape.jsonl")
        try write([assistant(id: "m1", input: 1, output: 1), assistant(id: "m2", input: 1, output: 1, cwd: "/tmp")], to: folder, name: "mixed.jsonl")
        try write([assistant(id: "m1", input: 1, output: 1, cwd: "relative/path")], to: folder, name: "relative.jsonl")
        try write([assistant(id: "m1", input: 1, output: 1, cwd: "/Users/someone/dev")], to: folder, name: "parent.jsonl")
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.isEmpty && l.unavailable.count == 5)
        #expect(l.unavailable.allSatisfy { $0.reason.contains("another directory") })
        #expect(l.total == ProviderUsage())
    }

    @Test func unreadableFolderAndFileAreUnavailableNotGuessed() throws {
        let (home, folder) = try makeHome()
        try write([assistant(id: "m1", input: 1, output: 2)], to: folder, name: "ok.jsonl")
        try write([assistant(id: "m1", input: 9, output: 9)], to: folder, name: "locked.jsonl")
        let locked = folder.appendingPathComponent("locked.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let l = try #require(ledger(ClaudeTranscriptReader.read(projectPath: project, claudeHome: home)))
        #expect(l.sessions.count == 1 && l.total == ProviderUsage(inputTokens: 1, outputTokens: 2))
        #expect(l.unavailable.count == 1 && l.unavailable.first?.reason.contains("could not read") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard case .unavailable(let reason) = ClaudeTranscriptReader.read(projectPath: project, claudeHome: home) else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("could not be listed"))
    }

    @Test func containmentComparesResolvedComponents() throws {
        typealias R = ClaudeTranscriptReader
        #expect(R.isWithin("/a/b", root: "/a/b") && R.isWithin("/a/b/", root: "/a/b") && R.isWithin("/a/b/c/d", root: "/a/b/"))
        #expect(R.isWithin("/a/b/./c", root: "/a/b") && R.isWithin("/a/x/../b/c", root: "/a/b"))
        #expect(!R.isWithin("/a/bc", root: "/a/b") && !R.isWithin("/a/b-c", root: "/a/b") && !R.isWithin("/a", root: "/a/b"))
        #expect(!R.isWithin("/a/b/../c", root: "/a/b") && !R.isWithin("a/b", root: "/a/b") && !R.isWithin("/a/b", root: "a/b"))
        #expect(!R.isWithin("/A/B", root: "/a/b"))   // case is compared as written (Claude Code records the real spelling)
        // Symlinks: a link to the project and the project itself are the same place; a link inside the project that
        // points outside it is outside. Missing paths are compared as written.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("within-\(UUID().uuidString)").resolvingSymlinksInPath()
        let real = base.appendingPathComponent("real"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("alias"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("escape"), withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(R.isWithin(base.appendingPathComponent("alias/sub").path, root: real.path))
        #expect(R.isWithin(real.appendingPathComponent("sub").path, root: base.appendingPathComponent("alias").path))
        #expect(!R.isWithin(real.appendingPathComponent("escape").path, root: real.path))
        #expect(R.isWithin(real.appendingPathComponent("gone/deeper").path, root: real.path))
        #expect(!R.isWithin(base.appendingPathComponent("gone").path, root: real.path))
    }
}

// MARK: - Token Saver TS-2: transcript ↔ C2D launch attribution

@Suite struct SessionAttributionTests {
    private let cwd = "/Users/someone/dev/proj"
    private let idA = "11111111-1111-4111-8111-111111111111"
    private let idB = "22222222-2222-4222-8222-222222222222"
    private let idExt = "33333333-3333-4333-8333-333333333333"

    private func session(_ id: String) -> TranscriptSession {
        TranscriptSession(id: id, fileURL: URL(fileURLWithPath: "/x/\(id).jsonl"), cwd: cwd, cliVersion: "2.1.303", models: ["m"], gitBranch: nil,
                          firstTimestamp: Date(timeIntervalSince1970: 1000), lastTimestamp: Date(timeIntervalSince1970: 2000), messageCount: 1,
                          usage: ProviderUsage(inputTokens: 1, outputTokens: 2))
    }
    private func record(sessionID: String?, taskID: String? = nil, lifecycle: AgentSessionLifecycle = .exited, id: String = UUID().uuidString) -> AgentSessionRecord {
        var r = AgentSessionRecord(id: id, providerID: "claude-code", panelID: nil, projectPath: cwd, workingDirectory: cwd, taskID: taskID, taskSummary: taskID.map { "Task \($0)" })
        r.providerSessionID = sessionID; r.lifecycle = lifecycle
        return r
    }

    @Test func explicitIdLinksToExactlyThatLaunch() {
        let a = SessionAttributor.attribute(sessions: [session(idA)], agentRecords: [record(sessionID: idA, taskID: "T1", id: "R1"), record(sessionID: idB, taskID: "T2", id: "R2")])
        #expect(a[idA] == .linked(agentSessionID: "R1", taskID: "T1", taskSummary: "Task T1", lifecycle: .exited))
    }

    @Test func externalSessionStaysVisibleButUnmatched() {
        let a = SessionAttributor.attribute(sessions: [session(idExt), session(idA)], agentRecords: [record(sessionID: idA)])
        #expect(a[idExt] == .unmatched)
        #expect(a[idA]?.isLinked == true)
        #expect(a.count == 2, "unmatched sessions are kept, never dropped")
    }

    @Test func sameDirectoryAndTimeNeverProduceAGuess() {
        // Two C2D launches in the same cwd and time window but without session ids (pre-TS-2 or codex): no match.
        let a = SessionAttributor.attribute(sessions: [session(idA)], agentRecords: [record(sessionID: nil, taskID: "T1"), record(sessionID: nil, taskID: "T2")])
        #expect(a[idA] == .unmatched)
    }

    @Test func duplicateClaimsAreAmbiguousNotResolved() {
        let a = SessionAttributor.attribute(sessions: [session(idA)], agentRecords: [record(sessionID: idA, id: "R2"), record(sessionID: idA.uppercased(), id: "R1")])
        #expect(a[idA] == .ambiguous(agentSessionIDs: ["R1", "R2"]))
    }

    @Test func noCandidatesIsUnmatchedAndLaunchWithoutTranscriptIsPending() {
        let launched = record(sessionID: idB, taskID: "T9", lifecycle: .running)
        let a = SessionAttributor.attribute(sessions: [session(idA)], agentRecords: [launched])
        #expect(a[idA] == .unmatched)
        #expect(SessionAttributor.launchesWithoutTranscript(sessions: [session(idA)], agentRecords: [launched]).map(\.id) == [launched.id])
        // The transcript appears later: the next (identical) reconciliation links it and clears the pending entry.
        let later = SessionAttributor.attribute(sessions: [session(idA), session(idB)], agentRecords: [launched])
        #expect(later[idB]?.isLinked == true)
        #expect(SessionAttributor.launchesWithoutTranscript(sessions: [session(idA), session(idB)], agentRecords: [launched]).isEmpty)
    }

    @Test func repeatedRescansAreIdempotent() {
        let recs = [record(sessionID: idA, taskID: "T1", id: "R1"), record(sessionID: nil)]
        let first = SessionAttributor.attribute(sessions: [session(idA), session(idExt)], agentRecords: recs)
        let second = SessionAttributor.attribute(sessions: [session(idA), session(idExt)], agentRecords: recs)
        #expect(first == second && first.count == 2)
    }

    @Test func cancelledOrFailedLaunchesNeverAttractForeignTranscripts() {
        let failed = record(sessionID: idB, taskID: "T1", lifecycle: .failed)
        let cancelled = record(sessionID: nil, taskID: "T2", lifecycle: .exited)
        let a = SessionAttributor.attribute(sessions: [session(idA)], agentRecords: [failed, cancelled])
        #expect(a[idA] == .unmatched)
        // A launch that failed *after* producing a transcript is still truthfully linked, flagged with its lifecycle.
        let b = SessionAttributor.attribute(sessions: [session(idB)], agentRecords: [failed])
        if case .linked(_, _, _, let lc)? = b[idB] { #expect(lc == .failed) } else { Issue.record("expected linked") }
    }

    @Test func malformedIdsAreNeverEvidence() {
        let a = SessionAttributor.attribute(sessions: [session(idA), session("not-a-uuid")],
                                            agentRecords: [record(sessionID: ""), record(sessionID: "garbage"), record(sessionID: "not-a-uuid")])
        #expect(a[idA] == .unmatched && a["not-a-uuid"] == .unmatched)
        #expect(SessionAttributor.launchesWithoutTranscript(sessions: [], agentRecords: [record(sessionID: "garbage")]).isEmpty, "a malformed id is not a pending launch either")
    }

    @Test func subAgentTranscriptsInSubfoldersAreNotCountedByTheParentScan() throws {
        let project = "/Users/someone/dev/sub"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-sub-\(UUID().uuidString)")
        let folder = ClaudeTranscriptReader.projectFolder(for: project, claudeHome: home)
        let sub = folder.appendingPathComponent("S1").appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let rec = { (id: String, out: Int) in
            #"{"type":"assistant","cwd":"\#(project)","sessionId":"S1","version":"2.1.303","timestamp":"2026-10-19T10:00:00.000Z","message":{"id":"\#(id)","model":"m","usage":{"input_tokens":1,"output_tokens":\#(out),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        }
        try (rec("m1", 10) + "\n").write(to: folder.appendingPathComponent("S1.jsonl"), atomically: true, encoding: .utf8)
        try (rec("m2", 999) + "\n").write(to: sub.appendingPathComponent("agent-x.jsonl"), atomically: true, encoding: .utf8)
        guard case .available(let l) = ClaudeTranscriptReader.read(projectPath: project, claudeHome: home) else { Issue.record("expected ledger"); return }
        #expect(l.sessions.count == 1 && l.total.outputTokens == 10, "sub-agent usage must not be folded into the parent (overlap unknown)")
    }
}

// MARK: - TSD-02: read-only RTK hook detection

@Suite struct RTKHookDetectorTests {
    private func settings(_ command: String) -> Data {
        Data(#"{"model":"x","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\#(command)"}]}]}}"#.utf8)
    }

    @Test func detectsRTKHookAndIgnoresOthers() {
        #expect(RTKHookDetector.isConfigured(settings: settings("rtk hook claude")))
        #expect(RTKHookDetector.isConfigured(settings: settings("/opt/homebrew/bin/rtk hook claude")))
        #expect(!RTKHookDetector.isConfigured(settings: settings("./scripts/lint.sh")))
        #expect(!RTKHookDetector.isConfigured(settings: settings("artk-check")))
        #expect(!RTKHookDetector.isConfigured(settings: Data(#"{"hooks":{"PostToolUse":[{"hooks":[{"command":"rtk hook claude"}]}]}}"#.utf8)))
        #expect(!RTKHookDetector.isConfigured(settings: Data("{ broken".utf8)))
    }

    @Test func readsFileWithoutChangingIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("rtk-\(UUID().uuidString)")
        #expect(!RTKHookDetector.isConfigured(claudeHome: home))   // no folder, no file
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("settings.json")
        try settings("rtk hook claude").write(to: file)
        let before = try Data(contentsOf: file), stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(RTKHookDetector.isConfigured(claudeHome: home))
        #expect(try Data(contentsOf: file) == before)
        #expect(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
    }
}

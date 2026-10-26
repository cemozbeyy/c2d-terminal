import Foundation
import Testing
@testable import C2DCore

/// `c2d gain` P0 (plan C2D_GAIN_PLAN_2026-10-26): aggregation, store separation, replay classification. Synthetic inputs only.
@Suite struct GainReportTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func event(_ source: GainEvent.Source = .live, project: String = "-p", family: String = "grep", original: Int, result: Int? = nil,
                      skip: GainEvent.SkipReason? = nil, stderr: Int? = nil, at offset: Double = 0) -> GainEvent {
        GainEvent(timestamp: t0.addingTimeInterval(offset), source: source, project: project, family: family,
                  outcome: skip == nil ? .emitted : .skipped, skipReason: skip, originalStdoutBytes: original,
                  resultStdoutBytes: skip == nil ? (result ?? original) : original, stderrBytes: stderr)
    }

    @Test func emptyLiveStoreReportsZero() async throws {
        let store = try OptimizationStore.inMemory()
        let report = GainReport(events: try await store.events(source: .live, project: "-p"), source: .live, project: "-p")
        #expect(report.total.commands == 0 && report.total.transformed == 0 && report.total.savedBytes == 0)
        #expect(report.total.savingsPercent == nil, "no percent without a base")
        let text = report.render()
        #expect(text.contains("Commands            0   transformed 0   skipped 0"))
        #expect(text.contains("Saved               0 B (—)"))
        #expect(text.contains("By command: (none)"))
        #expect(text.contains("delivery to the model is not proven"))
    }

    @Test func percentIsRatioOfSumsNotMeanOfPercents() throws {
        // 50 % and 10 % → mean 30 %, but Σsaved/Σoriginal = 510 / 1100.
        let report = GainReport(events: [Self.event(original: 1000, result: 500), Self.event(family: "ls", original: 100, result: 90)],
                                source: .live, project: nil)
        let p = try #require(report.total.savingsPercent)
        #expect(abs(p - 510.0 / 1100.0 * 100) < 1e-9)
        #expect(report.byFamily.map(\.family) == ["grep", "ls"], "sorted by saved bytes")
    }

    @Test func skipsAreCountedButDoNotDiluteTheRate() throws {
        let transformed = [Self.event(original: 1000, result: 500)]
        let withSkips = transformed + [Self.event(original: 10_000, skip: .rtk), Self.event(family: "cat", original: 5000, skip: .noGain)]
        let a = GainReport(events: transformed, source: .live, project: nil), b = GainReport(events: withSkips, source: .live, project: nil)
        #expect(b.total.commands == 3 && b.total.transformed == 1)
        #expect(b.total.savingsPercent == a.total.savingsPercent)
        #expect(b.total.originalBytes == 1000, "original = transformed commands only")
        #expect(b.stdoutSeenBytes == 16_000, "the share-of-all-stdout line keeps the skipped bytes")
        #expect(b.skips == [.rtk: 1, .noGain: 1])
        #expect(b.render().contains("skipped 2 (rtk 1, no_gain 1)"))
    }

    @Test func stderrIsNeverCountedAsSavings() {
        let report = GainReport(events: [Self.event(original: 1000, result: 400, stderr: 50_000)], source: .live, project: nil)
        #expect(report.total.originalBytes == 1000 && report.total.savedBytes == 600 && report.stdoutSeenBytes == 1000)
    }

    @Test func tokensAreCeilBytesOverFourAndLabelled() {
        #expect([0, 1, 4, 5, 8].map(GainReport.estimatedTokens) == [0, 1, 1, 2, 2])
        let report = GainReport(events: [Self.event(original: 1001, result: 499)], source: .live, project: nil)
        #expect(report.total.estimatedTokensSaved == 251 - 125)
        #expect(report.render().contains("estimated, bytes/4, not provider-reported"))
    }

    @Test func reportNeverMixesSourcesOrProjects() {
        let events = [Self.event(.live, project: "-a", original: 100, result: 50), Self.event(.replay, project: "-a", original: 9000, result: 1000),
                      Self.event(.live, project: "-b", original: 300, result: 100)]
        let live = GainReport(events: events, source: .live, project: nil)
        #expect(live.total.commands == 2 && live.total.savedBytes == 250)
        let replay = GainReport(events: events, source: .replay, project: nil)
        #expect(replay.total.commands == 1 && replay.total.savedBytes == 8000)
        #expect(replay.render().contains("REPLAY (offline, not live)"))
        let projectA = GainReport(events: events, source: .live, project: "-a")
        #expect(projectA.total.commands == 1 && projectA.total.savedBytes == 50)
    }

    @Test func storeKeepsLiveAndReplayApart() async throws {
        let store = try OptimizationStore.inMemory()
        try await store.record(events: [Self.event(.live, original: 100, result: 60, at: 1)])
        try await store.replaceReplayEvents(with: [Self.event(.replay, original: 500, result: 100), Self.event(.live, original: 7, result: 1)])
        #expect(try await store.events(source: .live).count == 1, "a live event slipped into a replay export is dropped, not stored")
        #expect(try await store.events(source: .replay).count == 1)
        // A second export replaces the replay rows only.
        try await store.replaceReplayEvents(with: [Self.event(.replay, original: 50, result: 40), Self.event(.replay, family: "ls", original: 60, skip: .diff)])
        let replay = try await store.events(source: .replay)
        let live = try await store.events(source: .live)
        #expect(replay.count == 2 && replay.allSatisfy { $0.source == .replay })
        #expect(live.count == 1 && live[0].originalStdoutBytes == 100 && live[0].resultStdoutBytes == 60)
        #expect(replay.contains { $0.skipReason == .diff && $0.stderrBytes == nil && $0.helperMilliseconds == nil })
        #expect(try await store.events(source: .live, project: "-other").isEmpty)
        #expect(try await store.events(source: .replay, limit: 1).count == 1)
    }

    @Test func storeMigrationToV3IsIdempotent() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gain-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await OptimizationStore(path: path).record(events: [Self.event(original: 10, result: 5)])
        #expect(try await OptimizationStore(path: path).events(source: .live).count == 1)
    }

    @Test func replayClassifierFollowsTheHookRules() throws {
        func ev(_ command: String, _ out: String, error: Bool = false) -> GainEvent {
            GainEvent.replay(command: command, output: Data(out.utf8), isError: error, project: "-p", sessionID: "s", at: Self.t0)
        }
        let foldable = (1...40).map { "Sources/App/a.swift:\($0):let value = \($0)" }.joined(separator: "\n") + "\n"
        let folded = try #require(OutputCondenser.condenseExact(foldable), "fixture must be foldable")
        let e = ev("grep -rn value Sources", foldable)
        #expect(e.outcome == .emitted && e.source == .replay && e.family == "grep")
        #expect(e.originalStdoutBytes == foldable.utf8.count && e.resultStdoutBytes == folded.utf8.count)
        #expect(e.stderrBytes == nil && e.helperMilliseconds == nil, "replay cannot separate stderr or time the helper")
        #expect(ev("rtk grep value", foldable).skipReason == .rtk)
        #expect(ev("git diff", foldable).skipReason == .diff)
        #expect(ev("cat x", "<persisted-output>\n" + foldable).skipReason == .persisted)
        #expect(ev("grep x", foldable, error: true).skipReason == .failed)
        #expect(ev("true", "").skipReason == .empty)
        #expect(ev("echo hi", "hi\n").skipReason == .noGain)
        #expect(ev("cat big", String(repeating: "a\n", count: TokenSaverHook.maximumBytes)).skipReason == .tooLarge)
        // Skips keep their bytes but carry no savings.
        let skipped = ev("rtk grep value", foldable)
        #expect(skipped.resultStdoutBytes == skipped.originalStdoutBytes && skipped.savedBytes == 0)
    }

    @Test func familyNeverCarriesArgumentsOrPaths() {
        for command in ["grep -rn hunter2 /Users/someone/private", "API_TOKEN=abc /Users/someone/bin/deploy --key=secret", "git status --short"] {
            let e = GainEvent.replay(command: command, output: Data("x\n".utf8), isError: false, project: "-p", sessionID: nil, at: Self.t0)
            #expect(!e.family.contains("/") && !e.family.contains("hunter2") && !e.family.contains("secret") && !e.family.contains("abc"), "\(e.family)")
        }
    }

    @Test func hookSkipRuleIsUnchangedBySplittingOutReasons() {
        for (command, stdout, skipped) in [("rtk ls", "a\n", true), ("ls", "[rtk] filtered\n", true), ("git diff", "x\n", true),
                                           ("ls", "diff --git a/x b/x\n", true), ("cat f", "<persisted-output>\n", true), ("ls", "a\nb\n", false)] {
            #expect(TokenSaverHook.skips(command: command, stdout: stdout) == skipped, "\(command)")
            #expect((TokenSaverHook.skipReason(command: command, stdout: stdout) != nil) == skipped)
        }
    }
}

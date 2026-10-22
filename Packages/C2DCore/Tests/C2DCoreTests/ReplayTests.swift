import Foundation
import Testing
@testable import C2DCore

/// ADR-034 replay benchmark. Synthetic inputs only: real transcripts are read by `Tools/replay`, never by tests.
@Suite struct ReplayTests {
    static func data(_ s: String) -> Data { Data(s.utf8) }

    /// The corpus every transform must survive: the edge cases the runner meets in real output.
    static let corpus: [(String, Data)] = {
        let grepRows = (1...4000).map { "Sources/App/File\($0 / 500).swift:\($0):    let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        return [
            ("empty", Data()),
            ("stderr-style error", data("fatal: not a git repository (or any of the parent directories): .git\n")),
            ("non-UTF-8", Data([0x66, 0x6F, 0xFF, 0xFE, 0x0A, 0x80, 0x0A])),
            ("CRLF", data((1...20).map { "src/a.swift:\($0):x" }.joined(separator: "\r\n") + "\r\n")),
            ("CR progress redraw", data("Fetching 10%\rFetching 50%\rFetching 100%\ndone\n")),
            ("trailing whitespace", data("a.txt:1:let x = 1   \na.txt:2:let y = 2\t\na.txt:3:let z = 3  \n\n\n\nend\n")),
            ("diff", data("diff --git a/x b/x\n@@ -1 +1 @@\n-old  \n+new  \n")),
            ("compiler errors", data((1...4).map { "Sources/Lib.swift:\($0):5: error: cannot find 'x\($0)' in scope" }.joined(separator: "\n") + "\n")),
            ("repeated lines", data(String(repeating: "warning: deprecated API\n", count: 12) + "Build complete!\n")),
            ("ANSI colours", data("\u{1B}[31merror\u{1B}[0m: a.swift:1:1: boom\n\u{1B}]8;;https://x\u{07}link\u{1B}]8;;\u{07}\n")),
            ("large grep -n", data(grepRows)),
        ]
    }()

    @Test func runnerTransformKeepsTheContractOnTheCorpus() {
        for (name, input) in Self.corpus {
            let o = Replay.check(Replay.runnerLossless, input)
            #expect(o.original == input, "the original is never altered: \(name)")
            let allowed: Set<Replay.Violation> = name == "CR progress redraw" ? [.normalizationDropsText] : []
            #expect(o.violations == allowed, "\(name): \(o.violations)")
        }
        // Pass-through cases, byte for byte.
        for name in ["empty", "stderr-style error", "non-UTF-8", "diff", "compiler errors"] {
            let input = Self.corpus.first { $0.0 == name }!.1
            #expect(Replay.runnerLossless.apply(input) == input, "\(name) unchanged")
        }
        // Folding cases actually fold, so the contract above checked a real inverse.
        for name in ["large grep -n", "repeated lines", "CRLF"] {
            let input = Self.corpus.first { $0.0 == name }!.1
            #expect(Replay.runnerLossless.apply(input).count < input.count, "\(name) condensed")
        }
    }

    @Test func contractCatchesBrokenTransforms() {
        let input = Self.data("Sources/a.swift:1:1: error: boom\nok line\nanother line\n")
        let grows = Replay.Transform(name: "grows", fidelity: .exact, apply: { $0 + Self.data("x") }, restore: { $0.dropLast() })
        #expect(Replay.check(grows, input).violations == [.grew])
        let random = Replay.Transform(name: "random", fidelity: .exact, apply: { Data($0.shuffled()) }, restore: { $0 })
        #expect(Replay.check(random, input).violations.isSuperset(of: [.nondeterministic, .notRestorable]))
        let dropsErrors = Replay.Transform(name: "drops errors", fidelity: .lossy, apply: { d in
            Self.data(String(decoding: d, as: UTF8.self).split(separator: "\n").filter { !$0.contains("error") }.joined(separator: "\n"))
        })
        #expect(Replay.check(dropsErrors, input).violations == [.droppedDiagnostic])
        let badInverse = Replay.Transform(name: "bad inverse", fidelity: .normalized, apply: { $0.dropLast(4) }, restore: { $0 })
        #expect(Replay.check(badInverse, input).violations.contains(.notRestorable))
    }

    /// A synthetic transcript: streamed records, a parallel-free single result, an attachment, a compaction,
    /// a `<synthetic>` record, an error result and metadata records that must be ignored.
    static let transcript: [String] = {
        func json(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) }
        func assistant(_ id: String, _ ctx: Int, _ out: Int, tool: (String, String, String)? = nil, model: String = "m1") -> String {
            var content: [[String: Any]] = [["type": "text", "text": "x"]]
            if let (toolID, name, command) = tool { content.append(["type": "tool_use", "id": toolID, "name": name, "input": ["command": command]]) }
            return json(["type": "assistant", "message": ["id": id, "model": model, "content": content,
                                                         "usage": ["input_tokens": 0, "cache_read_input_tokens": ctx, "cache_creation_input_tokens": 0, "output_tokens": out]]])
        }
        func result(_ toolID: String, _ text: String, error: Bool = false) -> String {
            json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": toolID, "content": text, "is_error": error]]]])
        }
        let big = String(repeating: "Sources/A.swift:1:let a = 1\n", count: 200)
        return [
            json(["type": "ai-title", "aiTitle": "ignored"]),
            assistant("A", 1000, 10, tool: ("t1", "Bash", "cd /x && grep -rn a .")),
            assistant("A", 1000, 50, tool: nil),                       // streamed record of the same call: usage updated
            result("t1", big),
            assistant("B", 3000, 20, tool: ("t2", "Read", "")),
            result("t2", "file text"),
            json(["type": "attachment", "attachment": ["type": "total_tokens_reminder"]]),
            assistant("C", 3500, 5),
            json(["type": "system", "subtype": "compact_boundary"]),
            assistant("S", 0, 0, model: "<synthetic>"),
            assistant("D", 900, 30, tool: ("t3", "Bash", "git status")),
            result("t3", "fatal: not a git repository\n", error: true),
            assistant("E", 1000, 5),
            "not json",
        ]
    }()

    @Test func extractionCountsCallsCarryAndCalibrationPairs() throws {
        let s = Replay.extract(lines: Self.transcript)
        #expect(s.calls == 5 && s.compactions == 1)
        #expect(s.samples.map(\.tool) == ["Bash", "Read", "Bash"])
        let bash = s.samples.filter { $0.tool == "Bash" }
        #expect(bash.map(\.command) == ["cd /x && grep -rn a .", "git status"] && s.samples[1].command.isEmpty, "only Bash keeps its input")
        #expect(bash.map(\.carry) == [2, 1], "t1 is re-read by B and C, then compacted away; t3 by E")
        #expect(bash.map(\.isError) == [false, true])
        // A→B: one text result, nothing else → pair. B→C: an attachment. C→D: a compaction. D→E: one result.
        #expect(s.pairs.count == 2)
        let ab = try #require(s.pairs.first)
        #expect(ab.contextDelta == 2000 && ab.askingOutput == 50 && ab.resultBytes == 200 * 28 && ab.model == "m1")
        #expect(Replay.extract(lines: Self.transcript) == s, "deterministic")
    }

    @Test func metricsKeepBytesTokensAndCarrySeparateAndDeterministic() {
        let samples = Self.corpus.enumerated().map { Replay.Sample(command: "grep", output: $1.1, isError: $1.0 == "stderr-style error", carry: $0) }
        let m = Replay.measure(Replay.runnerLossless, on: samples)
        #expect(m == Replay.measure(Replay.runnerLossless, on: samples.reversed()), "same totals in any order")
        #expect(m.samples == samples.count && m.errorSamples == 1 && m.errorChanged == 0)
        #expect(m.rawBytes == samples.reduce(0) { $0 + $1.output.count } && m.shownBytes < m.rawBytes)
        #expect(m.rawTokens > m.shownTokens && m.carriedRawTokens > m.carriedShownTokens)
        #expect(m.violations == [.normalizationDropsText: 1])
        let carried = samples.reduce(0) { $0 + TokenEstimator.estimate(String(decoding: $1.output, as: UTF8.self)).tokens * $1.carry }
        #expect(m.carriedRawTokens == carried)
    }

    @Test func repeatsCountOnlyIdenticalResultsInTheSameSegment() {
        let big = Self.data(String(repeating: "Sources/A.swift:1:let a = 1\n", count: 100))   // 2 800 bytes
        let small = Self.data("tiny\n")
        var session = Replay.Session()
        session.samples = [
            Replay.Sample(tool: "Read", command: "", output: big, carry: 5, segment: 0),
            Replay.Sample(tool: "Bash", command: "cat a", output: big, carry: 4, segment: 0),      // repeat (any tool)
            Replay.Sample(tool: "Bash", command: "cat b", output: small, carry: 4, segment: 0),
            Replay.Sample(tool: "Bash", command: "cat b", output: small, carry: 3, segment: 0),    // under 1 KB: not counted
            Replay.Sample(tool: "Bash", command: "cat a", output: big + Self.data("x"), carry: 2, segment: 0),   // changed: not a repeat
            Replay.Sample(tool: "Read", command: "", output: big, carry: 1, segment: 1),           // after a compaction: fresh
        ]
        let m = Replay.repeats(in: session)
        let tokens = TokenEstimator.estimate(String(decoding: big, as: UTF8.self)).tokens
        #expect(m.results == 6 && m.repeats == 1 && m.repeatBytes == big.count)
        #expect(m.repeatCarriedTokens == tokens * 4 && m.netCarriedTokens == (tokens - Replay.referenceTokens) * 4)
        #expect(m.byTool == ["Bash": m.netCarriedTokens])
        #expect(Replay.extract(lines: Self.transcript).samples.map(\.segment) == [0, 0, 1], "segments follow compactions")
    }

    @Test func restartModelMatchesTheRecordingBelowThresholdAndBracketsItAbove() {
        // A session growing by 10 k fresh tokens per call from a 50 k base, everything else read from cache.
        let calls = (0..<40).map { i in
            Replay.CallUsage(input: 10, cacheRead: i == 0 ? 0 : 50_000 + (i - 1) * 10_000, cacheCreation: i == 0 ? 50_000 : 10_000, output: 500)
        }
        let recorded = Replay.cost(calls)
        #expect(recorded.context == calls.reduce(0) { $0 + $1.context } && recorded.restarts == 0)
        #expect(Replay.cost(calls, policy: .init(threshold: 10_000_000, handoffTokens: 5_000, reworkShare: 0, extraCalls: 0)) == recorded,
                "a threshold never reached changes nothing")
        let free = Replay.cost(calls, policy: .init(threshold: 150_000, handoffTokens: 5_000, reworkShare: 0, extraCalls: 0))
        #expect(free.restarts > 0 && free.context < recorded.context && free.weighted < recorded.weighted)
        #expect(free.output == recorded.output + free.restarts * 5_000, "hand-off is written by the model")
        let costly = Replay.cost(calls, policy: .init(threshold: 200_000, handoffTokens: 5_000, reworkShare: 0.6, extraCalls: 40))
        #expect(costly.restarts > 0 && costly.weighted > recorded.weighted, "heavy re-work plus extra calls costs more than it saves")
        #expect(Replay.cost(calls, policy: .init(threshold: 60_000, handoffTokens: 20_000, reworkShare: 1, extraCalls: 20)) == recorded,
                "no restart when the carried context cannot get under the threshold")
        let p = Replay.RestartPolicy(threshold: 150_000, handoffTokens: 5_000, reworkShare: 0, extraCalls: 5)
        let even = Replay.breakEvenRework([calls], policy: p)
        #expect(even != nil && even! > 0)
        if let even, even < 1 {
            var at = p; at.reworkShare = min(1, even + 0.05)
            #expect(Replay.cost(calls, policy: at).weighted >= recorded.weighted)
        }
        #expect(Replay.breakEvenRework([calls], policy: .init(threshold: 60_000, handoffTokens: 200_000, reworkShare: 0, extraCalls: 50)) == nil)
        // A recorded compaction (context drops back near the base) after a simulated restart: never negative.
        let compacted = calls.prefix(30) + [Replay.CallUsage(input: 10, cacheRead: 40_000, cacheCreation: 20_000, output: 500)] + calls.prefix(20).dropFirst()
        let sim = Replay.cost(Array(compacted), policy: .init(threshold: 150_000, handoffTokens: 5_000, reworkShare: 0, extraCalls: 0))
        let rec = Replay.cost(Array(compacted))
        #expect(sim.cacheRead >= 0 && sim.cacheWrite >= 0 && sim.weighted > 0 && sim.weighted < rec.weighted && sim.context <= rec.context)
        // Compaction contexts come from the calls around each boundary.
        let s = Replay.extract(lines: Self.transcript)
        #expect(s.compactionContexts == [Replay.CompactionContext(before: 3500, after: 900)])
        #expect(s.usage.map(\.output) == [50, 20, 5, 30, 5], "last record per message id; <synthetic> is not a call")
    }

    @Test func calibrationBoundsAndLabels() {
        let pairs = [Replay.CalibrationPair(model: "m", resultBytes: 8000, heuristicTokens: 2400, contextDelta: 2000, askingOutput: 400),
                     Replay.CalibrationPair(model: "m", resultBytes: 100, heuristicTokens: 30, contextDelta: 10, askingOutput: 0),   // under 4 KB: ignored
                     Replay.CalibrationPair(model: "n", resultBytes: 5000, heuristicTokens: 1000, contextDelta: 1000, askingOutput: 2000)]
        let c = Replay.calibrate(pairs)
        #expect(c.map(\.model) == ["m", "n"] && c[0].pairs == 1)
        #expect(c[0].bytesPerTokenAtLeast == 4 && c[0].bytesPerTokenAdjusted == 5 && c[0].heuristicOverGrowth == 1.2)
        #expect(c[1].bytesPerTokenAdjusted == nil, "no adjustment when the asking turn outweighs the growth")
    }

    @Test func familyLabelsNeverCarryPathsOrArguments() {
        #expect(Replay.family(of: "cd /Users/me/x && git status 2>&1") == "git status")
        #expect(Replay.family(of: "S=/private/tmp/secret python3 - <<'EOF'") == "python3")
        #expect(Replay.family(of: "/usr/bin/grep -rn token .") == "grep")
        #expect(Replay.family(of: "git /odd/path") == "git")
        #expect(Replay.family(of: "\"$HOME/bin/x\" run") == "other")
        #expect(Replay.unwrapped("cd a && cd b && rg -n x . 2>/dev/null | head -20") == "rg -n x .")
    }
}

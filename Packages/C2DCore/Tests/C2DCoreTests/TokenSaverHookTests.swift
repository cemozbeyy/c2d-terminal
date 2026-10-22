import Foundation
import Testing
@testable import C2DCore

/// ADR-035: the exact fold and the PostToolUse adapter. Synthetic inputs only.
@Suite struct TokenSaverHookTests {
    /// Deterministic generator, so a failing case can be reproduced from its seed.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Byte-for-byte: whenever the fold is used, expanding it gives the input back exactly, and it is smaller.
    static func expectExact(_ input: String, _ label: String) {
        guard let folded = OutputCondenser.condenseExact(input) else { return }
        #expect(OutputCondenser.expandExact(folded) == input, "\(label) round-trips")
        #expect(folded.utf8.count < input.utf8.count && folded.hasPrefix(OutputCondenser.exactHeader + "\n"), "\(label) smaller, marked")
    }

    @Test func exactFoldRoundTripsTheCorpusByteForByte() throws {
        for (name, data) in ReplayTests.corpus {
            guard let text = String(data: data, encoding: .utf8) else { continue }
            Self.expectExact(text, name)
        }
        // Unlike the runner, nothing is normalized: CRLF, trailing spaces, blank runs and escapes survive.
        let crlf = (1...20).map { "src/a.swift:\($0):x  \r" }.joined(separator: "\n") + "\n\n\n"
        let folded = try #require(OutputCondenser.condenseExact(crlf))
        #expect(folded.contains("x  \r\n") && OutputCondenser.expandExact(folded) == crlf)
        #expect(OutputCondenser.condenseExact("Fetching 10%\rFetching 100%\ndone\n") == nil, "nothing to fold: unchanged")
        #expect(OutputCondenser.condenseExact("") == nil)
    }

    @Test func exactFoldDeclinesOrRoundTripsAdversarialLines() {
        let block = (1...6).map { "Sources/a.swift:\($0):let v = \($0)" }
        let traps: [String] = [
            OutputCondenser.exactHeader + "\n" + block.joined(separator: "\n"),                     // literal header first
            (block + ["[c2d: previous line repeated 3 more times]"]).joined(separator: "\n"),        // literal marker
            (block + ["Sources:", "  12 items", "  13 more"]).joined(separator: "\n"),               // looks like a group
            (["a.swift:"] + (1...5).map { "  \($0):x" } + block).joined(separator: "\n"),            // pre-grouped text
            (block + Array(repeating: "", count: 5) + Array(repeating: "same", count: 9)).joined(separator: "\n"),
            (block + ["Sources/a.swift:7:" + String(repeating: "é", count: 50), "Sources/a.swift:8:\u{1B}[31mred"]).joined(separator: "\n"),
        ]
        for (i, t) in traps.enumerated() { Self.expectExact(t, "trap \(i)") }
    }

    @Test func exactFoldPropertyHoldsOnRandomOutputs() {
        var rng = SplitMix64(state: 0xC2D)
        let pieces = ["Sources/a.swift:1:x", "Sources/a.swift:2:y", "b.ts:10:error: boom", "b.ts:10-ctx", "same", "same", "", "  3:z",
                      "a.swift:", "[c2d: previous line repeated 2 more times]", OutputCondenser.exactHeader, "x\r", "tab\there  ", "naïve"]
        for seed in 0..<400 {
            let count = Int.random(in: 0...60, using: &rng)
            let text = (0..<count).map { _ in pieces.randomElement(using: &rng)! }.joined(separator: "\n") + (Bool.random(using: &rng) ? "\n" : "")
            Self.expectExact(text, "seed \(seed)")
        }
    }

    // MARK: Adapter

    static func payload(_ command: String, stdout: String, extra: [String: Any] = [:], tool: String = "Bash") -> Data {
        var response: [String: Any] = ["stdout": stdout, "stderr": "warn: x\n", "interrupted": false, "isImage": false,
                                       "returnCodeInterpretation": "No matches", "bashEditDiff": ["changedFiles": []]]
        response.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PostToolUse", "tool_name": tool,
                                                            "tool_input": ["command": command], "tool_response": response])
    }
    static let grep = (1...30).map { "Sources/App/Big.swift:\($0):    let value\($0) = compute()" }.joined(separator: "\n") + "\n"

    @Test func adapterReplacesOnlyStdoutAndKeepsEveryOtherField() throws {
        let data = try #require(TokenSaverHook.postToolUseResponse(payload: Self.payload("cd x && grep -rn value .", stdout: Self.grep)))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let out = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(out["hookEventName"] as? String == "PostToolUse" && out.count == 2, "no permission decision, no other key")
        let r = try #require(out["updatedToolOutput"] as? [String: Any])
        #expect(OutputCondenser.expandExact(try #require(r["stdout"] as? String)) == Self.grep)
        #expect(r["stderr"] as? String == "warn: x\n" && r["interrupted"] as? Bool == false && r["isImage"] as? Bool == false)
        #expect(r["returnCodeInterpretation"] as? String == "No matches" && r["bashEditDiff"] != nil)
    }

    @Test func adapterLeavesEverythingElseAlone() {
        func none(_ d: Data, _ why: String) { #expect(TokenSaverHook.postToolUseResponse(payload: d) == nil, "\(why)") }
        let g = Self.grep
        none(Data("not json".utf8), "malformed JSON")
        none(Data("[]".utf8), "not an object")
        none(Data("{}".utf8), "empty object")
        none(try! JSONSerialization.data(withJSONObject: ["tool_name": "Bash", "tool_input": ["command": "ls"]]), "no tool_response")
        none(try! JSONSerialization.data(withJSONObject: ["tool_name": "Bash", "tool_input": ["command": 3], "tool_response": ["stdout": g]]), "command not a string")
        none(Self.payload("grep -rn x", stdout: g, extra: ["stdout": 42]), "stdout not a string")
        none(Self.payload("cat a", stdout: g, tool: "Read"), "not Bash")
        none(Self.payload("grep -rn x", stdout: g, extra: ["interrupted": true]), "interrupted")
        none(Self.payload("grep -rn x", stdout: g, extra: ["isImage": true]), "image")
        none(Self.payload("grep -rn x", stdout: ""), "empty stdout")
        none(Self.payload("grep -rn x", stdout: "short\n"), "nothing to fold")
        none(Self.payload("rtk grep -rn x .", stdout: g), "RTK owns this output")
        none(Self.payload("cd a && rtk git status", stdout: g), "RTK after cd")
        none(Self.payload("grep -rn x", stdout: g + "[full output: rtk recall abc]\n"), "RTK hint in output")
        none(Self.payload("git diff", stdout: g), "diff command")
        none(Self.payload("git log -p", stdout: "diff --git a/x b/x\n" + g), "diff-shaped output")
        none(Self.payload("grep -rn x", stdout: g + "@@ -1 +1 @@\n"), "hunk header")
        none(Self.payload("grep -rn x", stdout: "<persisted-output>\n" + g), "already persisted")
        none(Self.payload("grep -rn x", stdout: String(repeating: g, count: (TokenSaverHook.maximumBytes / g.utf8.count) + 1)), "over the size bound")
        var other = try! JSONSerialization.jsonObject(with: Self.payload("grep -rn x", stdout: g)) as! [String: Any]
        other["hook_event_name"] = "PostToolUseFailure"
        none(try! JSONSerialization.data(withJSONObject: other), "failure event: output cannot be replaced there")
    }

    @Test func exactFoldPassesTheReplayContract() {
        for (name, data) in ReplayTests.corpus {
            #expect(Replay.check(Replay.exactFold, data).violations.isEmpty, "\(name)")
        }
        let big = ReplayTests.corpus.first { $0.0 == "large grep -n" }!.1
        #expect(Replay.exactFold.apply(big).count < big.count)
    }
}

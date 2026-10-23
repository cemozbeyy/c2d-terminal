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

    /// Boundary and encoding cases: each either leaves the result alone (nil) or round-trips byte for byte with
    /// every other field untouched. Nothing in between.
    static let edgeCases: [(String, String)] = {
        let bound = TokenSaverHook.maximumBytes
        let rows = String(repeating: "a.swift:1:x\n", count: bound / 12)
        var c: [(String, String)] = []
        c.append(("whitespace only", String(repeating: " \t\n", count: 300)))
        c.append(("blank lines", String(repeating: "\n", count: 500)))
        c.append(("unicode rows", (1...30).map { "src/naïve_日本語_🇹🇷.swift:\($0):let é = \"e\u{301}\" // ‮rtl" }.joined(separator: "\n") + "\n"))
        c.append(("combining marks repeated", String(repeating: "a\u{301}\u{302}\u{303}\n", count: 40)))
        c.append(("one 200 KB line", String(repeating: "x", count: 200_000) + "\n"))
        c.append(("long rows", (1...20).map { "a.swift:\($0):" + String(repeating: "y", count: 20_000) }.joined(separator: "\n") + "\n"))
        c.append(("CRLF rows", (1...30).map { "a.swift:\($0):x\r" }.joined(separator: "\n") + "\r\n"))
        c.append(("lone CR", String(repeating: "same\r", count: 20)))
        c.append(("header collision inside", grep + OutputCondenser.exactHeader + "\n" + grep))
        c.append(("marker collision", grep + "[c2d: previous line repeated 99 more times]\n" + grep))
        c.append(("group collision", "src:\n  1:a\n  2:b\n  3:c\n" + grep))
        c.append(("exit code text", grep + "exit status 2\nerror: boom\n" + grep))
        c.append(("null bytes", (1...30).map { "a.swift:\($0):\u{0}x\u{0}" }.joined(separator: "\n") + "\n"))
        c.append(("exactly the size bound", rows.padding(toLength: bound, withPad: "z", startingAt: 0)))
        c.append(("one byte over the bound", rows.padding(toLength: bound + 1, withPad: "z", startingAt: 0)))
        return c
    }()

    @Test(arguments: edgeCases) func edgeCasesEitherPassThroughOrRoundTrip(_ c: (String, String)) throws {
        let (name, stdout) = c
        let extra: [String: Any] = ["exitCode": 2, "returnCodeInterpretation": "exit 2", "stderr": "grep: warning\n"]
        guard let data = TokenSaverHook.postToolUseResponse(payload: Self.payload("grep -rn x .", stdout: stdout, extra: extra)) else {
            if stdout.utf8.count <= TokenSaverHook.maximumBytes { #expect(OutputCondenser.condenseExact(stdout) == nil, "\(name): declined only when there is nothing exact to fold") }
            return
        }
        #expect(stdout.utf8.count <= TokenSaverHook.maximumBytes, "\(name): over the bound is never touched")
        let r = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
        let out = try #require(r["updatedToolOutput"] as? [String: Any])
        let folded = try #require(out["stdout"] as? String)
        #expect(OutputCondenser.expandExact(folded) == stdout && folded.utf8.count < stdout.utf8.count, "\(name): byte-exact and smaller")
        #expect(out["exitCode"] as? Int == 2 && out["returnCodeInterpretation"] as? String == "exit 2" && out["stderr"] as? String == "grep: warning\n",
                "\(name): exit status and stderr untouched")
    }

    /// Opt-in lossy variants (helper `--lossy`): same skip rules, same two response keys, an explicit marker that
    /// names the omitted range, diagnostics kept; the exact fold declines the same plain file body.
    @Test func lossyVariantsAreMarkedKeepDiagnosticsAndShareTheSkipRules() throws {
        var body = (1...400).map { "    let field\($0) = compute(\($0))" }
        body[249] = "    let secret = compute(7331)"; body[214] = "Sources/long.swift:215:9: error: boom"   // 250 is inside the omitted 217–320
        let stdout = body.joined(separator: "\n") + "\n"
        #expect(TokenSaverHook.postToolUseResponse(payload: Self.payload("cat src/long.swift", stdout: stdout)) == nil, "exact fold: nothing to fold")
        let data = try #require(TokenSaverHook.postToolUseResponse(payload: Self.payload("cat src/long.swift", stdout: stdout), lossy: .truncate))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let out = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(Set(out.keys) == ["hookEventName", "updatedToolOutput"])
        let r = try #require(out["updatedToolOutput"] as? [String: Any])
        let text = try #require(r["stdout"] as? String)
        #expect(text.hasPrefix("[c2d: condensed 400→") && text.utf8.count < stdout.utf8.count)
        #expect(text.contains("[c2d: 173 lines omitted: 41–213 of this output]") && text.contains("[c2d: 104 lines omitted: 217–320 of this output]"))
        #expect(text.contains("Sources/long.swift:215:9: error: boom") && !text.contains("secret = compute(7331)"), "diagnostic kept, plain middle line gone")
        #expect(text.hasSuffix("    let field400 = compute(400)\n"))
        #expect(r["stderr"] as? String == "warn: x\n" && r["returnCodeInterpretation"] as? String == "No matches")
        for v in TokenSaverHook.LossyVariant.allCases {
            #expect(TokenSaverHook.postToolUseResponse(payload: Self.payload("rtk cat src/long.swift", stdout: stdout), lossy: v) == nil, "\(v): RTK-owned")
            #expect(TokenSaverHook.postToolUseResponse(payload: Self.payload("git diff", stdout: stdout), lossy: v) == nil, "\(v): diff command")
            #expect(TokenSaverHook.postToolUseResponse(payload: Self.payload("cat x", stdout: stdout, extra: ["interrupted": true]), lossy: v) == nil, "\(v): interrupted")
        }
        // Similar-line folding on this body: either nothing to fold (nil) or a marked, smaller result — never an unmarked change.
        if let d = TokenSaverHook.postToolUseResponse(payload: Self.payload("cat src/long.swift", stdout: stdout), lossy: .similar) {
            let t = String(decoding: d, as: UTF8.self)
            #expect(t.contains("[c2d: condensed") && t.contains("similar lines omitted"))
        }
    }

    /// The response can only ever carry a replacement output: no permission decision, no input rewrite, no
    /// continue/stop control. Execution and permissions are decided before this hook runs and it cannot reach them.
    @Test func responseCarriesNoPermissionOrExecutionSemantics() throws {
        let data = try #require(TokenSaverHook.postToolUseResponse(payload: Self.payload("grep -rn x .", stdout: Self.grep)))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["hookSpecificOutput"])
        let out = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(Set(out.keys) == ["hookEventName", "updatedToolOutput"])
        let forbidden = ["decision", "permissionDecision", "permissionDecisionReason", "continue", "stopReason", "suppressOutput", "updatedInput",
                         "additionalContext", "systemMessage", "reason"]
        let text = String(decoding: data, as: UTF8.self)
        for key in forbidden { #expect(!text.contains("\"\(key)\""), "never emits \(key)") }
        #expect(!text.contains("\"command\""), "the command is never echoed back")
    }

    @Test func exactFoldPassesTheReplayContract() {
        for (name, data) in ReplayTests.corpus {
            #expect(Replay.check(Replay.exactFold, data).violations.isEmpty, "\(name)")
        }
        let big = ReplayTests.corpus.first { $0.0 == "large grep -n" }!.1
        #expect(Replay.exactFold.apply(big).count < big.count)
    }
}

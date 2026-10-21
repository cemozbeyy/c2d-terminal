import Foundation
import Testing
@testable import C2DCore

@Suite(.serialized) struct TokenSaverEngineTests {
    @Test func onlySimpleReadOnlyCommandsAreEligible() {
        for ok in ["git status", "git log --oneline -20", "ls -la", "grep -rn foo src", "rg -n 'a b' .", "find . -name '*.swift'", "tree -L 2"] {
            #expect(TokenSaverEngine.isEligible(ok), "\(ok)")
        }
        for no in ["git diff", "git show HEAD", "git log -p", "git log --patch", "git log -pS x", "git -C x status", "git push",
                   "ls | wc -l", "ls && rm x", "grep x > out", "echo $(ls)", "find . -delete", "find . -exec rm {} +",
                   "rg --pre cat x", "tree -o out", "rtk git status", "FOO=1 ls", "rm -rf x", "cd x", "ls\nrm x", ""] {
            #expect(!TokenSaverEngine.isEligible(no), "\(no)")
        }
    }

    @Test func hookRewritesEligibleBashCallsAndQuotesThroughAShell() throws {
        func respond(_ command: String, tool: String = "Bash") -> [String: Any]? {
            let payload = try! JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": ["command": command, "description": "d"]])
            return TokenSaverEngine.hookResponse(payload: payload, runner: "/bin/echo").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        #expect(respond("ls | head") == nil)
        #expect(respond("ls", tool: "Read") == nil)
        #expect(TokenSaverEngine.hookResponse(payload: Data("not json".utf8), runner: "/bin/echo") == nil)
        let out = try #require(respond("grep -n \"it's\" a.txt")?["hookSpecificOutput"] as? [String: Any])
        #expect(out["hookEventName"] as? String == "PreToolUse" && out["permissionDecision"] == nil)
        let input = try #require(out["updatedInput"] as? [String: Any])
        #expect(input["description"] as? String == "d", "other tool_input fields are kept")
        // Through a real shell the runner receives the flag and the original command as one argument.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", try #require(input["command"] as? String)]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "--c2d-token-run grep -n \"it's\" a.txt\n")
    }

    @Test func runCondensesLosslesslyKeepsExitStatusAndRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.swift")
        try (1...40).map { "let value\($0) = needle\($0)" }.joined(separator: "\n").write(to: src, atomically: true, encoding: .utf8)
        let ledger = dir.appendingPathComponent("engine.tsv")
        let outURL = dir.appendingPathComponent("out")

        func run(_ command: String) throws -> (Int32, String) {
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            let h = try FileHandle(forWritingTo: outURL)
            let status = TokenSaverEngine.run(command: command, ledger: ledger, out: h)
            try h.close()
            return (status, try String(contentsOf: outURL, encoding: .utf8))
        }
        let (ok, text) = try run("grep -Hn needle '\(src.path)'")
        #expect(ok == 0)
        #expect(text.contains("[c2d: condensed"), "grep -n rows grouped by file")
        #expect(OutputCondenser.expandGroups(String(text.dropLast())).dropFirst() == ((1...40).map { "\(src.path):\($0):let value\($0) = needle\($0)" })[...], "nothing lost")

        let (miss, empty) = try run("grep -Hn nothing-here '\(src.path)'")
        #expect(miss == 1 && empty.isEmpty, "grep's no-match status passes through")
        #expect(try run("rm -rf '\(dir.path)'").0 == 126 && FileManager.default.fileExists(atPath: src.path), "runner refuses non-allowlisted commands")

        // A flag list cannot catch every diff-producing option; diff-shaped output is passed through untouched.
        let diffLike = (1...5).map { "diff --git a/f\($0) b/f\($0)\n@@ -1 +1 @@\n-x\n+x\n+x\n+x\n+x" }.joined(separator: "\n") + "\n"
        try diffLike.write(to: dir.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        #expect(try run("grep -h '' '\(dir.path)/d.txt'").1 == diffLike)

        let t = TokenSaverEngine.totals(ledger: ledger)
        #expect(t.commands == 3 && t.rawBytes > t.shownBytes && t.savedTokens > 0)
        try "junk\n1\t2\n".write(to: ledger, atomically: true, encoding: .utf8)
        #expect(TokenSaverEngine.totals(ledger: ledger).commands == 0, "malformed rows are skipped")
    }

    @Test func launchSettingsCarryTheEngineHookOnlyWhenGiven() throws {
        func obj(_ s: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
        let plain = try obj(AgentActivity.hookSettings(stateFile: "/s"))
        #expect(plain["permissions"] == nil && (plain["hooks"] as? [String: Any])?["PreToolUse"] == nil)
        let with = try obj(AgentActivity.hookSettings(stateFile: "/s", tokenRunner: "/A B/C2D Terminal"))
        let pre = try #require(((with["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first)
        #expect(pre["matcher"] as? String == "Bash")
        #expect((pre["hooks"] as? [[String: Any]])?.first?["command"] as? String == "'/A B/C2D Terminal' --c2d-token-hook")
        #expect((with["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash('/A B/C2D Terminal' --c2d-token-run:*)"])
    }
}

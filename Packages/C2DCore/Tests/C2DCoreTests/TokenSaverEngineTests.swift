import CryptoKit
import Foundation
import Testing
@testable import C2DCore

/// Plan C2D_GAIN P1–P3: hook ledger events, the fold launch gate (fail-closed with RTK), RTK's history read
/// read-only, and the unified report. Synthetic files only; RTK itself is never run.
@Suite struct TokenSaverEngineTests {
    static func temp(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-ts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func payload(command: String, stdout: String, stderr: String = "warn\n", interrupted: Bool = false, cwd: String = "/tmp/proj") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "s-1", "tool_use_id": "toolu_1", "cwd": cwd,
            "tool_input": ["command": command],
            "tool_response": ["stdout": stdout, "stderr": stderr, "interrupted": interrupted, "isImage": false, "returnCodeInterpretation": "exit 0"],
        ])
    }

    static let foldable = (1...40).map { "Sources/App/a.swift:\($0):let value = \($0)" }.joined(separator: "\n") + "\n"

    // MARK: P1 — ledger events from the hook

    @Test func evaluateReturnsTheSameResponseAndAMatchingEvent() throws {
        let p = Self.payload(command: "grep -rn value Sources", stdout: Self.foldable)
        let (response, event) = TokenSaverHook.evaluate(payload: p, project: "-proj")
        #expect(response == TokenSaverHook.postToolUseResponse(payload: p), "the response is unchanged by recording")
        let e = try #require(event)
        #expect(e.source == .live && e.outcome == .emitted && e.family == "grep" && e.project == "-proj" && e.mode == "exact")
        #expect(e.sessionID == "s-1" && e.toolUseID == "toolu_1" && e.stderrBytes == 5 && e.originalStdoutBytes == Self.foldable.utf8.count)
        let body = try #require(response)
        let out = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let updated = try #require((out["hookSpecificOutput"] as? [String: Any])?["updatedToolOutput"] as? [String: Any])
        #expect(updated["stderr"] as? String == "warn\n" && updated["returnCodeInterpretation"] as? String == "exit 0", "stderr and exit info untouched")
        #expect((updated["stdout"] as? String)?.utf8.count == e.resultStdoutBytes && OutputCondenser.expandExact(updated["stdout"] as! String) == Self.foldable)
    }

    @Test func evaluateRecordsSkipsWithReasonsAndNoResponse() {
        func skip(_ p: Data) -> GainEvent.SkipReason? {
            let r = TokenSaverHook.evaluate(payload: p, project: "-p")
            #expect(r.response == nil)
            return r.event?.skipReason
        }
        #expect(skip(Self.payload(command: "rtk grep value", stdout: Self.foldable)) == .rtk)
        #expect(skip(Self.payload(command: "grep value", stdout: "[rtk] 40 matches\n" + Self.foldable)) == .rtk)
        #expect(skip(Self.payload(command: "git diff", stdout: Self.foldable)) == .diff)
        #expect(skip(Self.payload(command: "cat log", stdout: "<persisted-output>\n" + Self.foldable)) == .persisted)
        // Over ~30 KB the CLI gives the hook a prefix plus persistedOutputPath and ignores any replacement.
        let persisted = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": ["command": "sh gen.sh"],
            "tool_response": ["stdout": Self.foldable, "stderr": "", "persistedOutputPath": "/tmp/x.txt", "persistedOutputSize": 212679]])
        #expect(skip(persisted) == .persisted)
        #expect(skip(Self.payload(command: "make", stdout: Self.foldable, interrupted: true)) == .interrupted)
        #expect(skip(Self.payload(command: "true", stdout: "")) == .empty)
        #expect(skip(Self.payload(command: "echo hi", stdout: "hi\n")) == .noGain)
        #expect(skip(Self.payload(command: "cat big", stdout: String(repeating: "a\n", count: TokenSaverHook.maximumBytes))) == .tooLarge)
        // Not a Bash PostToolUse with text stdout: no response and no event.
        let notBash = try! JSONSerialization.data(withJSONObject: ["hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": [:], "tool_response": [:]])
        #expect(TokenSaverHook.evaluate(payload: notBash).event == nil)
        #expect(TokenSaverHook.evaluate(payload: Data("not json".utf8)).event == nil)
    }

    @Test func evaluateKeysTheProjectByCwdWhenNoneIsGiven() {
        let e = TokenSaverHook.evaluate(payload: Self.payload(command: "ls", stdout: "a\n", cwd: "/Users/x/my proj")).event
        #expect(e?.project == ClaudeTranscriptReader.projectFolderName(for: "/Users/x/my proj"))
    }

    // MARK: P2 — launch gate

    @Test func foldHookIsAddedOnlyWhenEveryGateIsOpen() throws {
        let helper = "/bin/ls"   // any executable file stands in for the helper
        func decide(debug: Bool = true, on: Bool = true, fold: Bool = true, rtk: Bool? = false, helperPath: String? = helper) -> TokenSaverLaunchHook.Decision {
            TokenSaverLaunchHook.decide(isDebugBuild: debug, tokenSaverOn: on, foldOn: fold, rtkHookConfigured: rtk,
                                        helperPath: helperPath, ledgerPath: "/tmp/l.sqlite", projectPath: "/tmp/p")
        }
        #expect(decide(debug: false).hook == nil, "Release never")
        #expect(decide(on: false).hook == nil)
        #expect(decide(fold: false).hook == nil, "off by default")
        #expect(decide(rtk: true).hook != nil, "RTK configured: fold runs beside it, skipping RTK-owned output")
        #expect(decide(rtk: nil).hook == nil, "RTK unknown: fail-closed")
        #expect(decide(helperPath: nil).hook == nil && decide(helperPath: "/no/such/helper").hook == nil)
        let hook = try #require(decide().hook)
        #expect(hook.command == "'/bin/ls' --ledger '/tmp/l.sqlite' --project '\(ClaudeTranscriptReader.projectFolderName(for: "/tmp/p"))'")
    }

    @Test func settingsWithTheFoldHookAddOnlyOneBashPostToolUseGroup() throws {
        let hook = TokenSaverLaunchHook(helperPath: "/A pp/c2d-token-helper", ledgerPath: "/tmp/it's.sqlite", projectFolder: "-p")
        let plain = AgentActivity.hookSettings(stateFile: "/tmp/s")
        #expect(plain == AgentActivity.hookSettings(stateFile: "/tmp/s", tokenSaverHook: nil), "no hook: byte-identical settings")
        let with = try #require(try JSONSerialization.jsonObject(with: Data(AgentActivity.hookSettings(stateFile: "/tmp/s", tokenSaverHook: hook).utf8)) as? [String: Any])
        let base = try #require(try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any])
        #expect(Set(with.keys) == ["hooks"], "no permissions block")
        let hooks = try #require(with["hooks"] as? [String: Any]), baseHooks = try #require(base["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(baseHooks.keys) && hooks["PreToolUse"] == nil, "no new events, never PreToolUse")
        let post = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(post.count == 2 && post[1]["matcher"] as? String == "Bash")
        #expect((post[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String == #"'/A pp/c2d-token-helper' --ledger '/tmp/it'\''s.sqlite' --project '-p'"#)
        #expect(NSDictionary(dictionary: post[0]) == NSDictionary(dictionary: (baseHooks["PostToolUse"] as! [[String: Any]])[0]), "activity hook unchanged")
    }

    @Test func launchPlanCarriesTheFoldHookOnlyWhenGiven() throws {
        let dir = Self.temp("x").deletingLastPathComponent()
        let off = try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: nil)
        let sid = try #require(off.providerSessionID)
        #expect(off.arguments[1] == AgentActivity.hookSettings(stateFile: AgentActivity.stateFile(sessionID: sid).path), "off: the settings C2D always passed")
        #expect(!off.arguments[1].contains("c2d-token-helper") && !off.arguments[1].contains("PreToolUse"))
        let hook = TokenSaverLaunchHook(helperPath: "/App/c2d-token-helper", ledgerPath: "/tmp/l.sqlite", projectFolder: "-p")
        let on = try AgentLaunchPlan.make(provider: .claudeCode, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: nil, tokenSaverHook: hook)
        #expect(on.arguments[1].contains("c2d-token-helper") && !on.arguments[1].contains("PreToolUse") && !on.arguments[1].contains("permissions"))
        #expect(on.arguments.count == off.arguments.count && on.arguments[0] == "--settings" && on.arguments[2] == "--session-id", "only the settings JSON differs")
        let codex = try AgentLaunchPlan.make(provider: .codex, executablePath: "/bin/ls", projectPath: dir.path, workingDirectory: dir.path, task: nil, tokenSaverHook: hook)
        #expect(codex.arguments.isEmpty, "other providers never get the hook")
    }

    @Test func rtkGateIsFailClosedAcrossSettingsFiles() throws {
        let home = Self.temp("home").deletingLastPathComponent().appendingPathComponent("claude")
        let project = home.deletingLastPathComponent().appendingPathComponent("project")
        let managed = home.deletingLastPathComponent().appendingPathComponent("managed.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let rtk = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}"#
        func state() -> Bool? { RTKHookDetector.state(claudeHome: home, projectPath: project.path, managedSettings: managed) }
        #expect(state() == false, "no settings files at all")
        try #"{"hooks":{}}"#.write(to: home.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        #expect(state() == false)
        try rtk.write(to: project.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        #expect(state() == true, "project-local RTK counts")
        try FileManager.default.removeItem(at: project.appendingPathComponent(".claude/settings.local.json"))
        try "{ not json".write(to: home.appendingPathComponent("settings.local.json"), atomically: true, encoding: .utf8)
        #expect(state() == nil, "an unreadable settings file means RTK cannot be ruled out")
        try rtk.write(to: managed, atomically: true, encoding: .utf8)
        #expect(state() == true)
    }

    // MARK: RTK history, read-only

    static func makeRTKHistory(_ rows: [(cmd: String, input: Int, output: Int, saved: Int, ms: Int, project: String)], dropColumn: Bool = false) throws -> String {
        let path = temp("history.db").path
        let db = try SQLiteDatabase(path: path)
        try db.exec("""
        CREATE TABLE commands (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, original_cmd TEXT NOT NULL, rtk_cmd TEXT NOT NULL,
          input_tokens INTEGER NOT NULL, \(dropColumn ? "" : "output_tokens INTEGER NOT NULL,") saved_tokens INTEGER NOT NULL, savings_pct REAL NOT NULL,
          exec_time_ms INTEGER DEFAULT 0, project_path TEXT DEFAULT '');
        """)
        for (i, r) in rows.enumerated() {
            try db.run("INSERT INTO commands (timestamp, original_cmd, rtk_cmd, input_tokens, \(dropColumn ? "" : "output_tokens,") saved_tokens, savings_pct, exec_time_ms, project_path) VALUES (?,?,?,?,\(dropColumn ? "" : "?,")?,?,?,?)",
                       [.text("2026-10-2\(i % 10)T10:00:00.000000+00:00"), .text(r.cmd), .text("rtk " + r.cmd)] + [.int(Int64(r.input))]
                       + (dropColumn ? [] : [.int(Int64(r.output))]) + [.int(Int64(r.saved)), .double(0), .int(Int64(r.ms)), .text(r.project)])
        }
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        db.close()
        return path
    }

    @Test func rtkHistoryIsReadReadOnlyAndScopedToTheProjectTree() throws {
        let path = try Self.makeRTKHistory([
            ("git log -n 5 --secret", 1000, 100, 900, 20, "/w/app"), ("grep -rn x .", 400, 300, 100, 10, "/w/app/sub"),
            ("ls", 50, 50, 0, 1, "/w/app2"), ("cat f", 70, 10, 60, 2, "/w/other"),
        ])
        let before = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        let ledger = try #require(RTKLedger.read(path: path, projectPath: "/w/app").ledger)
        #expect(ledger.total.commands == 2 && ledger.total.savedTokens == 1000 && ledger.total.inputTokens == 1400, "subdir in, sibling /w/app2 out")
        #expect(ledger.byFamily.map(\.family) == ["git log", "grep"], "family only; arguments never kept")
        #expect(ledger.firstDay == "2026-10-20" && ledger.lastDay == "2026-10-21")
        #expect(try #require(RTKLedger.read(path: path, projectPath: nil).ledger).total.commands == 4)
        #expect(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))) == before, "reading never changes RTK's file")
        #expect(!FileManager.default.fileExists(atPath: path + "-journal"))
    }

    @Test func rtkRowsCanBeLimitedToWhenC2DSessionsRan() throws {
        // makeRTKHistory stamps row i at 2026-10-2i 10:00 UTC (RTK's own RFC 3339 shape, microseconds + offset).
        let path = try Self.makeRTKHistory([("git log", 1000, 100, 900, 20, "/w/app"), ("grep x", 400, 300, 100, 10, "/w/app")])
        let day1 = try #require(RTKLedger.parseTimestamp("2026-10-21T09:00:00Z"))...(try #require(RTKLedger.parseTimestamp("2026-10-21T11:00:00Z")))
        let only = try #require(RTKLedger.read(path: path, projectPath: "/w/app", windows: [day1]).ledger)
        #expect(only.total.commands == 1 && only.total.savedTokens == 100, "only the row inside the session window")
        #expect(try #require(RTKLedger.read(path: path, projectPath: "/w/app", windows: []).ledger).total.commands == 0, "no C2D session, no RTK rows")
        #expect(RTKLedger.parseTimestamp("2026-10-30T10:53:03.444727+00:00") != nil && RTKLedger.parseTimestamp("2026-10-30 10:53:03") != nil)
        #expect(RTKLedger.parseTimestamp("yesterday") == nil)
    }

    @Test func rtkHistoryThatCannotBeTrustedIsLeftOutNotGuessed() throws {
        if case .unavailable = RTKLedger.read(path: "/no/such/history.db", projectPath: nil) {} else { Issue.record("missing file must be unavailable") }
        let odd = try Self.makeRTKHistory([("ls", 1, 1, 0, 0, "/w")], dropColumn: true)
        guard case .unavailable(let why) = RTKLedger.read(path: odd, projectPath: nil) else { Issue.record("unknown layout must be unavailable"); return }
        #expect(why.contains("output_tokens"))
        let garbage = Self.temp("history.db")
        try Data("not a database".utf8).write(to: garbage)
        if case .unavailable = RTKLedger.read(path: garbage.path, projectPath: nil) {} else { Issue.record("garbage must be unavailable") }
    }

    // MARK: Unified report

    static func live(_ family: String, _ original: Int, _ result: Int, skip: GainEvent.SkipReason? = nil, project: String = "/w/app") -> GainEvent {
        GainEvent(timestamp: Date(), source: .live, project: ClaudeTranscriptReader.projectFolderName(for: project), family: family,
                  outcome: skip == nil ? .emitted : .skipped, skipReason: skip, originalStdoutBytes: original, resultStdoutBytes: skip == nil ? result : original)
    }

    @Test func unifiedReportAddsEachEngineOnceAndLabelsBoth() throws {
        let path = try Self.makeRTKHistory([("git log", 1000, 100, 900, 20, "/w/app"), ("grep x", 400, 300, 100, 10, "/w/app")])
        let events = [Self.live("grep", 4000, 2000), Self.live("rtk", 9000, 9000, skip: .rtk),
                      GainEvent(timestamp: Date(), source: .replay, project: ClaudeTranscriptReader.projectFolderName(for: "/w/app"), family: "cat",
                                outcome: .emitted, originalStdoutBytes: 80_000, resultStdoutBytes: 1)]
        let g = UnifiedGain(c2dEvents: events, rtk: RTKLedger.read(path: path, projectPath: "/w/app"), projectPath: "/w/app")
        #expect(g.rtkSavedTokens == 1000 && g.c2dSavedTokens == 500, "C2D: 1000 − 500 est. tokens; the RTK-owned skip and the replay event add nothing")
        #expect(g.estimatedTokensSaved == 1500 && g.estimatedInputTokens == 1400 + 1000)
        let grep = try #require(g.byFamily.first { $0.family == "grep" })
        #expect(grep.engines == "RTK + C2D" && grep.savedTokens == 600)
        // The C2D skip on RTK-owned output is the same command RTK already recorded: counted once, as RTK's.
        #expect(g.commands == 3 && !g.byFamily.contains { $0.family == "rtk" })
        #expect(g.c2d.skips[.rtk] == 1, "still visible in C2D's own skip line")
        #expect(grep.rtkAverageMilliseconds == 10 && grep.c2dAverageMilliseconds == nil, "RTK run time and C2D overhead never mixed")
        let text = g.render()
        #expect(text.contains("RTK-powered") && text.contains("RTK's own count") && text.contains("emitted, delivery to the model not proven"))
        #expect(text.contains("Provider-verified   not measured") && text.contains("estimated, bytes/4, not provider-reported"))
    }

    @Test func unifiedReportWithoutRTKDataSaysSoAndAddsNothingForIt() {
        let g = UnifiedGain(c2dEvents: [Self.live("grep", 400, 200)], rtk: .unavailable("No RTK history."), projectPath: "/w/app")
        #expect(g.estimatedTokensSaved == g.c2dSavedTokens && g.rtkSavedTokens == 0)
        #expect(g.render().contains("RTK-powered       not included — No RTK history."))
        let empty = UnifiedGain(c2dEvents: [], rtk: .unavailable("x"), projectPath: "/w/app")
        #expect(empty.estimatedTokensSaved == 0 && empty.savingsPercent == nil && empty.render().contains("By command: (none)"))
    }
}

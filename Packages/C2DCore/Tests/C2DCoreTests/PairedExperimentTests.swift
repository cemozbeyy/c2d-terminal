import Foundation
import Testing
@testable import C2DCore

@Suite struct ExperimentModelResolverTests {
    private let cwd = "/Users/someone/dev/proj"
    private let idA = "11111111-1111-4111-8111-111111111111"
    private let idB = "22222222-2222-4222-8222-222222222222"

    private func session(_ id: String, models: [String]) -> TranscriptSession {
        TranscriptSession(id: id, fileURL: URL(fileURLWithPath: "/x/\(id).jsonl"), cwd: cwd, cliVersion: "2.1.306", models: models, gitBranch: nil,
                          firstTimestamp: nil, lastTimestamp: nil, messageCount: 1, usage: ProviderUsage(inputTokens: 1, outputTokens: 1))
    }
    private func record(_ sessionID: String?, lifecycle: AgentSessionLifecycle = .running, provider: String = "claude-code", id: String = "R1") -> AgentSessionRecord {
        var r = AgentSessionRecord(id: id, providerID: provider, panelID: nil, projectPath: cwd, workingDirectory: cwd)
        r.providerSessionID = sessionID; r.lifecycle = lifecycle
        return r
    }

    @Test func oneLiveLinkedSessionWithOneModelIsVerified() {
        let s = ExperimentModelResolver.resolve(agentRecords: [record(idA.uppercased())], sessions: [session(idA, models: ["claude-opus-5-5"])])
        #expect(s == .verified(model: "claude-opus-5-5", agentSessionID: "R1", transcriptSessionID: idA, cliVersion: "2.1.306"))
    }

    @Test func severalObservedModelsNeedAnExplicitChoice() {
        let s = ExperimentModelResolver.resolve(agentRecords: [record(idA)], sessions: [session(idA, models: ["claude-fable-5-1", "claude-opus-5-5"])])
        #expect(s == .needsChoice(observedModels: ["claude-fable-5-1", "claude-opus-5-5"], agentSessionID: "R1", transcriptSessionID: idA, cliVersion: "2.1.306"))
    }

    @Test func missingOrAmbiguousMetadataIsUnknownNeverGuessed() {
        func unknown(_ s: ExperimentModelSource) -> Bool { if case .unknown = s { return true }; return false }
        let one = [session(idA, models: ["m"])]
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [], sessions: one)))                                       // nothing running
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idA, lifecycle: .exited)], sessions: one)))        // ended, not active
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(nil)], sessions: one)))                            // no id → no evidence
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idA, provider: "codex")], sessions: one)))         // other provider
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idB)], sessions: one)))                            // no transcript yet
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idA)], sessions: [session(idA, models: [])])))     // no model named
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idA), record(idB, id: "R2")], sessions: one + [session(idB, models: ["m"])])))  // two live
        #expect(unknown(ExperimentModelResolver.resolve(agentRecords: [record(idA)], sessions: one + one)))                      // duplicate transcripts
    }
}

@Suite(.serialized) struct PairedExperimentCommandTests {
    private let experimentDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Tools/experiment").standardizedFileURL

    @Test func previewNeverCarriesRunAndBothShareModelAndSeed() {
        let c = PairedExperimentCommand(script: "/s.py", tasks: "/t.json", model: "claude-opus-5-5", claudeExecutable: "/bin/claude", reps: 3)
        #expect(!c.previewArguments.contains("--run") && c.previewArguments.contains("--json"))
        let run = c.runArguments(outputDirectory: "/out")
        #expect(run.last == "--run" && !run.contains("--json"))
        #expect(Array(run.prefix(12)) == Array(c.previewArguments.prefix(12)), "same script, tasks, model, claude, reps and seed")
    }

    /// The preview through the real runner with a fake `claude` that records any call: the plan decodes and the
    /// fake is never started (zero model calls, not even `claude --version`).
    @Test func previewThroughTheRealRunnerMakesNoCLICall() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("c2d-exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let marker = tmp.appendingPathComponent("called"), fake = tmp.appendingPathComponent("claude")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let c = PairedExperimentCommand(script: experimentDir.appendingPathComponent("paired_experiment.py").path,
                                        tasks: experimentDir.appendingPathComponent("tasks.example.json").path,
                                        model: "claude-opus-5-5", claudeExecutable: fake.path, reps: 3)
        guard case .success(let out) = AgentDiscovery.runSync("/usr/bin/python3", c.previewArguments, timeout: 30) else {
            Issue.record("runner preview failed"); return
        }
        let plan = try JSONDecoder().decode(ExperimentPlan.self, from: Data(out.utf8))
        #expect(plan.runs == 27 && plan.tasks.count == 3 && plan.arms.count == 3 && plan.reps == 3 && plan.model == "claude-opus-5-5")
        #expect(plan.controlRows > 0, "identical-context arms are flagged as A/A controls")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func resultsDecodeAndMismatchBreaksTheSameModelComparison() throws {
        func line(_ match: String, _ models: String, order: Int) -> String {
            #"{"task":"t","arm":"a","rep":0,"order":\#(order),"success":true,"retries":0,"error":"","usage_source":"provider-reported","input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"models_actual":"\#(models)","model_match":"\#(match)"}"#
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try [line("exact", "m", order: 0), line("exact", "m", order: 1), "{broken"].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let loaded = try #require(ExperimentResultRow.load(url))
        #expect(loaded.rows.count == 2 && loaded.undecodable == 1)
        #expect(ExperimentResultRow.sameModelComparison(loaded.rows))
        let mixedSets = loaded.rows + [try JSONDecoder().decode(ExperimentResultRow.self, from: Data(line("mixed", "m,side", order: 2).utf8))]
        #expect(!ExperimentResultRow.sameModelComparison(mixedSets), "different model sets across rows are not comparable")
        let mismatch = loaded.rows + [try JSONDecoder().decode(ExperimentResultRow.self, from: Data(line("mismatch", "other", order: 2).utf8))]
        #expect(!ExperimentResultRow.sameModelComparison(mismatch))
        #expect(!ExperimentResultRow.sameModelComparison([]))
    }
}

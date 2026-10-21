import Foundation

// Token Saver TSD-03 — the paired experiment as seen from the app. The runner stays
// `Tools/experiment/paired_experiment.py`; this file only decides which model to request, builds its
// argv, and decodes what it wrote. Nothing here starts a process or calls a model.

/// Where the model for a new experiment comes from. The launch record carries no model (C2D starts `claude`
/// without `--model`), so the only source is the `message.model` values of the live session's own transcript,
/// linked by the `--session-id` C2D chose (the same evidence as `SessionAttributor`).
public enum ExperimentModelSource: Hashable, Sendable {
    /// One live C2D Claude Code session, linked to its transcript, which shows exactly one model.
    case verified(model: String, agentSessionID: String, transcriptSessionID: String, cliVersion: String)
    /// One live linked session whose transcript shows several models (e.g. side calls). C2D cannot tell which one
    /// is the main model; the user picks one of these explicitly.
    case needsChoice(observedModels: [String], agentSessionID: String, transcriptSessionID: String, cliVersion: String)
    case unknown(reason: String)

    public static let sourceLabel = "Claude Code transcript (provider-reported `message.model`), linked by the --session-id C2D passed at launch"
}

public enum ExperimentModelResolver {
    public static func resolve(agentRecords: [AgentSessionRecord], sessions: [TranscriptSession]) -> ExperimentModelSource {
        let live = agentRecords.filter { $0.isLive && $0.providerID == AgentProvider.claudeCode.id && SessionAttributor.normalized($0.providerSessionID) != nil }
        guard !live.isEmpty else { return .unknown(reason: "No running Claude Code session launched from C2D in this project.") }
        guard live.count == 1, let record = live.first else {
            return .unknown(reason: "\(live.count) Claude Code sessions are running in this project; C2D does not pick one for you. Close all but one to use its model.")
        }
        let id = SessionAttributor.normalized(record.providerSessionID)
        let matches = sessions.filter { SessionAttributor.normalized($0.id) == id }
        guard matches.count == 1, let s = matches.first else {
            return .unknown(reason: matches.isEmpty ? "The running session has no readable transcript yet (no reply so far, or its format failed the check)."
                                                    : "Several transcripts carry the running session's id; not resolved.")
        }
        switch s.models.count {
        case 0: return .unknown(reason: "The running session's transcript names no model.")
        case 1: return .verified(model: s.models[0], agentSessionID: record.id, transcriptSessionID: s.id, cliVersion: s.cliVersion)
        default: return .needsChoice(observedModels: s.models, agentSessionID: record.id, transcriptSessionID: s.id, cliVersion: s.cliVersion)
        }
    }
}

/// argv for `/usr/bin/python3`. The preview never carries `--run`, so the runner cannot reach `claude` at all.
/// The real run still stops at the runner's own "Type SPEND" prompt, answered by the user in a C2D terminal pane.
public struct PairedExperimentCommand: Hashable, Sendable {
    public var script: String
    public var tasks: String
    public var model: String
    public var claudeExecutable: String
    public var reps = 3
    public var seed = 1

    public init(script: String, tasks: String, model: String, claudeExecutable: String, reps: Int = 3, seed: Int = 1) {
        self.script = script; self.tasks = tasks; self.model = model; self.claudeExecutable = claudeExecutable; self.reps = reps; self.seed = seed
    }

    private var common: [String] {
        ["-I", script, "--tasks", tasks, "--model", model, "--claude", claudeExecutable, "--reps", String(reps), "--seed", String(seed)]
    }
    public var previewArguments: [String] { common + ["--json"] }
    public func runArguments(outputDirectory: String) -> [String] { common + ["--out", outputDirectory, "--run"] }
}

/// `--json` output of the runner: the plan, nothing executed.
public struct ExperimentPlan: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable { public let task: String; public let arm: String; public let rep: Int; public let same_context_as: [String] }
    public let runs: Int
    public let reps: Int
    public let seed: Int
    public let max_retries: Int
    public let model: String?
    public let tasks: [String]
    public let arms: [String]
    public let rows: [Row]
    public var controlRows: Int { rows.filter { !$0.same_context_as.isEmpty }.count }
}

/// One line of `results.jsonl` (only the fields the app shows).
public struct ExperimentResultRow: Codable, Hashable, Sendable {
    public let task: String
    public let arm: String
    public let rep: Int
    public let order: Int
    public let success: Bool
    public let retries: Int
    public let error: String
    public let usage_source: String
    public let input_tokens: Int?
    public let output_tokens: Int?
    public let cache_read_input_tokens: Int?
    public let cache_creation_input_tokens: Int?
    public let models_actual: String?   // absent in rows written before the model readback existed
    public let model_match: String?

    public var isProviderReported: Bool { usage_source == "provider-reported" }

    /// Reads `results.jsonl`. A row that does not decode is counted, never dropped silently.
    public static func load(_ url: URL) -> (rows: [ExperimentResultRow], undecodable: Int)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rows: [ExperimentResultRow] = [], bad = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let r = try? JSONDecoder().decode(ExperimentResultRow.self, from: Data(line.utf8)) { rows.append(r) } else { bad += 1 }
        }
        return (rows, bad)
    }

    /// Same rule as the runner's summary: comparable only when every row's transcript contains the requested model
    /// and all rows show the identical model set. Otherwise the result is not a same-model comparison.
    public static func sameModelComparison(_ rows: [ExperimentResultRow]) -> Bool {
        !rows.isEmpty && rows.allSatisfy { $0.model_match == "exact" || $0.model_match == "mixed" } && Set(rows.map { $0.models_actual ?? "" }).count == 1
    }
}

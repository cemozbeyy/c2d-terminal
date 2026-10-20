import Foundation

// Token Saver TS-2 — transcript ↔ C2D launch correlation (Bible Addendum A §A.3-A, ADR-023).
// The only accepted evidence is the session id C2D itself chose at launch (`--session-id`) and stored
// in the agent record. Working directory, timestamps and CLI version never establish ownership.

public enum SessionAttribution: Hashable, Sendable {
    /// Exactly one C2D launch carries this transcript's session id.
    case linked(agentSessionID: String, taskID: String?, taskSummary: String?, lifecycle: AgentSessionLifecycle)
    /// No C2D launch carries this id: started outside C2D, or launched before explicit ids existed.
    case unmatched
    /// More than one C2D record claims the same id (should not happen; reported, never resolved by guessing).
    case ambiguous(agentSessionIDs: [String])

    public var isLinked: Bool { if case .linked = self { return true }; return false }
}

public enum SessionAttributor {
    /// Attribution for every transcript session, keyed by transcript session id. Deterministic and pure:
    /// the same inputs always give the same answer, so repeated rescans cannot drift or duplicate.
    public static func attribute(sessions: [TranscriptSession], agentRecords: [AgentSessionRecord]) -> [String: SessionAttribution] {
        var byProviderID: [String: [AgentSessionRecord]] = [:]
        for r in agentRecords {
            guard let id = normalized(r.providerSessionID) else { continue }   // no id → can never be evidence
            byProviderID[id, default: []].append(r)
        }
        var out: [String: SessionAttribution] = [:]
        for s in sessions {
            guard let key = normalized(s.id), let candidates = byProviderID[key] else { out[s.id] = .unmatched; continue }
            if candidates.count == 1, let r = candidates.first {
                out[s.id] = .linked(agentSessionID: r.id, taskID: r.taskID, taskSummary: r.taskSummary, lifecycle: r.lifecycle)
            } else {
                out[s.id] = .ambiguous(agentSessionIDs: candidates.map(\.id).sorted())
            }
        }
        return out
    }

    /// C2D launches that carry a session id but have no transcript in the ledger yet (not started, exited
    /// before the first reply, or the file is not visible yet). Shown as pending; a later rescan resolves it.
    public static func launchesWithoutTranscript(sessions: [TranscriptSession], agentRecords: [AgentSessionRecord]) -> [AgentSessionRecord] {
        let seen = Set(sessions.compactMap { normalized($0.id) })
        return agentRecords.filter { r in
            guard let id = normalized(r.providerSessionID) else { return false }
            return !seen.contains(id)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Only a well-formed UUID counts; an empty or malformed id is treated as absent, never matched.
    static func normalized(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

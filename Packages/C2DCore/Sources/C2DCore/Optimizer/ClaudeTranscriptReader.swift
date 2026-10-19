import Foundation

// Token Saver TS-1 — usage ledger (Bible Addendum A §A.3-A, ADR-023).
// Reads the usage fields Claude Code writes into its own local session transcripts. Read-only, local,
// format-defensive: only `assistant` records are decoded, only usage/metadata fields are kept, no line is
// retained or logged, nothing is copied or uploaded, nothing is persisted (TS-1 reads on demand).

/// Token counts as the provider wrote them. Never summed with locally estimated numbers.
public struct ProviderUsage: Hashable, Codable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens; self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    /// Everything the provider counted for the request (uncached input + cache read + cache creation + output).
    public var total: Int { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }

    public static func + (a: ProviderUsage, b: ProviderUsage) -> ProviderUsage {
        ProviderUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                      cacheReadInputTokens: a.cacheReadInputTokens + b.cacheReadInputTokens,
                      cacheCreationInputTokens: a.cacheCreationInputTokens + b.cacheCreationInputTokens)
    }
}

/// One Claude Code session (one top-level `.jsonl` file) whose usage could be read.
public struct TranscriptSession: Identifiable, Hashable, Sendable {
    public let id: String             // Claude Code sessionId (falls back to the file name)
    public let fileURL: URL
    public let cwd: String?
    public let cliVersion: String
    public let models: [String]       // distinct, sorted
    public let gitBranch: String?
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let messageCount: Int      // distinct assistant messages (duplicate records of one message count once)
    public let usage: ProviderUsage
}

/// A session file the reader refused to count, with the reason (shown to the user, never guessed around).
public struct UnavailableSession: Hashable, Sendable {
    public let id: String
    public let fileURL: URL
    public let reason: String
}

public struct TranscriptLedger: Sendable {
    public let projectPath: String
    public let folder: URL
    public let sessions: [TranscriptSession]     // newest first
    public let unavailable: [UnavailableSession]
    public let skippedRecords: Int               // non-assistant records (never decoded)
    public let inProgressLines: Int              // trailing partial line of a file being written right now
    public var scannedFiles: Int { sessions.count + unavailable.count }
    public var total: ProviderUsage { sessions.map(\.usage).reduce(ProviderUsage(), +) }
    public var source: MeasurementSource { .providerConfirmed }
    /// "CLI v2.1.303 format (verified)" — the versions actually seen in counted sessions.
    public var formatLabel: String {
        let versions = Set(sessions.map(\.cliVersion)).sorted()
        return versions.isEmpty ? "no verified session" : "CLI v\(versions.joined(separator: ", v")) format (verified)"
    }
}

public enum TranscriptLedgerResult: Sendable {
    case available(TranscriptLedger)
    case unavailable(reason: String)
}

public enum ClaudeTranscriptReader {
    /// CLI versions whose transcript shape was checked by hand (OPEN_DECISIONS §4.5 proposal: pin, never guess).
    /// A session written by any other version is reported as unavailable until that version is verified.
    public static let verifiedCLIVersions: Set<String> = ["2.1.303"]

    /// `CLAUDE_CONFIG_DIR` if set, else `~/.claude`.
    public static func defaultClaudeHome() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Claude Code names the project folder after the cwd with every non-alphanumeric character replaced
    /// by "-" (rule derived from 13 folders on the development Mac, 2026-10-19; `/a/b_c.d` → `-a-b-c-d`).
    public static func projectFolderName(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    public static func projectFolder(for projectPath: String, claudeHome: URL = defaultClaudeHome()) -> URL {
        claudeHome.appendingPathComponent("projects").appendingPathComponent(projectFolderName(for: projectPath))
    }

    /// Synchronous and file-bound — run it off the main actor (ADR-022). Only top-level `*.jsonl` files
    /// are read; sub-agent transcripts in subfolders are not counted in TS-1.
    public static func read(projectPath: String, claudeHome: URL = defaultClaudeHome()) -> TranscriptLedgerResult {
        let folder = projectFolder(for: projectPath, claudeHome: claudeHome)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return .unavailable(reason: "No Claude Code transcripts for this project (expected folder: \(folder.path)).")
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
        } catch {
            return .unavailable(reason: "Transcript folder could not be listed: \(error.localizedDescription)")
        }
        guard !files.isEmpty else { return .unavailable(reason: "The transcript folder has no session files (\(folder.path)).") }

        var sessions: [TranscriptSession] = [], unavailable: [UnavailableSession] = []
        var skipped = 0, inProgress = 0
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch readSession(fileURL: file, projectPath: projectPath) {
            case .success(let r):
                sessions.append(r.session); skipped += r.skippedRecords; inProgress += r.inProgressLines
            case .failure(let why):
                unavailable.append(UnavailableSession(id: file.deletingPathExtension().lastPathComponent, fileURL: file, reason: why.message))
            }
        }
        sessions.sort { ($0.lastTimestamp ?? .distantPast) > ($1.lastTimestamp ?? .distantPast) }
        return .available(TranscriptLedger(projectPath: projectPath, folder: folder, sessions: sessions, unavailable: unavailable,
                                           skippedRecords: skipped, inProgressLines: inProgress))
    }

    struct Failure: Error { let message: String }
    struct SessionRead { let session: TranscriptSession; let skippedRecords: Int; let inProgressLines: Int }

    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let newline = UInt8(ascii: "\n")

    static func readSession(fileURL: URL, projectPath: String) -> Result<SessionRead, Failure> {
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { return .failure(Failure(message: "could not read the file: \(error.localizedDescription)")) }

        struct Message { var usage: ProviderUsage; var model: String?; var timestamp: Date? }
        var messages: [String: Message] = [:]     // keyed by message id: one message, several streamed records
        var order: [String] = []
        var versions = Set<String>(), models = Set<String>(), cwds = Set<String>()
        var sessionID: String?, gitBranch: String?
        var skipped = 0, inProgress = 0
        let endsWithNewline = data.last == newline

        var start = data.startIndex
        var lineNumber = 0
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let line = data[start..<end]
            let isLast = end == data.endIndex
            start = end == data.endIndex ? end : data.index(after: end)
            lineNumber += 1
            if line.isEmpty { continue }
            if isLast && !endsWithNewline { inProgress += 1; continue }        // still being written — not malformed
            guard line.range(of: assistantMarker) != nil else { skipped += 1; continue }  // cheap pre-filter; never decoded
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: line) } catch { return .failure(Failure(message: "malformed JSON on line \(lineNumber)")) }
            guard let record = object as? [String: Any] else { return .failure(Failure(message: "line \(lineNumber) is not a JSON object")) }
            guard record["type"] as? String == "assistant" else { skipped += 1; continue }

            guard let message = record["message"] as? [String: Any] else { return .failure(Failure(message: "assistant record on line \(lineNumber) has no message")) }
            guard let usageDict = message["usage"] as? [String: Any] else { return .failure(Failure(message: "assistant record on line \(lineNumber) has no usage")) }
            func count(_ key: String, required: Bool) -> Int? {
                if let n = usageDict[key] as? NSNumber { return n.intValue }
                return usageDict[key] == nil && !required ? 0 : nil
            }
            guard let input = count("input_tokens", required: true), let output = count("output_tokens", required: true),
                  let cacheRead = count("cache_read_input_tokens", required: false), let cacheCreate = count("cache_creation_input_tokens", required: false)
            else { return .failure(Failure(message: "unrecognised usage shape on line \(lineNumber)")) }
            guard let id = (message["id"] as? String) ?? (record["requestId"] as? String) else { return .failure(Failure(message: "assistant record on line \(lineNumber) has no message id")) }

            if let v = record["version"] as? String { versions.insert(v) } else { return .failure(Failure(message: "assistant record on line \(lineNumber) carries no CLI version")) }
            if let c = record["cwd"] as? String { cwds.insert(c) }
            if let s = record["sessionId"] as? String { sessionID = s }
            if let b = record["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
            let model = message["model"] as? String
            if let model, model != "<synthetic>" { models.insert(model) }   // CLI-generated placeholder records (usage all 0, verified) are counted but not listed as a model
            let ts = (record["timestamp"] as? String).flatMap(parseTimestamp)
            if messages[id] == nil { order.append(id) }
            messages[id] = Message(usage: ProviderUsage(inputTokens: input, outputTokens: output, cacheReadInputTokens: cacheRead, cacheCreationInputTokens: cacheCreate), model: model, timestamp: ts)
        }

        let unverified = versions.subtracting(verifiedCLIVersions)
        if !unverified.isEmpty {
            return .failure(Failure(message: "CLI version \(unverified.sorted().joined(separator: ", ")) not yet verified — numbers withheld rather than guessed"))
        }
        let wanted = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        if let other = cwds.first(where: { URL(fileURLWithPath: $0).standardizedFileURL.path != wanted }) {
            return .failure(Failure(message: "transcript belongs to another directory (\(other))"))
        }
        guard !messages.isEmpty else { return .failure(Failure(message: "no assistant messages with usage in this file")) }

        let stamps = messages.values.compactMap(\.timestamp)
        let session = TranscriptSession(
            id: sessionID ?? fileURL.deletingPathExtension().lastPathComponent, fileURL: fileURL, cwd: cwds.first,
            cliVersion: versions.sorted().joined(separator: ", "), models: models.sorted(), gitBranch: gitBranch,
            firstTimestamp: stamps.min(), lastTimestamp: stamps.max(), messageCount: messages.count,
            usage: messages.values.map(\.usage).reduce(ProviderUsage(), +))
        return .success(SessionRead(session: session, skippedRecords: skipped, inProgressLines: inProgress))
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

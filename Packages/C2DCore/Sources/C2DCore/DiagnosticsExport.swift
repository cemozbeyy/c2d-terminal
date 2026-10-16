import Foundation

// Diagnostics export (Bible Part 11 §15 Error Model, §18 Observability, §12.4 export bundles).
// Safety is minimization-first: a bundle is built only from the allowlisted fields below — it has no
// field for command arguments, environment values, file contents, terminal output, or prompts, so
// those cannot be exported. SecretRedactor is a secondary net applied at record time, so the in-memory
// buffer never holds secrets either. os_log history (Log.*) is NOT part of a bundle.

/// Scrubs secrets and local identity from free text. Minimization is the primary defence; this is the
/// safety net for the one free-text field (`detail`, only present at verbose verbosity).
public enum SecretRedactor {
    private static func sub(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    // Applied in order. Specific shapes first, then the generic high-entropy catch, then local paths.
    private static let rules: [(NSRegularExpression?, String)] = [
        (sub("-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----"), "[REDACTED-PRIVATE-KEY]"),
        // Whole Authorization value (scheme + token), to the end of the line.
        (sub("(?i)authorization:[^\\n]+"), "Authorization: [REDACTED]"),
        (sub("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._\\-+/=]+"), "$1 [REDACTED]"),
        // scheme://user:pass@host → strip the credentials only.
        (sub("([A-Za-z][A-Za-z0-9+.\\-]*://)[^/\\s:@]+:[^/\\s@]+@"), "$1[REDACTED]@"),
        // sensitive key = value (quoted or bare).
        (sub("(?i)\\b(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|auth|credential|session)\\b\\s*[=:]\\s*(\"[^\"]*\"|'[^']*'|\\S+)"), "$1=[REDACTED]"),
        // Known provider token shapes (many are shorter than the 32-char generic catch below).
        // Each is \b-anchored so it can't match inside an ordinary word (e.g. "task-123" ≠ "sk-…").
        (sub("\\bAKIA[0-9A-Z]{16}", []), "[REDACTED-TOKEN]"),
        (sub("\\bgh[pousr]_[A-Za-z0-9]{20,}", []), "[REDACTED-TOKEN]"),
        (sub("\\bgithub_pat_[A-Za-z0-9_]{20,}", []), "[REDACTED-TOKEN]"),
        (sub("\\bxox[baprs]-[A-Za-z0-9-]{10,}", []), "[REDACTED-TOKEN]"),
        (sub("\\bAIza[0-9A-Za-z_\\-]{30,}", []), "[REDACTED-TOKEN]"),
        (sub("\\bsk_(live|test)_[A-Za-z0-9]{10,}", []), "[REDACTED-TOKEN]"),
        (sub("\\bsk-[A-Za-z0-9_\\-]{10,}", []), "[REDACTED-TOKEN]"),
        (sub("\\beyJ[A-Za-z0-9_\\-]+\\.eyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+", []), "[REDACTED-JWT]"),
    ]

    public static func redact(_ input: String) -> String {
        var s = input
        for (re, replacement) in rules {
            guard let re else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
        }
        s = redactHighEntropy(s)
        s = collapseHomePaths(s)
        return s
    }

    /// Any opaque run of ≥32 [A-Za-z0-9_-] characters is treated as a possible token and redacted,
    /// EXCEPT a bare 40- or 64-char lowercase hex string (a git SHA we want to keep).
    private static func redactHighEntropy(_ s: String) -> String {
        guard let re = sub("[A-Za-z0-9_\\-]{32,}", []) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let token = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += isHexSHA(token) ? token : "[REDACTED-TOKEN]"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func isHexSHA(_ t: String) -> Bool {
        (t.count == 40 || t.count == 64) && t.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// Replaces `/Users/<name>/` with `~/` so the local username does not leak.
    private static func collapseHomePaths(_ s: String) -> String {
        guard let re = sub("/Users/[^/\\s:]+", []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "~")
    }
}

/// §15 error taxonomy.
public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
    case userInput, invalidConfiguration, missingDependency, permission, os, git, provider, network, persistence, dataCorruption, timeout, cancellation, unknown
}

/// §18: an outcome may be genuinely unknown (e.g. a process we had to terminate); never flatten that to failure.
public enum DiagnosticOutcome: String, Codable, Sendable { case success, failure, unknown }

public enum DiagnosticVerbosity: String, Codable, Sendable { case normal, verbose }

/// One diagnostic record. Only these allowlisted fields exist; there is deliberately no field that
/// could carry source, env, args, terminal output, or prompts.
public struct DiagnosticEvent: Codable, Sendable, Hashable {
    public let at: Date
    public let module: String
    public let operation: String
    public let category: DiagnosticCategory
    public let outcome: DiagnosticOutcome
    public let errorType: String?
    public let reason: String?
    public let exitCode: Int32?
    public let durationMS: Int?
    public let detail: String?   // only at verbose; redacted + truncated

    /// The complete set of JSON keys an event may carry — used by tests to prove nothing else leaks in.
    public static let allowedKeys: Set<String> = ["at", "module", "operation", "category", "outcome", "errorType", "reason", "exitCode", "durationMS", "detail"]
}

/// Maps an error to allowlisted, secret-free classification fields. Case names only — never associated
/// values (which may hold git stderr, paths, etc.).
public enum DiagnosticClassifier {
    public static func classify(_ error: Error) -> (category: DiagnosticCategory, errorType: String, reason: String?, exitCode: Int32?, outcome: DiagnosticOutcome) {
        if let g = error as? GitError {
            switch g {
            case .gitUnavailable: return (.missingDependency, "GitError", "gitUnavailable", nil, .failure)
            case .notARepository: return (.invalidConfiguration, "GitError", "notARepository", nil, .failure)
            case .identityNotConfigured: return (.invalidConfiguration, "GitError", "identityNotConfigured", nil, .failure)
            case .dirtyWorkingTree: return (.userInput, "GitError", "dirtyWorkingTree", nil, .failure)
            case .nothingToCommit: return (.userInput, "GitError", "nothingToCommit", nil, .failure)
            case .emptyMessage: return (.userInput, "GitError", "emptyMessage", nil, .failure)
            case .invalidPath: return (.userInput, "GitError", "invalidPath", nil, .failure)
            case .staleDiff: return (.userInput, "GitError", "staleDiff", nil, .failure)
            case .notConflicted: return (.userInput, "GitError", "notConflicted", nil, .failure)
            case .conflictMarkersRemain: return (.userInput, "GitError", "conflictMarkersRemain", nil, .failure)
            case .patchDoesNotApply: return (.git, "GitError", "patchDoesNotApply", nil, .failure)
            case .commandFailed(let code, _):
                // A process we terminated (SIGTERM/143) leaves the real outcome unknown, not failed.
                let terminated = code == 15 || code == 143 || code < 0
                return (.git, "GitError", terminated ? "terminated" : nil, code, terminated ? .unknown : .failure)
            }
        }
        if let t = error as? TaskError {
            switch t {
            case .notFound: return (.userInput, "TaskError", "notFound", nil, .failure)
            case .invalidTransition: return (.userInput, "TaskError", "invalidTransition", nil, .failure)
            case .storage: return (.persistence, "TaskError", "storage", nil, .failure)
            case .selfDependency: return (.userInput, "TaskError", "selfDependency", nil, .failure)
            case .crossProject: return (.userInput, "TaskError", "crossProject", nil, .failure)
            case .dependencyCycle: return (.userInput, "TaskError", "dependencyCycle", nil, .failure)
            case .dependenciesUnmet: return (.userInput, "TaskError", "dependenciesUnmet", nil, .failure)
            case .hasDependents: return (.userInput, "TaskError", "hasDependents", nil, .failure)
            }
        }
        return (.unknown, "\(type(of: error))", nil, nil, .failure)
    }
}

/// Bounded, in-memory diagnostic buffer. No indefinite accumulation (§12.3), no central infrastructure.
public actor DiagnosticsRecorder {
    private var events: [DiagnosticEvent] = []
    private let capacity: Int
    public private(set) var verbosity: DiagnosticVerbosity

    public init(capacity: Int = 500, verbosity: DiagnosticVerbosity = .normal) {
        self.capacity = max(1, capacity)
        self.verbosity = verbosity
    }

    public func setVerbosity(_ v: DiagnosticVerbosity) { verbosity = v }

    private static func clean(_ s: String?, limit: Int = 200) -> String? {
        guard let s, !s.isEmpty else { return nil }
        let redacted = SecretRedactor.redact(s)
        return redacted.count > limit ? String(redacted.prefix(limit)) + "…" : redacted
    }

    /// Records an error-derived event. `detail` is kept only at verbose verbosity, always redacted.
    public func record(module: String, operation: String, error: Error, durationMS: Int? = nil) {
        let c = DiagnosticClassifier.classify(error)
        let detail = verbosity == .verbose ? Self.clean(String(describing: error)) : nil
        append(DiagnosticEvent(at: Date(), module: module, operation: Self.clean(operation, limit: 80) ?? "",
                               category: c.category, outcome: c.outcome, errorType: c.errorType,
                               reason: c.reason, exitCode: c.exitCode, durationMS: durationMS, detail: detail))
    }

    /// Records a free-form event (e.g. a user-facing message). `detail` kept only at verbose.
    public func record(module: String, operation: String, category: DiagnosticCategory = .unknown,
                        outcome: DiagnosticOutcome = .failure, detail: String? = nil, durationMS: Int? = nil) {
        append(DiagnosticEvent(at: Date(), module: module, operation: Self.clean(operation, limit: 80) ?? "",
                               category: category, outcome: outcome, errorType: nil, reason: nil,
                               exitCode: nil, durationMS: durationMS, detail: verbosity == .verbose ? Self.clean(detail) : nil))
    }

    private func append(_ e: DiagnosticEvent) {
        events.append(e)
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func snapshot() -> [DiagnosticEvent] { events }
    public func clear() { events.removeAll() }

    public func makeBundle(report: DiagnosticsReport) -> DiagnosticsBundle {
        DiagnosticsBundle(generatedAt: Date(), includesDetail: verbosity == .verbose, report: report, events: events)
    }
}

/// A previewable, serializable support bundle (§12.4). Everything in it is already redacted/allowlisted.
public struct DiagnosticsBundle: Codable, Sendable {
    public let generatedAt: Date
    public let includesDetail: Bool
    public let report: DiagnosticsReport
    public let events: [DiagnosticEvent]

    public func serialized() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
}

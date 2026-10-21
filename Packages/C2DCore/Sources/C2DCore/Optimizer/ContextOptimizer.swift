import Foundation

public struct ContextItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, selection, diff, instructions, terminalOutput, note }
    public let id: String
    public let kind: Kind
    public let path: String?
    public var content: String
    /// Mandatory items are never removed or reduced to meet a budget (Bible Part 10 §6).
    public let mandatory: Bool

    public init(id: String = UUID().uuidString, kind: Kind, path: String? = nil, content: String, mandatory: Bool = false) {
        self.id = id
        self.kind = kind
        self.path = path
        self.content = content
        self.mandatory = mandatory
    }
}

public struct ContextPayload: Hashable, Sendable {
    public var items: [ContextItem]
    public init(items: [ContextItem]) { self.items = items }

    /// Measured: UTF-8 bytes of every item's content.
    public var byteCount: Int { items.reduce(0) { $0 + $1.content.utf8.count } }

    public var estimate: TokenEstimate {
        let total = items.reduce(0) { $0 + TokenEstimator.estimate($1.content).tokens }
        return TokenEstimate(tokens: total, source: .heuristicEstimate, confidence: "sum of per-item heuristic estimates")
    }
}

/// One change the optimizer made. `originalContent` keeps it reversible (Part 10 §18).
public struct OptimizationAction: Hashable, Sendable {
    public enum Kind: String, Sendable { case removedExactDuplicate, normalizedWhitespace, condensedOutput }
    public let itemID: String
    public let kind: Kind
    public let reason: String
    public let originalContent: String
    public let tokensBefore: Int
    public let tokensAfter: Int
}

public struct OptimizationResult: Hashable, Sendable {
    public let before: TokenEstimate
    public let after: TokenEstimate
    public let payload: ContextPayload
    public let actions: [OptimizationAction]
    public let preservedMandatory: Int
    /// True only when a lossy condensing step actually ran (the opt-in alone does not make a result lossy).
    public internal(set) var lossyStepsApplied = false
    public var removedItemIDs: [String] { actions.filter { $0.kind == .removedExactDuplicate }.map(\.itemID) }
}

public enum BudgetVerdict: Hashable, Sendable {
    case fits(tokens: Int, budget: Int)
    /// Over budget. `optionalCandidates` are the non-mandatory items a user could drop; nothing was dropped.
    case exceedsBy(tokens: Int, optionalCandidates: [String], mandatoryTokens: Int)
}

/// Deterministic, local-only context reduction (Bible Part 10 Phase A). No semantic judgement:
/// only byte-identical duplicates (after whitespace normalization) and whitespace clean-up.
public enum ContextOptimizer {
    public static func deduplicate(_ payload: ContextPayload) -> OptimizationResult {
        let before = payload.estimate
        var seen: [String: String] = [:]   // normalized content → first item id
        var kept: [ContextItem] = []
        var actions: [OptimizationAction] = []
        var preservedMandatory = 0

        for item in payload.items {
            let normalized = normalizeWhitespace(item.content)
            let tokensBefore = TokenEstimator.estimate(item.content).tokens
            if let firstID = seen[normalized], !item.mandatory {
                actions.append(OptimizationAction(itemID: item.id, kind: .removedExactDuplicate,
                                                  reason: "identical to item \(firstID) after whitespace normalization",
                                                  originalContent: item.content, tokensBefore: tokensBefore, tokensAfter: 0))
                continue
            }
            if seen[normalized] != nil, item.mandatory { preservedMandatory += 1 }
            var copy = item
            if normalized != item.content {
                copy.content = normalized
                actions.append(OptimizationAction(itemID: item.id, kind: .normalizedWhitespace,
                                                  reason: "trailing spaces, CRLF or runs of blank lines removed",
                                                  originalContent: item.content, tokensBefore: tokensBefore,
                                                  tokensAfter: TokenEstimator.estimate(normalized).tokens))
            }
            if seen[normalized] == nil { seen[normalized] = item.id }
            kept.append(copy)
        }
        let result = ContextPayload(items: kept)
        return OptimizationResult(before: before, after: result.estimate, payload: result, actions: actions, preservedMandatory: preservedMandatory)
    }

    /// Full deterministic pass: terminal-output items are condensed (TS-4, `OutputCondenser`), then exact
    /// duplicates and whitespace are handled as in `deduplicate`. Every change keeps its original. Lossless by
    /// default; lossy folding only when the caller passes options that allow it.
    public static func optimize(_ payload: ContextPayload, output: OutputCondenser.Options = .lossless) -> OptimizationResult {
        var condensed = payload
        var actions: [OptimizationAction] = []
        var lossy = false
        for i in condensed.items.indices where condensed.items[i].kind == .terminalOutput && !condensed.items[i].mandatory {
            let item = condensed.items[i]
            let c = OutputCondenser.condense(item.content, options: output)
            guard c.text != item.content, c.text.utf8.count < item.content.utf8.count else { continue }
            actions.append(OptimizationAction(itemID: item.id, kind: .condensedOutput,
                                              reason: "\(c.steps.map(\.rawValue).joined(separator: ", ")); \(c.linesBefore)→\(c.linesAfter) lines, all \(c.diagnosticLines) diagnostic line(s) kept",
                                              originalContent: item.content, tokensBefore: TokenEstimator.estimate(item.content).tokens,
                                              tokensAfter: TokenEstimator.estimate(c.text).tokens))
            condensed.items[i].content = c.text
            lossy = lossy || c.steps.contains(where: \.isLossy)
        }
        let d = deduplicate(condensed)
        var r = OptimizationResult(before: payload.estimate, after: d.after, payload: d.payload, actions: actions + d.actions, preservedMandatory: d.preservedMandatory)
        r.lossyStepsApplied = lossy
        return r
    }

    /// Markdown for a hand-off (TS-3): one section per item, each body in a fence longer than any backtick
    /// run inside it so pasted code can't break out.
    public static func handOffMarkdown(_ payload: ContextPayload, title: String) -> String {
        var out = "# \(title)\n"
        for item in payload.items {
            out += "\n## \(item.kind.rawValue)\(item.path.map { ": \($0)" } ?? "")\(item.mandatory ? " (mandatory)" : "")\n\n"
            var longest = 0, run = 0
            for ch in item.content { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            out += "\(fence)\n\(item.content)\n\(fence)\n"
        }
        return out
    }

    /// Reports only; the user decides what to drop (Part 10 §6).
    public static func budgetCheck(_ payload: ContextPayload, budgetTokens: Int) -> BudgetVerdict {
        let total = payload.estimate.tokens
        if total <= budgetTokens { return .fits(tokens: total, budget: budgetTokens) }
        let mandatoryTokens = payload.items.filter(\.mandatory).reduce(0) { $0 + TokenEstimator.estimate($1.content).tokens }
        let optional = payload.items.filter { !$0.mandatory }.map(\.id)
        return .exceedsBy(tokens: total - budgetTokens, optionalCandidates: optional, mandatoryTokens: mandatoryTokens)
    }

    /// CRLF/CR → LF, trailing spaces/tabs per line removed, more than one consecutive blank line collapsed to one.
    static func normalizeWhitespace(_ text: String) -> String {
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [Substring] = []
        var blankRun = 0
        for line in lf.split(separator: "\n", omittingEmptySubsequences: false) {
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)] == " " || line[line.index(before: end)] == "\t" { end = line.index(before: end) }
            let trimmed = line[line.startIndex..<end]
            if trimmed.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            out.append(trimmed)
        }
        return out.joined(separator: "\n")
    }
}

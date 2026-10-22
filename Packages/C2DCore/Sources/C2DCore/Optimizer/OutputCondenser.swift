import Foundation

// Token Saver TS-4 — terminal output condensing for context the USER hands to an agent (ADR-023: never an
// interception of the agent's own tool calls). Deterministic and lossy only where it says so: every removal
// leaves a `[c2d: …]` marker in the text, diagnostic lines are never removed, and the caller keeps the original.

public struct CondensedOutput: Hashable, Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case strippedEscapes       // ANSI/OSC sequences, backspaces, carriage-return progress overwrites
        case collapsedRepeats      // ≥ 3 identical consecutive lines → one line + count
        case collapsedSimilar      // long runs of non-diagnostic lines identical except for digits
        case groupedByFile         // ≥ 3 consecutive `path:line:text` lines → `path:` header + `  line: text` (lossless)
        case elidedLongLines       // long tool invocations / machine dumps (not diagnostic) keep their start and end
        case truncatedMiddle       // over the line budget: head + tail + every diagnostic line in between

        /// Steps that drop content (each leaves a marker); only reachable when the caller opts in (TSD-08).
        public var isLossy: Bool { self == .collapsedSimilar || self == .elidedLongLines || self == .truncatedMiddle }
    }
    public let text: String
    public let original: String
    public let steps: [Step]
    public let linesBefore: Int
    public let linesAfter: Int
    /// Diagnostic lines (errors, warnings, failures, `file:line`) in the original; all of them are in `text`.
    public let diagnosticLines: Int
    public var changed: Bool { !steps.isEmpty }
}

public enum OutputCondenser {
    public struct Options: Hashable, Sendable {
        /// Soft cap on output lines. Diagnostic lines are kept even past it. nil = never truncate.
        public var lineBudget: Int?
        public var headLines: Int
        public var tailLines: Int
        /// A digit-only-differing run is collapsed only from this length.
        public var similarRunMinimum: Int
        /// Command-invocation lines (≥ 8 `-flag` words, e.g. swiftc/clang lines in build logs) longer than this,
        /// and any non-diagnostic line over 10× this (single-line dumps, minified blobs), keep their first 160
        /// and last 60 characters. Prose paragraphs (the longest in this repo's docs: < 2 500) are left alone. nil = never.
        public var longLine: Int?
        public init(lineBudget: Int? = 300, headLines: Int = 40, tailLines: Int = 80, similarRunMinimum: Int = 6, longLine: Int? = 400) {
            self.lineBudget = lineBudget; self.headLines = headLines; self.tailLines = tailLines; self.similarRunMinimum = similarRunMinimum
            self.longLine = longLine
        }
        /// Only transformations that drop nothing: escapes, exact repeats (counted), file grouping.
        public static let lossless = Options(lineBudget: nil, similarRunMinimum: .max, longLine: nil)
    }

    public static func condense(_ raw: String, options: Options = Options()) -> CondensedOutput {
        var steps: [CondensedOutput.Step] = []
        let cleaned = stripEscapes(raw)
        if cleaned != raw.replacingOccurrences(of: "\r\n", with: "\n") { steps.append(.strippedEscapes) }
        var lines = ContextOptimizer.normalizeWhitespace(cleaned).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        var rawLines = raw.components(separatedBy: "\n")
        while rawLines.last?.isEmpty == true { rawLines.removeLast() }
        let linesBefore = rawLines.count
        let diagnostics = lines.filter(isDiagnostic).count

        let afterRepeats = collapseRepeats(lines)
        if afterRepeats.count < lines.count { steps.append(.collapsedRepeats) }
        let afterSimilar = collapseSimilar(afterRepeats, minimum: options.similarRunMinimum)
        if afterSimilar.count < afterRepeats.count { steps.append(.collapsedSimilar) }
        var final = afterSimilar
        if let limit = options.longLine {
            let elided = final.map { elideLongLine($0, limit: limit) }
            if elided != final { final = elided; steps.append(.elidedLongLines) }
        }
        // Truncate before grouping: grouped rows no longer carry their path, so they would not look diagnostic.
        if let budget = options.lineBudget, final.count > budget {
            let cut = truncateMiddle(final, head: options.headLines, tail: options.tailLines)
            if cut.count < final.count { final = cut; steps.append(.truncatedMiddle) }
        }
        let grouped = groupByFile(final)
        if grouped != final, grouped.joined(separator: "\n").utf8.count < final.joined(separator: "\n").utf8.count { final = grouped; steps.append(.groupedByFile) }
        let cleanedText = lines.joined(separator: "\n")
        if !steps.isEmpty && steps != [.strippedEscapes] {
            final.insert("[c2d: condensed \(linesBefore)→\(final.count) lines; every error/warning/file:line kept]", at: 0)
            // Never worse (RTK's guard): if the markers cost more than they saved, hand over the cleaned text.
            if final.joined(separator: "\n").utf8.count >= cleanedText.utf8.count {
                final = lines; steps = steps.contains(.strippedEscapes) ? [.strippedEscapes] : []
            }
        }
        return CondensedOutput(text: final.joined(separator: "\n"), original: raw, steps: steps,
                               linesBefore: linesBefore, linesAfter: final.count, diagnosticLines: diagnostics)
    }

    // MARK: Exact fold (ADR-035)

    /// First line of an exact fold; tells the reader how to read the rows back.
    public static let exactHeader = "[c2d: lossless fold; under a \"path:\" line, \"  N:…\" means \"path:N:…\"; repeat counts are exact]"

    /// Byte-exact variant of the lossless steps: no escape stripping, no whitespace or CR/LF normalization, only
    /// exact-repeat counting and file grouping on the raw lines. Returns nil unless the fold is smaller and
    /// `expandExact` gives back `text` byte for byte — checked on every call, so an ambiguous line in the
    /// original (a literal marker, a `name:` line followed by indented numbers) makes it decline, never guess.
    public static func condenseExact(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let folded = groupByFile(collapseRepeats(lines))
        guard folded != lines else { return nil }
        let out = ([exactHeader] + folded).joined(separator: "\n")
        guard out.utf8.count < text.utf8.count, expandExact(out) == text else { return nil }
        return out
    }

    /// Inverse of `condenseExact`: drops the header, expands file groups and repeat markers.
    public static func expandExact(_ text: String) -> String {
        guard text.hasPrefix(exactHeader + "\n") else { return text }
        return expandRepeats(expandGroups(String(text.dropFirst(exactHeader.count + 1)))).joined(separator: "\n")
    }

    /// Inverse of `collapseRepeats`: each `[c2d: previous line repeated N more times]` becomes N copies of the line before it.
    static func expandRepeats(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            if line.hasPrefix("[c2d: previous line repeated "), line.hasSuffix(" more times]"),
               let n = Int(line.dropFirst("[c2d: previous line repeated ".count).dropLast(" more times]".count)), let last = out.last {
                out += Array(repeating: last, count: n)
            } else {
                out.append(line)
            }
        }
        return out
    }

    // MARK: Steps

    /// Removes CSI/OSC/other ESC sequences and backspace overstrikes, and resolves `\r` progress redraws to the
    /// last segment of the line (what a terminal would show). CRLF counts as a plain newline.
    static func stripEscapes(_ s: String) -> String {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.contains("\u{1B}") || text.contains("\r") || text.contains("\u{08}") else { return text }
        var out = String.UnicodeScalarView()
        var it = Array(text.unicodeScalars)[...]
        while let c = it.popFirst() {
            switch c {
            case "\u{1B}":
                guard let next = it.popFirst() else { break }
                if next == "[" {          // CSI: parameters/intermediates until a final byte 0x40–0x7E
                    while let p = it.popFirst(), !(0x40...0x7E).contains(p.value) {}
                } else if next == "]" {   // OSC: until BEL or ESC \
                    while let p = it.popFirst() {
                        if p == "\u{07}" { break }
                        if p == "\u{1B}" { _ = it.popFirst(); break }
                    }
                }                          // other two-byte escapes: both bytes dropped
            case "\u{08}":
                if !out.isEmpty { out.removeLast() }
            default:
                out.append(c)
            }
        }
        // Carriage-return redraws: keep the text after the last \r on each line (empty trailing \r ignored).
        return String(out).split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard line.contains("\r") else { return line }
            return line.split(separator: "\r", omittingEmptySubsequences: true).last ?? ""
        }.joined(separator: "\n")
    }

    /// Runs of ≥ 3 identical lines → the line once plus a count marker (a run of 2 is cheaper left alone).
    static func collapseRepeats(_ lines: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            var j = i + 1
            while j < lines.count && lines[j] == lines[i] { j += 1 }
            let run = j - i
            out.append(lines[i])
            if run >= 3 && !lines[i].isEmpty { out.append("[c2d: previous line repeated \(run - 1) more times]") }
            else if run > 1 { out.append(contentsOf: Array(repeating: lines[i], count: run - 1)) }
            i = j
        }
        return out
    }

    /// Runs of non-diagnostic lines that are identical once digits are masked (progress counters, "Compiling
    /// 12/300", timestamps) keep their first two and last line. Diagnostic lines break a run, so an error
    /// line — or two errors differing only in a line number — is never folded.
    static func collapseSimilar(_ lines: [String], minimum: Int) -> [String] {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let key = maskDigits(lines[i])
            guard !isDiagnostic(lines[i]), key != lines[i] else { out.append(lines[i]); i += 1; continue }
            var j = i + 1
            while j < lines.count, !isDiagnostic(lines[j]), maskDigits(lines[j]) == key { j += 1 }
            let run = j - i
            if run >= minimum {
                out.append(lines[i]); out.append(lines[i + 1])
                out.append("[c2d: \(run - 3) similar lines omitted (differ only in numbers)]")
                out.append(lines[j - 1])
            } else {
                out.append(contentsOf: lines[i..<j])
            }
            i = j
        }
        return out
    }

    /// `path:line:text` (grep -n / rg -n / compiler style) runs of ≥ 3 lines with the same path become a `path:`
    /// header and `  line:text` rows. Lossless: `expandGroups` restores the original lines exactly.
    static func groupByFile(_ lines: [String]) -> [String] {
        func split(_ l: String) -> (String, String)? {
            guard let m = groupPattern.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                  let r = Range(m.range(at: 1), in: l) else { return nil }
            return (String(l[r]), String(l[r.upperBound...].dropFirst()))   // drop the ":" after the path
        }
        var out: [String] = []
        var i = 0
        while i < lines.count {
            guard let (path, _) = split(lines[i]) else { out.append(lines[i]); i += 1; continue }
            var j = i + 1
            while j < lines.count, let (p, _) = split(lines[j]), p == path { j += 1 }
            if j - i >= 3 {
                out.append(path + ":")
                for k in i..<j { out.append("  " + split(lines[k])!.1) }
            } else {
                out.append(contentsOf: lines[i..<j])
            }
            i = j
        }
        return out
    }

    /// Inverse of `groupByFile`, for checking that grouping lost nothing.
    public static func expandGroups(_ text: String) -> [String] {
        var out: [String] = []
        var path: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("  "), let p = path, line.dropFirst(2).first?.isNumber == true { out.append(p + ":" + line.dropFirst(2)); continue }
            if line.hasSuffix(":"), !line.hasPrefix(" "), !line.contains(" "), line.count > 1 { path = String(line.dropLast()); continue }
            path = nil
            out.append(line)
        }
        return out
    }

    /// A path with an extension followed by `:<line>:` — not a URL (`https://…`) and not a time (`12:30:`).
    private static let groupPattern = try! NSRegularExpression(pattern: #"^([^\s:]+\.[A-Za-z0-9]{1,8}):\d+[:-]"#)

    static func elideLongLine(_ line: String, limit: Int) -> String {
        guard line.count > limit, !isDiagnostic(line),
              line.count > limit * 10 || line.split(separator: " ").lazy.filter({ $0.hasPrefix("-") && $0.count > 1 }).prefix(8).count == 8
        else { return line }
        return "\(line.prefix(160)) [c2d: \(line.count - 220) chars omitted] \(line.suffix(60))"
    }

    /// Keeps `head` and `tail` lines, and from the middle every diagnostic line with one line of context on
    /// each side. Gaps become explicit markers with the number of lines omitted.
    static func truncateMiddle(_ lines: [String], head: Int, tail: Int) -> [String] {
        guard lines.count > head + tail else { return lines }
        var keep = Set(0..<head).union((lines.count - tail)..<lines.count)
        for i in head..<(lines.count - tail) where isDiagnostic(lines[i]) {
            keep.formUnion(max(0, i - 1)...min(lines.count - 1, i + 1))
        }
        var out: [String] = []
        var gap = 0
        for i in 0..<lines.count {
            if keep.contains(i) {
                if gap > 0 { out.append("[c2d: \(gap) lines omitted]"); gap = 0 }
                out.append(lines[i])
            } else {
                gap += 1
            }
        }
        return out
    }

    // MARK: Classification

    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"(?i)\berr!|\b(error|errors|warning|warn|fail|failed|failure|failing|fatal|panic|panicked|exception|traceback|assert(ion)?|abort(ed)?|segmentation|denied|unresolved|undefined|cannot|can't|unable|not found|no such|refused|timed? ?out|crash(ed)?)\b|[✘✗×❌]|\b[\w./+-]+\.[A-Za-z]{1,6}:\d+(:\d+)?\b|^\s*at\s.+[:(]\d+"#)

    /// Errors, warnings, failures, stack frames and `path.ext:line` references.
    public static func isDiagnostic(_ line: String) -> Bool {
        diagnosticPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Each run of digits becomes one `#`, so "9/50" and "10/50" mask alike.
    static func maskDigits(_ s: String) -> String {
        var out = ""
        var inDigits = false
        for c in s.unicodeScalars {
            if CharacterSet.decimalDigits.contains(c) {
                if !inDigits { out.append("#") }
                inDigits = true
            } else {
                out.unicodeScalars.append(c); inDigits = false
            }
        }
        return out
    }
}

import Foundation
import Synchronization

/// Offline replay benchmark (ADR-034): what a deterministic output transform would have changed in recorded
/// Claude Code sessions, measured before the transform is built into anything. Pure — no file access, no network.
/// Only `Tools/replay` feeds it transcript lines; the app never calls it (ADR-023: the app reads usage, not content).
/// Nothing here is a saving: bytes are measured, tokens are `TokenEstimator` heuristics, and `calibrate` gives
/// bounds from provider-reported context growth.
public enum Replay {
    /// One text tool result exactly as the agent received it.
    public struct Sample: Hashable, Sendable {
        public var tool: String
        /// The Bash command; empty for other tools (their inputs are never needed).
        public var command: String
        public var output: Data
        public var isError: Bool
        /// Later API calls in the same session before the next compaction: how many times this output was re-read.
        public var carry: Int
        /// Compactions before this result in its session: results in different segments never refer to each other.
        public var segment: Int
        public init(tool: String = "Bash", command: String, output: Data, isError: Bool = false, carry: Int = 0, segment: Int = 0) {
            self.tool = tool; self.command = command; self.output = output; self.isError = isError; self.carry = carry; self.segment = segment
        }
    }

    /// A call whose next call added exactly one text tool result (any tool) and nothing else to the context.
    public struct CalibrationPair: Hashable, Sendable {
        public var model: String
        public var resultBytes: Int
        public var heuristicTokens: Int
        /// Provider-reported context of the next call minus this call's: the tool result plus this call's own turn.
        public var contextDelta: Int
        /// Provider-reported output tokens of this call (its tool_use turn is inside `contextDelta`).
        public var askingOutput: Int
    }

    public struct Session: Hashable, Sendable {
        public var samples: [Sample] = []
        public var pairs: [CalibrationPair] = []
        public var calls = 0
        public var compactions = 0
        /// Provider-reported usage of every API call, in order (last record per message id).
        public var usage: [CallUsage] = []
        /// Context of the last call before and the first call after each compaction (provider-reported).
        public var compactionContexts: [CompactionContext] = []
        public init() {}
    }

    public struct CallUsage: Hashable, Sendable {
        public var input = 0, cacheRead = 0, cacheCreation = 0, cacheCreation1h = 0, output = 0
        public var context: Int { input + cacheRead + cacheCreation }
        public init(input: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0, cacheCreation1h: Int = 0, output: Int = 0) {
            self.input = input; self.cacheRead = cacheRead; self.cacheCreation = cacheCreation; self.cacheCreation1h = cacheCreation1h; self.output = output
        }
    }

    public struct CompactionContext: Hashable, Sendable {
        public var before: Int
        public var after: Int
        /// Heuristic tokens of tool-result lines (≥ 40 chars) after this compaction, until the next one, that had already
        /// appeared before it in the session: a measured proxy for re-work (re-reading what was dropped). Coincidental
        /// repeats count too; re-done reasoning does not.
        public var rereadTokens = 0
        public init(before: Int, after: Int, rereadTokens: Int = 0) { self.before = before; self.after = after; self.rereadTokens = rereadTokens }
    }

    // MARK: Extraction

    /// One top-level transcript (`.jsonl` lines, in order) → its text tool results with their re-read count, and the
    /// calls usable for calibration. API calls are distinct assistant message ids (streamed records of one id
    /// count once, last usage wins); `<synthetic>` records are not calls. Unknown record types are metadata.
    public static func extract<S: Sequence>(lines: S) -> Session where S.Element: StringProtocol {
        var session = Session()
        var calls: [Call] = [], events: [Event] = [], tools: [String: (name: String, command: String)] = [:], boundaries: [Int] = []
        func dirty() { if !calls.isEmpty { calls[calls.count - 1].clean = false } }

        for line in lines {
            guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let message = root["message"] as? [String: Any]
            switch root["type"] as? String {
            case "assistant":
                guard let message, let id = message["id"] as? String, let model = message["model"] as? String, model != "<synthetic>" else { dirty(); continue }
                let usage = message["usage"] as? [String: Any] ?? [:]
                func n(_ key: String) -> Int { usage[key] as? Int ?? 0 }
                let u = CallUsage(input: n("input_tokens"), cacheRead: n("cache_read_input_tokens"), cacheCreation: n("cache_creation_input_tokens"),
                                  cacheCreation1h: (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0,
                                  output: n("output_tokens"))
                if calls.last?.id == id {
                    calls[calls.count - 1].usage = u
                } else {
                    calls.append(Call(id: id, model: model, usage: u)); events.append(.call)
                }
                for case let block as [String: Any] in message["content"] as? [Any] ?? [] where block["type"] as? String == "tool_use" {
                    guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                    tools[toolID] = (name, name == "Bash" ? (block["input"] as? [String: Any])?["command"] as? String ?? "" : "")
                }
            case "user":
                guard let content = message?["content"] as? [Any] else { dirty(); continue }
                for item in content {
                    guard let block = item as? [String: Any], block["type"] as? String == "tool_result" else { dirty(); continue }
                    let (text, textOnly) = resultText(block["content"])
                    if textOnly, !calls.isEmpty { calls[calls.count - 1].results.append(text) } else { dirty() }
                    if textOnly, let toolID = block["tool_use_id"] as? String, let tool = tools.removeValue(forKey: toolID) {
                        events.append(.sample(session.samples.count))
                        session.samples.append(Sample(tool: tool.name, command: tool.command, output: Data(text.utf8),
                                                      isError: block["is_error"] as? Bool ?? false, segment: session.compactions))
                    }
                }
            case "system":
                if root["subtype"] as? String == "compact_boundary" { events.append(.reset); session.compactions += 1; boundaries.append(calls.count) }
                dirty()
            case "attachment":
                dirty()
            default:
                continue   // titles, modes, snapshots, request blobs…: not part of the model's context
            }
        }

        var later = 0
        for event in events.reversed() {
            switch event {
            case .reset: later = 0
            case .call: later += 1
            case .sample(let i): session.samples[i].carry = later
            }
        }
        session.calls = calls.count
        session.usage = calls.map(\.usage)
        var seenBefore = Set<Substring>(), reread = [Int](repeating: 0, count: boundaries.count + 1)
        for segment in 0...boundaries.count {
            let lines = session.samples.filter { $0.segment == segment }.flatMap { String(decoding: $0.output, as: UTF8.self).split(separator: "\n") }.filter { $0.count >= 40 }
            if segment > 0 { reread[segment] = TokenEstimator.estimate(lines.filter(seenBefore.contains).joined(separator: "\n")).tokens }
            seenBefore.formUnion(lines)
        }
        session.compactionContexts = boundaries.enumerated().compactMap { n, k in
            k > 0 && k < calls.count ? CompactionContext(before: calls[k - 1].usage.context, after: calls[k].usage.context, rereadTokens: reread[n + 1]) : nil
        }
        for i in calls.indices.dropLast() where calls[i].clean && calls[i].results.count == 1
            && calls[i + 1].model == calls[i].model && calls[i + 1].usage.context > calls[i].usage.context {
            let text = calls[i].results[0]
            session.pairs.append(CalibrationPair(model: calls[i].model, resultBytes: text.utf8.count, heuristicTokens: TokenEstimator.estimate(text).tokens,
                                                 contextDelta: calls[i + 1].usage.context - calls[i].usage.context, askingOutput: calls[i].usage.output))
        }
        return session
    }

    private struct Call { var id, model: String; var usage: CallUsage; var results: [String] = []; var clean = true }
    private enum Event { case call, reset, sample(Int) }

    /// Text of a tool_result's `content` (a string, or text blocks joined by newlines) and whether it was text only.
    static func resultText(_ content: Any?) -> (String, Bool) {
        if let s = content as? String { return (s, true) }
        var texts: [String] = [], textOnly = true
        for case let block as [String: Any] in content as? [Any] ?? [] {
            if block["type"] as? String == "text", let t = block["text"] as? String { texts.append(t) } else { textOnly = false }
        }
        return (texts.joined(separator: "\n"), textOnly)
    }

    // MARK: Transforms and their contract

    /// A candidate output transform. Every transform is judged by `check` before its numbers count.
    public struct Transform: Sendable {
        public enum Fidelity: String, Sendable {
            case exact        // `restore` gives back the original bytes
            case normalized   // `restore` gives back `normalize(original)`; the normalization is declared, not hidden
            case lossy        // no inverse; every diagnostic line must still be shown
        }
        public var name: String
        public var fidelity: Fidelity
        public var apply: @Sendable (Data) -> Data
        public var restore: (@Sendable (Data) -> Data)?
        public var normalize: @Sendable (Data) -> Data
        public init(name: String, fidelity: Fidelity, apply: @escaping @Sendable (Data) -> Data,
                    restore: (@Sendable (Data) -> Data)? = nil, normalize: @escaping @Sendable (Data) -> Data = { $0 }) {
            self.name = name; self.fidelity = fidelity; self.apply = apply; self.restore = restore; self.normalize = normalize
        }
    }

    public enum Violation: String, Hashable, Sendable, CaseIterable {
        case nondeterministic        // the same input gave two different outputs
        case grew                    // the output is larger than the input
        case notRestorable           // exact/normalized: `restore(output)` is not the (normalized) original
        case normalizationDropsText  // normalized: the declared normalization lost visible text (e.g. `\r` redraws)
        case droppedDiagnostic       // an error/warning/`file:line` line of the (normalized) original is not shown
    }

    /// The original stays untouched next to what would be shown; violations say why the shown form cannot be trusted.
    public struct Outcome: Sendable {
        public let original: Data
        public let shown: Data
        public let violations: Set<Violation>
        /// Lines of the original that `looksDiagnostic` flags and that are absent from the shown text (after undoing
        /// lossless steps). Independent of the condenser's own classifier, deliberately over-matching: a comment
        /// containing "error" counts. 0 for an exact transform by construction.
        public let suspectDropped: Int
    }

    /// A broad, independent detector of lines a reader would not want to lose: error/warning/fatal/failed/exception/
    /// panic/traceback wording, `path:line[:col]`, exit-status wording, test failure markers.
    static let suspectPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(error|warning|fatal|failed|failure|exception|panic|traceback|assert|abort|segfault|timed? ?out|denied|not found|no such file|exit(ed)? (status|code)|✘|FAIL)\b|[A-Za-z0-9_./-]+\.[A-Za-z]{1,6}:\d+(:\d+)?"#)
    public static func looksDiagnostic(_ line: String) -> Bool {
        suspectPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    public static func check(_ t: Transform, _ original: Data) -> Outcome {
        let shown = t.apply(original)
        var v = Set<Violation>()
        var suspect = 0
        if t.apply(original) != shown { v.insert(.nondeterministic) }
        if shown.count > original.count { v.insert(.grew) }
        if shown != original {
            let reference = t.fidelity == .exact ? original : t.normalize(original)
            let restored = t.restore?(shown) ?? shown
            if t.fidelity != .lossy, restored != reference { v.insert(.notRestorable) }
            if t.fidelity == .normalized, visibleText(original) != visibleText(reference) { v.insert(.normalizationDropsText) }
            if let ref = String(data: reference, encoding: .utf8) {
                let shownLines = Set(String(decoding: restored, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false))
                if ref.split(separator: "\n").contains(where: { OutputCondenser.isDiagnostic(String($0)) && !shownLines.contains($0) }) {
                    v.insert(.droppedDiagnostic)
                }
                suspect = ref.split(separator: "\n").filter { looksDiagnostic(String($0)) && !shownLines.contains($0) }.count
            }
        }
        return Outcome(original: original, shown: shown, violations: v, suspectDropped: suspect)
    }

    /// Non-whitespace characters, sorted, after removing terminal escape sequences (CSI, OSC, other two-byte ESC)
    /// but not resolving `\r` or backspace: comparing two of these tells whether a normalization lost text.
    static func visibleText(_ data: Data) -> [Unicode.Scalar] {
        guard let text = String(data: data, encoding: .utf8) else { return Array(data).map { Unicode.Scalar($0) } }
        let plain = text.replacingOccurrences(of: #"\x{1B}(\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|.)"#, with: "", options: .regularExpression)
        return plain.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "\u{08}" }.sorted { $0.value < $1.value }
    }

    /// Exactly what the retired ADR-033 runner handed the agent (the runner itself was removed, ADR-034), kept as the
    /// baseline transform, with its declared normalization (escape/`\r` resolution, trailing whitespace, blank-line
    /// runs) and its inverse. Non-UTF-8 and diff-shaped output stay byte-for-byte; the condensed form only when smaller.
    public static let runnerLossless = Transform(
        name: "runner-lossless", fidelity: .normalized,
        apply: { raw in
            guard let text = String(data: raw, encoding: .utf8), !("\n" + text).contains("\ndiff --git "), !("\n" + text).contains("\n@@ ") else { return raw }
            let condensed = OutputCondenser.condense(text, options: .lossless)
            let candidate = Data((condensed.text + (text.hasSuffix("\n") ? "\n" : "")).utf8)
            return condensed.changed && candidate.count < raw.count ? candidate : raw
        },
        restore: { shown in
            guard let text = String(data: shown, encoding: .utf8) else { return shown }
            var lines = OutputCondenser.expandGroups(text)
            if lines.first?.hasPrefix("[c2d: condensed ") == true { lines.removeFirst() }
            return Data(OutputCondenser.expandRepeats(lines).joined(separator: "\n").utf8)
        },
        normalize: { raw in
            guard let text = String(data: raw, encoding: .utf8) else { return raw }
            var lines = ContextOptimizer.normalizeWhitespace(OutputCondenser.stripEscapes(text)).split(separator: "\n", omittingEmptySubsequences: false)
            while lines.last?.isEmpty == true { lines.removeLast() }
            return Data((lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")).utf8)
        })

    /// What the PostToolUse adapter would hand the agent (`TokenSaverHook`, ADR-035): `OutputCondenser.condenseExact`,
    /// byte-reversible by `expandExact`. Non-UTF-8 output is never changed.
    public static let exactFold = Transform(
        name: "exact-fold", fidelity: .exact,
        apply: { raw in String(data: raw, encoding: .utf8).flatMap(OutputCondenser.condenseExact).map { Data($0.utf8) } ?? raw },
        restore: { shown in String(data: shown, encoding: .utf8).map { Data(OutputCondenser.expandExact($0).utf8) } ?? shown })

    // MARK: Metrics

    /// Bytes are measured; tokens are heuristic (`TokenEstimator`, ±25 %); carried = tokens × `carry`. Never summed across kinds.
    public struct Metrics: Hashable, Sendable {
        public var samples = 0, changed = 0, errorSamples = 0, errorChanged = 0
        public var rawBytes = 0, shownBytes = 0
        public var rawTokens = 0, shownTokens = 0
        public var carriedRawTokens = 0, carriedShownTokens = 0
        public var violations: [Violation: Int] = [:]
        /// Independent-detector lines lost (see `Outcome.suspectDropped`) and the outputs they came from.
        public var suspectDropped = 0, outputsWithSuspectDropped = 0
        public init() {}

        mutating func add(_ s: Sample, _ o: Outcome) {
            let raw = TokenEstimator.estimate(String(decoding: s.output, as: UTF8.self)).tokens
            let shown = o.shown == s.output ? raw : TokenEstimator.estimate(String(decoding: o.shown, as: UTF8.self)).tokens
            samples += 1; rawBytes += s.output.count; shownBytes += o.shown.count; rawTokens += raw; shownTokens += shown
            carriedRawTokens += raw * s.carry; carriedShownTokens += shown * s.carry
            let changedHere = o.shown != s.output
            if changedHere { changed += 1 }
            if s.isError { errorSamples += 1; if changedHere { errorChanged += 1 } }
            for v in o.violations { violations[v, default: 0] += 1 }
            suspectDropped += o.suspectDropped; if o.suspectDropped > 0 { outputsWithSuspectDropped += 1 }
        }

        static func + (a: Metrics, b: Metrics) -> Metrics {
            var m = a
            m.samples += b.samples; m.changed += b.changed; m.errorSamples += b.errorSamples; m.errorChanged += b.errorChanged
            m.rawBytes += b.rawBytes; m.shownBytes += b.shownBytes; m.rawTokens += b.rawTokens; m.shownTokens += b.shownTokens
            m.carriedRawTokens += b.carriedRawTokens; m.carriedShownTokens += b.carriedShownTokens
            m.violations.merge(b.violations, uniquingKeysWith: +)
            m.suspectDropped += b.suspectDropped; m.outputsWithSuspectDropped += b.outputsWithSuspectDropped
            return m
        }
    }

    /// Runs `check` on every sample (in parallel; the sum does not depend on the order).
    public static func measure(_ t: Transform, on samples: [Sample]) -> Metrics {
        let total = Mutex(Metrics())
        let stripes = max(1, min(samples.count, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
            var m = Metrics()
            for i in stride(from: stripe, to: samples.count, by: stripes) { m.add(samples[i], check(t, samples[i].output)) }
            total.withLock { $0 = $0 + m }
        }
        return total.withLock { $0 }
    }

    // MARK: Repeated content (measurement only)

    /// Results identical, byte for byte, to an earlier result in the same session and compaction segment. Identity
    /// is the whole proof a reference would need: a changed file gives different bytes and is never counted. What a
    /// transcript cannot show is whether the CLI cleared the earlier result from context in between, so this is an
    /// upper bound on what a reference could save, never a saving.
    public struct RepeatMetrics: Hashable, Sendable {
        public var results = 0, carriedTokens = 0
        public var repeats = 0, repeatBytes = 0, repeatCarriedTokens = 0
        /// Re-read tokens saved after paying for the reference text itself on every re-read.
        public var netCarriedTokens = 0
        public var byTool: [String: Int] = [:]   // net carried tokens per tool
        public init() {}

        public static func + (a: RepeatMetrics, b: RepeatMetrics) -> RepeatMetrics {
            var m = a
            m.results += b.results; m.carriedTokens += b.carriedTokens; m.repeats += b.repeats; m.repeatBytes += b.repeatBytes
            m.repeatCarriedTokens += b.repeatCarriedTokens; m.netCarriedTokens += b.netCarriedTokens
            m.byTool.merge(b.byTool, uniquingKeysWith: +)
            return m
        }
    }

    /// What a reference would cost the agent instead of the content (a fixed-width example of the planned marker).
    static let referenceTokens = TokenEstimator.estimate("[c2d: identical to an earlier Bash result in this session: 123456 bytes, sha256 0123456789abcdef]").tokens

    public static func repeats(in session: Session, minimumBytes: Int = 1024) -> RepeatMetrics {
        var m = RepeatMetrics()
        var seen = Set<Data>(), segment = -1
        for s in session.samples {
            if s.segment != segment { seen.removeAll(); segment = s.segment }
            let tokens = TokenEstimator.estimate(String(decoding: s.output, as: UTF8.self)).tokens
            m.results += 1; m.carriedTokens += tokens * s.carry
            guard s.output.count >= minimumBytes else { continue }
            if seen.insert(s.output).inserted { continue }
            m.repeats += 1; m.repeatBytes += s.output.count; m.repeatCarriedTokens += tokens * s.carry
            let net = max(0, tokens - referenceTokens) * s.carry
            m.netCarriedTokens += net; m.byTool[s.tool, default: 0] += net
        }
        return m
    }

    // MARK: Cross-result line overlap (measurement only)

    /// Lines of a Bash result that already appeared, as a run of at least `window` consecutive lines, in an earlier
    /// Bash result of the same session segment (overlapping `sed -n` ranges, `cat` after an edit, a re-run build).
    /// Hash windows, so an upper bound with a negligible collision error. No transform does this: a reference would
    /// need per-session state, a reset on compaction, and proof that the earlier result is still in the context.
    public struct OverlapMetrics: Hashable, Sendable {
        public var results = 0, bytes = 0, carriedTokens = 0
        public var overlappingResults = 0, overlapBytes = 0, overlapCarriedTokens = 0
        /// Carried tokens saved after paying for one reference marker per overlapping result.
        public var netCarriedTokens = 0
        public var byFamily: [String: Int] = [:]   // overlap bytes per program
        public init() {}

        public static func + (a: OverlapMetrics, b: OverlapMetrics) -> OverlapMetrics {
            var m = a
            m.results += b.results; m.bytes += b.bytes; m.carriedTokens += b.carriedTokens
            m.overlappingResults += b.overlappingResults; m.overlapBytes += b.overlapBytes; m.overlapCarriedTokens += b.overlapCarriedTokens
            m.netCarriedTokens += b.netCarriedTokens
            m.byFamily.merge(b.byFamily, uniquingKeysWith: +)
            return m
        }
    }

    public static func overlap(in session: Session, window: Int = 10, minimumBytes: Int = 512) -> OverlapMetrics {
        var m = OverlapMetrics()
        var seen = Set<Int>(), segment = -1
        for s in session.samples where s.tool == "Bash" {
            if s.segment != segment { seen.removeAll(); segment = s.segment }
            let text = String(decoding: s.output, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            m.results += 1; m.bytes += s.output.count
            let tokens = TokenEstimator.estimate(text).tokens
            m.carriedTokens += tokens * s.carry
            guard s.output.count >= minimumBytes, lines.count >= window else { continue }
            var keys: [Int] = []
            keys.reserveCapacity(lines.count - window + 1)
            for i in 0...(lines.count - window) {
                var h = Hasher()
                for l in lines[i..<(i + window)] { h.combine(l) }
                keys.append(h.finalize())
            }
            var covered = [Bool](repeating: false, count: lines.count)
            for (i, k) in keys.enumerated() where seen.contains(k) {
                for j in i..<(i + window) { covered[j] = true }
            }
            seen.formUnion(keys)
            let coveredLines = zip(lines, covered).filter(\.1).map(\.0)
            guard !coveredLines.isEmpty else { continue }
            let bytes = coveredLines.reduce(0) { $0 + $1.utf8.count + 1 }
            let coveredTokens = TokenEstimator.estimate(coveredLines.joined(separator: "\n")).tokens
            m.overlappingResults += 1; m.overlapBytes += bytes; m.overlapCarriedTokens += coveredTokens * s.carry
            m.netCarriedTokens += max(0, coveredTokens - referenceTokens) * s.carry
            m.byFamily[family(of: s.command), default: 0] += bytes
        }
        return m
    }

    /// The condenser's opt-in lossy defaults (similar-line folding, long-line elision, middle truncation) as a
    /// replay candidate: a ceiling for "repetitive log" reduction, judged by `droppedDiagnostic` like every other.
    /// Not wired anywhere; lossy stays opt-in (TSD-08).
    public static let runnerDefault = lossy(name: "runner-default (opt-in lossy)", options: OutputCondenser.Options())
    /// The three lossy steps one at a time, so the ceiling can be attributed to the risky step (file-body
    /// truncation) and the lower-risk ones (counter-line folding, long-line elision).
    public static let lossySimilar = lossy(name: "lossy: similar-line folding only", options: .init(lineBudget: nil, longLine: nil))
    public static let lossyLongLines = lossy(name: "lossy: long-line elision only", options: .init(lineBudget: nil, similarRunMinimum: .max))
    public static let lossyTruncate = lossy(name: "lossy: head/tail truncation only", options: .init(similarRunMinimum: .max, longLine: nil))

    static func lossy(name: String, options: OutputCondenser.Options) -> Transform {
        Transform(name: name, fidelity: .lossy,
                  apply: { raw in
                      guard let text = String(data: raw, encoding: .utf8), !("\n" + text).contains("\ndiff --git "), !("\n" + text).contains("\n@@ ") else { return raw }
                      let condensed = OutputCondenser.condense(text, options: options)
                      let candidate = Data((condensed.text + (text.hasSuffix("\n") ? "\n" : "")).utf8)
                      return condensed.changed && candidate.count < raw.count ? candidate : raw
                  },
                  restore: runnerLossless.restore,   // undoes only the lossless steps (groups, repeat markers) so dropped lines are judged on real lines
                  normalize: runnerLossless.normalize)
    }

    // MARK: Session restarts (model, not a measurement)

    /// Relative price weights per token, input = 1. Defaults are Anthropic's published multipliers (cache read 0.1×,
    /// 5-minute cache write 1.25×, 1-hour write 2×) and an output/input ratio of 5; an assumption, not this account's bill.
    public struct Weights: Hashable, Sendable {
        public var input = 1.0, cacheRead = 0.1, cacheWrite5m = 1.25, cacheWrite1h = 2.0, output = 5.0
        public init() {}
    }

    /// Restart when the next call's context would exceed `threshold`: the new session starts from the session's own
    /// first-call context (measured fixed overhead), plus a hand-off of `handoffTokens` (written by the model, charged
    /// as output), plus `reworkShare` of the history it shed (re-reading files, re-running commands), plus
    /// `extraCalls` calls at that size to do the re-work. The last three are assumptions; the transcript cannot show them.
    public struct RestartPolicy: Hashable, Sendable {
        public var threshold: Int, handoffTokens: Int, reworkShare: Double, extraCalls: Int
        public init(threshold: Int, handoffTokens: Int, reworkShare: Double, extraCalls: Int) {
            self.threshold = threshold; self.handoffTokens = handoffTokens; self.reworkShare = reworkShare; self.extraCalls = extraCalls
        }
    }

    public struct SessionCost: Hashable, Sendable {
        public var context = 0, cacheRead = 0, cacheWrite = 0, input = 0, output = 0, restarts = 0
        public var weighted = 0.0
        public init() {}
        public static func + (a: SessionCost, b: SessionCost) -> SessionCost {
            var c = a
            c.context += b.context; c.cacheRead += b.cacheRead; c.cacheWrite += b.cacheWrite; c.input += b.input; c.output += b.output
            c.restarts += b.restarts; c.weighted += b.weighted
            return c
        }
    }

    /// The session as recorded, priced with `weights` (policy nil), or the same calls replayed under `policy`. Each call
    /// keeps its own new tokens (fresh input + cache writes) and output; only the carried history changes. A recorded
    /// full cache miss (fresh ≥ context) stays a full miss of the shorter context.
    public static func cost(_ calls: [CallUsage], policy: RestartPolicy? = nil, weights w: Weights = Weights()) -> SessionCost {
        var c = SessionCost()
        guard let base = calls.first?.context else { return c }
        func charge(read: Int, write: Int, write1hShare: Double, input: Int, output: Int) {
            c.context += read + write + input; c.cacheRead += read; c.cacheWrite += write; c.input += input; c.output += output
            c.weighted += Double(read) * w.cacheRead + Double(input) * w.input + Double(output) * w.output
                + Double(write) * (write1hShare * w.cacheWrite1h + (1 - write1hShare) * w.cacheWrite5m)
        }
        var offset = 0
        for (i, u) in calls.enumerated() {
            let share = u.cacheCreation == 0 ? 0 : Double(u.cacheCreation1h) / Double(u.cacheCreation)
            var context = u.context - offset
            if offset > 0, context < base { offset = 0; context = u.context }   // the recording itself compacted: both arms restart here
            var fresh = min(u.input + u.cacheCreation, context)
            let carried = policy.map { base + $0.handoffTokens + Int($0.reworkShare * Double(max(0, context - base))) } ?? 0
            if let p = policy, i > 0, context > p.threshold, carried < p.threshold {   // a restart that cannot get under the threshold is not made
                c.restarts += 1
                charge(read: 0, write: 0, write1hShare: share, input: 0, output: p.handoffTokens)
                for _ in 0..<p.extraCalls { charge(read: carried, write: 0, write1hShare: share, input: 0, output: 0) }
                offset = u.context - carried
                context = carried
                fresh = max(min(u.input + u.cacheCreation, context), context - base)   // the new prefix beyond the base is written once
            }
            let input = min(u.input, fresh)
            charge(read: context - fresh, write: fresh - input, write1hShare: share, input: input, output: u.output)
        }
        return c
    }

    /// The re-work share at which `policy` (with its threshold, hand-off and extra calls) stops being cheaper than the
    /// recording, by weighted cost: nil when even zero re-work is not cheaper. Bisection; cost grows with re-work.
    public static func breakEvenRework(_ sessions: [[CallUsage]], policy: RestartPolicy, weights: Weights = Weights()) -> Double? {
        let recorded = sessions.reduce(0.0) { $0 + cost($1, weights: weights).weighted }
        func simulated(_ share: Double) -> Double {
            var p = policy; p.reworkShare = share
            return sessions.reduce(0.0) { $0 + cost($1, policy: p, weights: weights).weighted }
        }
        guard simulated(0) < recorded else { return nil }
        if simulated(1) < recorded { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 { let mid = (lo + hi) / 2; if simulated(mid) < recorded { lo = mid } else { hi = mid } }
        return lo
    }

    // MARK: Reach and labels

    /// The command without the wrappers agents add most (`cd <dir> &&`, `2>/dev/null`, a final `2>&1`,
    /// `| head`/`| tail`). Only used to ask whether a wider grammar would reach more output.
    public static func unwrapped(_ command: String) -> String {
        var c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, replacement) in [(#"^(cd\s+[^;&|]+?\s*&&\s*)+"#, ""), (#"\s*2>&1\s*$"#, ""), (#"\s*2>\s*/dev/null"#, ""),
                                       (#"\s*\|\s*(head|tail)(\s+-n?\s*\d+|\s+-\d+)?\s*$"#, "")] {
            c = c.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return c
    }

    /// A grouping label that cannot leak a path or argument: the program name (plus the subcommand for
    /// git/swift/npm/npx), or "other".
    public static func family(of command: String) -> String {
        let words = unwrapped(command).split(whereSeparator: \.isWhitespace).map(String.init).drop { $0.contains("=") }
        func plain(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }), plain(program, #"^[A-Za-z0-9._+-]{1,24}$"#) else { return "other" }
        let rest = Array(words.dropFirst())
        if ["git", "swift", "npm", "npx"].contains(program), let sub = rest.first, plain(sub, #"^[a-z][a-z-]{0,15}$"#) { return program + " " + sub }
        return program
    }

    // MARK: Calibration

    /// Bytes per provider token, per model, from calls that added exactly one text tool result of at least
    /// `minimumBytes`. Context growth also carries the asking turn, so `bytesPerTokenAtLeast` is a lower bound
    /// (unless the CLI dropped context between the two calls, which a transcript cannot show).
    public struct Calibration: Hashable, Sendable {
        public var model: String
        public var pairs: Int
        public var bytesPerTokenAtLeast: Double
        /// With the asking call's output tokens subtracted; overstates when that turn's thinking is not re-sent.
        public var bytesPerTokenAdjusted: Double?
        /// Median heuristic tokens ÷ context growth. Above 1 means the heuristic counts more than the provider did.
        public var heuristicOverGrowth: Double
    }

    public static func calibrate(_ pairs: [CalibrationPair], minimumBytes: Int = 4096) -> [Calibration] {
        Dictionary(grouping: pairs.filter { $0.resultBytes >= minimumBytes }, by: \.model).map { model, ps in
            let adjusted = ps.filter { $0.contextDelta > $0.askingOutput }.map { Double($0.resultBytes) / Double($0.contextDelta - $0.askingOutput) }
            return Calibration(model: model, pairs: ps.count,
                               bytesPerTokenAtLeast: median(ps.map { Double($0.resultBytes) / Double($0.contextDelta) }),
                               bytesPerTokenAdjusted: adjusted.isEmpty ? nil : median(adjusted),
                               heuristicOverGrowth: median(ps.map { Double($0.heuristicTokens) / Double($0.contextDelta) }))
        }.sorted { $0.model < $1.model }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

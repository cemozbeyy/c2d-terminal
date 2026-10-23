// Offline replay benchmark (ADR-034): what a Token Saver transform would have changed in this Mac's recorded
// Claude Code sessions, judged by `Replay.check` before any number counts. Reads `<claude home>/projects/*/*.jsonl`
// read-only and prints aggregate numbers only — no command, path or output text is printed or written. No network,
// no model calls. Exclude the session you are running in, or it measures itself.
//
//   swift run -c release --package-path Tools/replay replay [--exclude <session-id>]... [--claude-home <dir>] [--families] [--json <file>]
//
// `--json` writes the same aggregates machine-readably (counts and ratios only).
import C2DCore
import Foundation
import Synchronization

var home = ClaudeTranscriptReader.defaultClaudeHome()
var excluded = Set<String>()
var showFamilies = false
var jsonOut: URL?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch (arg, args.first) {
    case ("--claude-home", let v?): home = URL(fileURLWithPath: v); args.removeFirst()
    case ("--exclude", let v?): excluded.insert(v); args.removeFirst()
    case ("--families", _): showFamilies = true
    case ("--json", let v?): jsonOut = URL(fileURLWithPath: v); args.removeFirst()
    default:
        FileHandle.standardError.write(Data("usage: replay [--exclude <session-id>]... [--claude-home <dir>] [--families] [--json <file>]\n".utf8))
        exit(2)
    }
}

let started = Date()
let fm = FileManager.default
let projects = home.appendingPathComponent("projects")
var found: [URL] = []
for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
        if !excluded.contains(f.deletingPathExtension().lastPathComponent) { found.append(f) }
    }
}
let files = found.sorted { $0.path < $1.path }
guard !files.isEmpty else { print("No transcripts under \(projects.path)."); exit(1) }

let parsed = Mutex([Replay.Session?](repeating: nil, count: files.count))
DispatchQueue.concurrentPerform(iterations: files.count) { i in
    guard let data = try? Data(contentsOf: files[i]) else { return }
    let session = Replay.extract(lines: String(decoding: data, as: UTF8.self).split(separator: "\n"))
    parsed.withLock { $0[i] = session }
}
let sessions = parsed.withLock { $0.compactMap { $0 } }
let samples = sessions.flatMap(\.samples).filter { $0.tool == "Bash" }
let transforms = [Replay.runnerLossless, Replay.exactFold, Replay.runnerDefault, Replay.lossySimilar, Replay.lossyLongLines, Replay.lossyTruncate]
let results = transforms.map { Replay.measure($0, on: samples) }
let repeats = sessions.map { Replay.repeats(in: $0) }.reduce(Replay.RepeatMetrics(), +)
let overlap = sessions.map { Replay.overlap(in: $0) }.reduce(Replay.OverlapMetrics(), +)
// What Claude Code itself already keeps away from the model: results it moved to a file (a preview stays), and how
// large the largest result that still reached the model in full was. Bounds any "large output" optimization.
let persistedSamples = samples.filter { $0.output.range(of: Data("<persisted-output>".utf8)) != nil }
let persistedBytes = persistedSamples.reduce(0) { $0 + $1.output.count }
let largestInline = samples.filter { $0.output.range(of: Data("<persisted-output>".utf8)) == nil }.map(\.output.count).max() ?? 0
let over32k = samples.filter { $0.output.count > 32_768 }

func pct(_ part: Int, _ whole: Int) -> String { whole == 0 ? "—" : String(format: "%.2f %%", 100 * Double(part) / Double(whole)) }
func reduction(_ before: Int, _ after: Int) -> String { "\(before.formatted()) → \(after.formatted())  (−\(pct(before - after, before)))" }
let bashBytes = samples.reduce(0) { $0 + $1.output.count }
let errorBytes = samples.filter(\.isError).reduce(0) { $0 + $1.output.count }
/// The R&D report's E3 grammar (the retired runner's allowlist before ADR-034 hardened and then removed it): no shell operator, and the program is
/// ls/grep/rg/find/tree or `git status`/`git log`. Kept only to compare with the report's reference numbers.
func reportE3(_ command: String) -> Bool {
    let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !c.isEmpty, c.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`\\\n\r(){}")) == nil else { return false }
    let w = c.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    return ["ls", "grep", "rg", "find", "tree"].contains(w[0]) || (w[0] == "git" && w.count > 1 && ["status", "log"].contains(w[1]))
}
let e3Strict = samples.filter { reportE3($0.command) }.reduce(0) { $0 + $1.output.count }
let e3Relaxed = samples.filter { reportE3(Replay.unwrapped($0.command)) }.reduce(0) { $0 + $1.output.count }

print("""
Replay (offline; bytes measured, tokens heuristic ±25 %, never combined)
Dataset      \(sessions.count) transcripts (\(excluded.count) excluded), \(sessions.reduce(0) { $0 + $1.calls }.formatted()) API calls, \
\(sessions.reduce(0) { $0 + $1.compactions }) compactions
Bash         \(samples.count.formatted()) results, \(bashBytes.formatted()) bytes; is_error: \(samples.filter(\.isError).count) results, \(errorBytes.formatted()) bytes
Reach        retired runner's allowlist (report E3 grammar): \(pct(e3Strict, bashBytes)) of Bash output bytes, \(pct(e3Relaxed, bashBytes)) with cd/2>/head/tail wrappers removed
""")
for (t, m) in zip(transforms, results) {
    print("""

    Transform \(t.name) (\(t.fidelity.rawValue)) on every Bash result — an upper bound; nothing is active
      Bytes      \(reduction(m.rawBytes, m.shownBytes))   measured
      Tokens     \(reduction(m.rawTokens, m.shownTokens))   heuristic
      Re-read    \(reduction(m.carriedRawTokens, m.carriedShownTokens))   heuristic tokens × later calls before compaction
      Changed    \(m.changed.formatted()) of \(m.samples.formatted()) outputs; error outputs changed: \(m.errorChanged) of \(m.errorSamples)
      Contract   \(Replay.Violation.allCases.map { "\($0.rawValue) \(m.violations[$0, default: 0])" }.joined(separator: ", "))
      Suspect    \(m.suspectDropped.formatted()) lines flagged by the independent detector (error/warning/failed/path:line…, over-matching) are missing from \(m.outputsWithSuspectDropped.formatted()) outputs
    """)
}
print("""

Repeats      text tool results (all tools) ≥ 1 KB identical to an earlier one in the same session segment — an upper bound
  \(repeats.repeats.formatted()) of \(repeats.results.formatted()) results, \(repeats.repeatBytes.formatted()) bytes
  Re-read    \(repeats.repeatCarriedTokens.formatted()) of \(repeats.carriedTokens.formatted()) heuristic re-read tokens (\(pct(repeats.repeatCarriedTokens, repeats.carriedTokens))); \
net of the reference text \(repeats.netCarriedTokens.formatted()) (\(pct(repeats.netCarriedTokens, repeats.carriedTokens)))
  By tool    \(repeats.byTool.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(pct($0.value, repeats.carriedTokens))" }.joined(separator: ", "))
""")

print("""

Overlap      Bash result lines already seen as a run of ≥ 10 lines in an earlier Bash result of the same segment (hashed windows; upper bound)
  \(overlap.overlappingResults.formatted()) of \(overlap.results.formatted()) results, \(overlap.overlapBytes.formatted()) of \(overlap.bytes.formatted()) bytes (\(pct(overlap.overlapBytes, overlap.bytes)))   measured
  Re-read    \(overlap.overlapCarriedTokens.formatted()) of \(overlap.carriedTokens.formatted()) heuristic re-read tokens (\(pct(overlap.overlapCarriedTokens, overlap.carriedTokens))); \
net of one reference marker per result \(overlap.netCarriedTokens.formatted()) (\(pct(overlap.netCarriedTokens, overlap.carriedTokens)))
  By program \(overlap.byFamily.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \(pct($0.value, overlap.overlapBytes))" }.joined(separator: ", "))
  No transform does this: it needs per-session state, a reset on compaction and proof the earlier result is still in context.

Persisted    Bash results Claude Code moved to a file itself (a preview reached the model): \(persistedSamples.count) results, \(persistedBytes.formatted()) bytes as shown
             largest result that reached the model in full: \(largestInline.formatted()) bytes; results over 32 KiB: \(over32k.count) (\(pct(over32k.reduce(0) { $0 + $1.output.count }, bashBytes)) of Bash bytes)
""")

// Session restarts: measured facts first, then a model whose assumptions are printed with it.
let usages = sessions.map(\.usage).filter { !$0.isEmpty }
let recorded = usages.map { Replay.cost($0) }.reduce(Replay.SessionCost(), +)
let allCalls = usages.flatMap { $0 }
let compactionsSeen = sessions.flatMap(\.compactionContexts)
func median(_ xs: [Int]) -> Int { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
let thresholds = [100_000, 150_000, 250_000, 400_000]
print("""

Sessions     measured (provider-reported): \(usages.count) sessions, \(allCalls.count.formatted()) calls, context re-sent \(recorded.context.formatted()) tokens
             cache reads \(pct(recorded.cacheRead, recorded.context)), cache writes \(pct(recorded.cacheWrite, recorded.context)), fresh input \(pct(recorded.input, recorded.context)); \
output \(recorded.output.formatted())
             context per call: median \(median(allCalls.map(\.context)).formatted()), first call of a session median \(median(usages.map { $0[0].context }).formatted())
             calls above \(thresholds.map { t in "\(t / 1000)k: \(pct(allCalls.filter { $0.context > t }.count, allCalls.count))" }.joined(separator: ", "))
             compactions observed: \(compactionsSeen.count); context before median \(median(compactionsSeen.map(\.before)).formatted()), after median \(median(compactionsSeen.map(\.after)).formatted())
             re-read after them (proxy for re-work): \(compactionsSeen.map(\.rereadTokens).reduce(0, +).formatted()) heuristic tokens = \
\(pct(compactionsSeen.map(\.rereadTokens).reduce(0, +), compactionsSeen.map { $0.before - $0.after }.reduce(0, +))) of the context they dropped; \
per compaction median \(pct(median(compactionsSeen.map { $0.before > $0.after ? $0.rereadTokens * 10_000 / ($0.before - $0.after) : 0 }), 10_000))
Restart model  NOT a measurement. Assumed: hand-off size, re-work share of the shed history, 5 extra calls per restart, price weights
             (input 1, cache read 0.1, write 1.25/2.0, output 5). Unmeasured: lost context, task failure, answer quality.
""")
var restartRows: [[String: Any]] = []
for t in thresholds {
    for h in [5_000, 20_000] {
        var cells: [String] = []
        for r in [0.0, 0.25, 0.5] {
            let p = Replay.RestartPolicy(threshold: t, handoffTokens: h, reworkShare: r, extraCalls: 5)
            let sim = usages.map { Replay.cost($0, policy: p) }.reduce(Replay.SessionCost(), +)
            let change = (sim.weighted - recorded.weighted) / recorded.weighted
            cells.append(String(format: "re-work %2.0f%%: weighted %+.1f%%", r * 100, change * 100))
            restartRows.append(["threshold": t, "handoff": h, "rework": r, "restarts": sim.restarts, "contextChange": Double(sim.context - recorded.context) / Double(recorded.context),
                                "weightedChange": change])
        }
        let even = Replay.breakEvenRework(usages, policy: .init(threshold: t, handoffTokens: h, reworkShare: 0, extraCalls: 5))
        let restarts = usages.map { Replay.cost($0, policy: .init(threshold: t, handoffTokens: h, reworkShare: 0, extraCalls: 5)) }.reduce(0) { $0 + $1.restarts }
        print("  >\(t / 1000)k, hand-off \(h / 1000)k: \(restarts) restarts; " + cells.joined(separator: "; ")
              + "; break-even re-work " + (even.map { String(format: "%.0f%%", $0 * 100) } ?? "none (never cheaper)"))
    }
}

let calibration = Replay.calibrate(sessions.flatMap(\.pairs))
print("\nCalibration  provider-reported context growth over calls that added one text tool result ≥ 4 KB and nothing else")
if calibration.isEmpty { print("             no usable pairs") }
for c in calibration {
    print("  \(c.model): \(c.pairs) pairs; bytes/token ≥ \(String(format: "%.2f", c.bytesPerTokenAtLeast)) (lower bound), "
          + "\(c.bytesPerTokenAdjusted.map { String(format: "%.2f", $0) } ?? "—") with the asking turn removed; "
          + "heuristic ÷ growth \(String(format: "%.2f", c.heuristicOverGrowth))")
}

if showFamilies {
    let columns = [Replay.exactFold, Replay.lossySimilar, Replay.lossyLongLines, Replay.lossyTruncate, Replay.runnerDefault]
    var byFamily: [String: (raw: Int, n: Int, saved: [Int])] = [:]
    for s in samples {
        let f = Replay.family(of: s.command)
        var e = byFamily[f] ?? (0, 0, [Int](repeating: 0, count: columns.count))
        e.raw += s.output.count; e.n += 1
        for (i, t) in columns.enumerated() { e.saved[i] += s.output.count - t.apply(s.output).count }
        byFamily[f] = e
    }
    print("\nBy program (bytes, measured; reduction per transform; top 12 by raw bytes)")
    print("  " + "program".padding(toLength: 16, withPad: " ", startingAt: 0) + "        bytes  results   exact  similar  longline truncate  lossy-all")
    for (name, v) in byFamily.sorted(by: { $0.value.raw > $1.value.raw }).prefix(12) {
        let cells = v.saved.map { String(format: "%7.2f%%", 100 * Double($0) / Double(max(1, v.raw))) }.joined(separator: " ")
        print("  \(name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(String(format: "%12d", v.raw)) \(String(format: "%8d", v.n)) \(cells)")
    }
}
let elapsed = Date().timeIntervalSince(started)
print(String(format: "\nElapsed      %.1f s", elapsed))

if let jsonOut {
    func ratio(_ part: Int, _ whole: Int) -> Double { whole == 0 ? 0 : Double(part) / Double(whole) }
    func metric(_ kind: String, _ before: Int, _ after: Int) -> [String: Any] { ["kind": kind, "before": before, "after": after, "reduction": ratio(before - after, before)] }
    let result: [String: Any] = [
        "generated": ISO8601DateFormatter().string(from: Date()), "elapsedSeconds": (elapsed * 10).rounded() / 10,
        "dataset": ["transcripts": sessions.count, "excluded": excluded.count, "apiCalls": sessions.reduce(0) { $0 + $1.calls },
                    "compactions": sessions.reduce(0) { $0 + $1.compactions }, "bashResults": samples.count, "bashBytes": bashBytes,
                    "errorResults": samples.filter(\.isError).count],
        "reach": ["reportE3": ratio(e3Strict, bashBytes), "reportE3Unwrapped": ratio(e3Relaxed, bashBytes)],
        // Per transform, three separate metrics, never combined.
        "transforms": zip(transforms, results).map { t, m in [
            "name": t.name, "fidelity": t.fidelity.rawValue,
            "bytes": metric("measured", m.rawBytes, m.shownBytes),
            "estimatedTokens": metric("heuristic ±25%", m.rawTokens, m.shownTokens),
            "rereadWeightedTokens": metric("heuristic tokens × later calls before compaction", m.carriedRawTokens, m.carriedShownTokens),
            "changedOutputs": m.changed, "changedErrorOutputs": m.errorChanged,
            "violations": Dictionary(uniqueKeysWithValues: Replay.Violation.allCases.map { ($0.rawValue, m.violations[$0, default: 0]) }),
            "suspectDroppedLines (independent detector, over-matching)": m.suspectDropped, "outputsWithSuspectDropped": m.outputsWithSuspectDropped,
        ] as [String: Any] },
        "overlap": ["kind": "upper bound, hashed 10-line windows, Bash only", "results": overlap.results, "bytes": overlap.bytes,
                    "overlappingResults": overlap.overlappingResults, "overlapBytes": overlap.overlapBytes, "overlapShare": ratio(overlap.overlapBytes, overlap.bytes),
                    "carriedTokens": overlap.carriedTokens, "overlapCarriedTokens": overlap.overlapCarriedTokens, "netCarriedTokens": overlap.netCarriedTokens,
                    "netShare": ratio(overlap.netCarriedTokens, overlap.carriedTokens), "overlapBytesByFamily": overlap.byFamily],
        "persisted": ["results": persistedSamples.count, "bytesShown": persistedBytes, "largestInlineBytes": largestInline, "resultsOver32KiB": over32k.count],
        "repeats": ["kind": "upper bound, heuristic re-read tokens", "results": repeats.results, "repeats": repeats.repeats,
                    "repeatBytes": repeats.repeatBytes, "carriedTokens": repeats.carriedTokens, "repeatCarriedTokens": repeats.repeatCarriedTokens,
                    "netCarriedTokens": repeats.netCarriedTokens, "netShare": ratio(repeats.netCarriedTokens, repeats.carriedTokens),
                    "netCarriedTokensByTool": repeats.byTool],
        "sessions": ["kind": "provider-reported", "sessions": usages.count, "calls": allCalls.count, "contextTokens": recorded.context,
                     "cacheRead": recorded.cacheRead, "cacheWrite": recorded.cacheWrite, "input": recorded.input, "output": recorded.output,
                     "compactions": compactionsSeen.map { ["before": $0.before, "after": $0.after, "rereadTokensHeuristic": $0.rereadTokens] }],
        "restartModel": ["kind": "model with assumptions (hand-off, re-work share, 5 extra calls, price weights); not a measurement", "rows": restartRows],
        "calibration": calibration.map { ["model": $0.model, "pairs": $0.pairs, "bytesPerTokenAtLeast": $0.bytesPerTokenAtLeast,
                                          "bytesPerTokenAdjusted": $0.bytesPerTokenAdjusted as Any, "heuristicOverGrowth": $0.heuristicOverGrowth] },
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: jsonOut, options: .atomic)
    print("Wrote \(jsonOut.path)")
}

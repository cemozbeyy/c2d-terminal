import C2DCore
import Foundation

// `PostToolUse` payload on stdin → `updatedToolOutput` response on stdout, or nothing (the CLI keeps the original).
// Always exits 0: a failed fold must never fail or block the tool call.
// Default: the byte-exact fold (ADR-035). `--lossy <similar|longline|truncate|all>`: the opt-in lossy condenser,
// for the owner's quality experiment only (hookcheck arm `c2d-lossy`); never used by any launch.
// `gain …`: the unified `c2d gain` report (plan C2D_GAIN_PLAN_2026-10-26). Reads the event store and, read-only, RTK's
// history; never a hook.
if CommandLine.arguments.dropFirst().first == "gain" {
    exit(await runGain(Array(CommandLine.arguments.dropFirst(2))))
}

var lossy: TokenSaverHook.LossyVariant?
var ledger: String?, project: String?   // `--ledger <optimizer.sqlite> --project <Claude project folder>`: record a `c2d gain` event
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    if arg == "--lossy", let v = args.popFirst(), let variant = TokenSaverHook.LossyVariant(rawValue: v) { lossy = variant }
    else if arg == "--ledger", let v = args.popFirst() { ledger = v }
    else if arg == "--project", let v = args.popFirst() { project = v }
    else { exit(0) }   // unknown argument: do nothing rather than guess (the CLI keeps the original output)
}
let clock = ContinuousClock(), started = clock.now
let result = TokenSaverHook.evaluate(payload: FileHandle.standardInput.readDataToEndOfFile(), lossy: lossy, project: project)
if let response = result.response { FileHandle.standardOutput.write(response) }
// The answer is out before the ledger is touched; a slow, locked or unwritable store only loses the event.
if let ledger, var event = result.event {
    event.helperMilliseconds = Int((clock.now - started) / .milliseconds(1))
    try? await OptimizationStore(path: ledger, busyTimeoutMilliseconds: 100).record(events: [event])
}
exit(0)

func runGain(_ arguments: [String]) async -> Int32 {
    let usage = "usage: c2d-token-helper gain [--global] [--history [N]] [--source live|replay] [--project <dir>] [--db <file>] [--rtk-db <file>] [--no-rtk]\n"
    var global = false, history: Int?, source = GainEvent.Source.live, includeRTK = true
    var projectDir = FileManager.default.currentDirectoryPath, dbPath: String?, rtkPath = RTKLedger.defaultPath()
    var rest = arguments[...]
    func value() -> String? { rest.popFirst() }
    while let arg = rest.popFirst() {
        switch arg {
        case "--global": global = true
        case "--no-rtk": includeRTK = false
        case "--history": history = rest.first.flatMap { Int($0) }.map { _ = rest.popFirst(); return $0 } ?? 20
        case "--source":
            guard let v = value(), let s = GainEvent.Source(rawValue: v) else { FileHandle.standardError.write(Data(usage.utf8)); return 2 }
            source = s
        case "--project", "--db", "--rtk-db":
            guard let v = value() else { FileHandle.standardError.write(Data(usage.utf8)); return 2 }
            if arg == "--project" { projectDir = v } else if arg == "--db" { dbPath = v } else { rtkPath = v }
        default: FileHandle.standardError.write(Data(usage.utf8)); return 2
        }
    }
    let root = URL(fileURLWithPath: projectDir).standardizedFileURL.path
    let folder = global ? nil : ClaudeTranscriptReader.projectFolderName(for: root)
    do {
        let store = try OptimizationStore(path: dbPath ?? OptimizationStore.standardPath())
        if let history {
            let events = try await store.events(source: source, project: folder, limit: history)
            print("Recent C2D \(source.rawValue) events, \(folder.map { "project \($0)" } ?? "all projects") (family only; command text is never stored)")
            if events.isEmpty { print("  (none)") }
            let time = DateFormatter(); time.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for e in events {
                let what = e.outcome == .emitted ? "transformed" : "skipped (\(e.skipReason?.rawValue ?? "?"))"
                print("  \(time.string(from: e.timestamp))  \(e.family.padding(toLength: 16, withPad: " ", startingAt: 0))  \(what)  \(e.originalStdoutBytes) → \(e.resultStdoutBytes) B")
            }
        } else if source == .replay {
            print(GainReport(events: try await store.events(source: .replay, project: folder), source: .replay, project: folder).render())
        } else {
            let rtk: RTKLedger.Result = includeRTK ? RTKLedger.read(path: rtkPath, projectPath: global ? nil : root) : .unavailable("left out (--no-rtk).")
            print(UnifiedGain(c2dEvents: try await store.events(source: .live, project: folder), rtk: rtk, projectPath: global ? nil : root).render())
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("c2d gain: \(error)\n".utf8))
        return 1
    }
}

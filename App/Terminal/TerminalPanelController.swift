import AppKit
import C2DCore
import Foundation
import Observation
import SwiftTerm

/// One terminal panel: owns its `PTYSession`, mirrors state into the session registry, and
/// bridges bytes to/from a SwiftTerm `TerminalView`. Panel identity is stable; session identity
/// changes every time a new shell is started (Bible Part 4 §6.2).
@MainActor
@Observable
final class TerminalPanelController: NSObject {
    let panelID: PanelID
    let projectPath: String
    /// When set, the panel hosts an agent CLI instead of the login shell (Bible Part 7 "managed mode").
    private(set) var agentPlan: AgentLaunchPlan?
    /// argv for the first session instead of the login shell (the Token Saver experiment runner). Used once: a later
    /// "New session" in this panel starts a plain shell, so a restart can never re-run the command.
    @ObservationIgnored private var oneShotCommand: (argv: [String], title: String)?
    private(set) var agentRecord: AgentSessionRecord?
    private(set) var record: TerminalSessionRecord?
    private(set) var state: PTYSessionState?
    /// True when a surface is attached and output is being fed.
    private(set) var attached = false
    /// Kernel-reported cwd / foreground command, refreshed while running (Bible Part 4 §5.2). nil = unknown.
    private(set) var context: PTYProcessContext?
    @ObservationIgnored private var contextTask: Task<Void, Never>?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var session: PTYSession?
    @ObservationIgnored private weak var surface: TerminalView?
    /// The panel owns its `TerminalView` (not SwiftUI), so switching away from this tab and back reuses
    /// the same surface with its scrollback and current screen intact — recreating it on every tab
    /// switch would leave the terminal blank until the next byte of output (closing a sibling tab).
    @ObservationIgnored var hostedView: TerminalView?
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    /// The grid SwiftTerm last reported (what the PTY is told); readable for the Debug resize check.
    @ObservationIgnored private(set) var lastGrid: (cols: Int, rows: Int) = (0, 0)
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    /// Output is read only after `start()` succeeded; reading an unstarted session would end the stream.
    @ObservationIgnored private var started = false

    init(panelID: PanelID, projectPath: String, app: AppModel, previousRecord: TerminalSessionRecord?,
         agentPlan: AgentLaunchPlan? = nil, previousAgentRecord: AgentSessionRecord? = nil, oneShotCommand: (argv: [String], title: String)? = nil) {
        self.panelID = panelID
        self.projectPath = projectPath
        self.app = app
        self.record = previousRecord
        self.agentPlan = agentPlan
        self.agentRecord = previousAgentRecord
        self.oneShotCommand = oneShotCommand
        super.init()
    }

    /// A restored agent panel learns its relaunch plan once provider discovery has finished.
    func adoptRestoredPlan(_ plan: AgentLaunchPlan) {
        guard agentPlan == nil, !isRunning else { return }
        agentPlan = plan
    }

    var isRunning: Bool {
        if case .running = state { return true }
        if case .terminating = state { return true }
        return false
    }

    var title: String {
        if let t = record?.userTitle, !t.isEmpty { return t }
        if let plan = agentPlan { return plan.provider.displayName }
        if let shell = record?.shell { return URL(fileURLWithPath: shell).lastPathComponent }
        return "Terminal"
    }

    var statusText: String {
        switch state {
        case .none:
            switch record?.lifecycle {
            case .endedByRestart: return "Ended when the app last quit"
            case .exited: return "Exited"
            case .startupFailed: return "Failed to start"
            default: return "No session"
            }
        case .created: return "Starting…"
        case .running(let pid): return "Running · pid \(pid)"
        case .terminating: return "Stopping…"
        case .exited(.exited(let code)): return code == 0 ? "Exited (0)" : "Exited with code \(code)"
        case .exited(.signaled(let sig)): return "Terminated by signal \(sig)"
        case .failed(let error): return "Failed: \(describe(error))"
        }
    }

    // MARK: Lifecycle

    /// Starts a fresh shell with a fresh session identity. Never reuses an old record.
    func startNewSession() {
        guard !isRunning else { return }
        let executable: String
        let arguments: [String]
        let directory: String
        let needsLoginPath = agentPlan != nil || oneShotCommand != nil
        let oneShotTitle = oneShotCommand?.title
        if let plan = agentPlan {
            executable = plan.executable
            arguments = plan.arguments
            directory = plan.workingDirectory
        } else if let command = oneShotCommand?.argv, let first = command.first {
            executable = first
            arguments = Array(command.dropFirst())
            directory = projectPath
            oneShotCommand = nil
        } else {
            do { executable = try PTYSessionConfiguration.loginShell() } catch {
                app.report("Login shell unavailable", "Could not read the login shell from the user database.")
                return
            }
            arguments = ["-l"]
            directory = projectPath
        }
        var env = PTYSessionConfiguration.inheritedEnvironment()
        // Agent CLIs need the login PATH (node, git, …) that a GUI-launched app does not inherit (Bible Part 7 §4).
        if needsLoginPath { let loginPath = AgentDiscovery.loginShellPath(); if !loginPath.isEmpty { env["PATH"] = loginPath } }
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "C2DTerminal"
        env["TERM_PROGRAM_VERSION"] = app.diagnostics.appVersion
        for (k, v) in agentPlan?.environmentAdditions ?? [:] { env[k] = v }
        let size = lastGrid.cols > 0 ? TerminalSize(rows: UInt16(lastGrid.rows), columns: UInt16(lastGrid.cols)) : TerminalSize(rows: 24, columns: 80)
        let config = PTYSessionConfiguration(executable: executable, arguments: arguments, environment: env,
                                             workingDirectory: directory, initialSize: size)
        var rec = TerminalSessionRecord(panelID: panelID, projectPath: projectPath, initialDirectory: directory, shell: executable)
        rec.userTitle = oneShotTitle
        if let plan = agentPlan {
            var a = AgentSessionRecord(providerID: plan.provider.id, panelID: panelID, projectPath: projectPath, workingDirectory: directory)
            a.terminalSessionID = rec.id
            a.taskSummary = plan.task
            a.providerSessionID = plan.providerSessionID   // TS-2: the only link between this launch and its transcript
            agentRecord = a
            app.registerAgentSession(a)
        }
        let session = PTYSession(configuration: config)
        self.session = session
        self.started = false
        feedTask?.cancel(); feedTask = nil
        stateTask?.cancel()
        state = .created
        record = rec
        app.registerSession(rec)
        observe(session)
        Task { [weak self] in
            do {
                try await session.start()
                guard let self else { return }
                self.started = true
                if self.surface != nil { self.startFeeding() }
            } catch {
                // `observe` already mirrored `.failed` into the registry.
                Log.pty.error("session start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func observe(_ session: PTYSession) {
        stateTask = Task { [weak self] in
            for await s in session.stateChanges {
                guard let self else { return }
                self.state = s
                guard let id = self.record?.id else { continue }
                let agentID = self.agentRecord?.id
                switch s {
                case .running(let pid):
                    self.pollContext(session)
                    self.app.updateSession(id) { $0.lifecycle = .running; $0.pid = pid }
                    self.record?.lifecycle = .running; self.record?.pid = pid
                    if let agentID { self.app.updateAgentSession(agentID) { $0.lifecycle = .running }; self.agentRecord?.lifecycle = .running }
                case .exited(let status):
                    self.contextTask?.cancel(); self.contextTask = nil; self.context = nil
                    self.app.updateSession(id) {
                        $0.lifecycle = .exited; $0.endedAt = Date(); $0.pid = nil
                        if case .exited(let c) = status { $0.exitCode = c }
                        if case .signaled(let g) = status { $0.signal = g }
                    }
                    self.record = self.app.sessions.record(id)
                    if let sid = self.agentPlan?.providerSessionID {   // the pet stops tracking an agent that ended
                        try? FileManager.default.removeItem(at: AgentActivity.stateFile(sessionID: sid))
                    }
                    if let agentID {
                        self.app.updateAgentSession(agentID) { $0.lifecycle = .exited; $0.endedAt = Date(); if case .exited(let c) = status { $0.exitCode = c } }
                        self.agentRecord = self.app.agentSessions.record(agentID)
                    }
                case .failed(let error):
                    self.app.updateSession(id) { $0.lifecycle = .startupFailed; $0.failureDescription = self.describe(error); $0.endedAt = Date() }
                    self.record = self.app.sessions.record(id)
                    if let agentID {
                        self.app.updateAgentSession(agentID) { $0.lifecycle = .failed; $0.failureDescription = self.describe(error); $0.endedAt = Date() }
                        self.agentRecord = self.app.agentSessions.record(agentID)
                    }
                default: break
                }
            }
        }
    }

    private func pollContext(_ session: PTYSession) {
        contextTask?.cancel()
        contextTask = Task { [weak self] in
            while !Task.isCancelled {
                let ctx = await session.processContext()
                guard let self, !Task.isCancelled else { return }
                if ctx != self.context { self.context = ctx }
                try? await Task.sleep(for: .milliseconds(1500))   // ponytail: polling; shell integration (OSC 7) if latency matters
            }
        }
    }

    /// Current directory for display: "~" for home, "." for the project root, "./sub" inside it.
    var displayDirectory: String? {
        guard let dir = context?.currentDirectory else { return nil }
        // The kernel reports symlinks resolved (/private/tmp/…); Foundation's resolvingSymlinksInPath
        // strips /private again, so use realpath(3) for the roots.
        func real(_ p: String) -> String { guard let r = realpath(p, nil) else { return p }; defer { free(r) }; return String(cString: r) }
        let project = real(projectPath), home = real(NSHomeDirectory())
        if dir == project { return "." }
        if dir.hasPrefix(project + "/") { return "./" + dir.dropFirst(project.count + 1) }
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~/" + dir.dropFirst(home.count + 1) }
        return dir
    }

    /// Directory a detected link's relative path is resolved against: the live cwd if known, else the
    /// session's starting directory, else the project root.
    var resolutionDirectory: String {
        context?.currentDirectory ?? agentRecord?.workingDirectory ?? record?.initialDirectory ?? projectPath
    }

    /// Handles a path/URL that the terminal engine detected under a Cmd-click (Bible Part 5 §7.3).
    /// A real URL opens with the system handler; a path that resolves to an existing file opens in the
    /// C2D editor at its line/column; anything else reports a message and opens nothing.
    /// Returns a short outcome string for runtime checks.
    @discardableResult
    func handleOpenLink(_ link: String) -> String {
        let schemes: Set<String> = ["http", "https", "mailto", "ftp", "ssh"]
        if let url = URL(string: link), let scheme = url.scheme, schemes.contains(scheme) {
            NSWorkspace.shared.open(url)
            return "url:\(scheme)"
        }
        guard let resolved = FileReference.resolve(link, relativeTo: resolutionDirectory) else {
            app.report("Could not open \(link)", "No file matched that path under \(resolutionDirectory).")
            return "unresolved"
        }
        app.workspace?.openFile(path: resolved.path, line: resolved.line, column: resolved.column)
        return "opened:\(resolved.path):\(resolved.line ?? 0):\(resolved.column ?? 0)"
    }

    func attach(_ view: TerminalView) {
        surface = view
        attached = true
        feedTask?.cancel(); feedTask = nil   // a new surface needs its own feed, even if an old one existed
        if started { startFeeding() }
    }

    func detach() {
        feedTask?.cancel()
        feedTask = nil
        surface = nil
        attached = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        hostedView = nil
    }

    private func startFeeding() {
        guard feedTask == nil, let session, let surface else { return }
        feedTask = Task { [weak self, weak surface] in
            #if DEBUG
            // `-c2dPtyDump <file>` appends every raw byte an agent panel receives (rendering forensics).
            let dump = self?.agentPlan != nil ? UserDefaults.standard.string(forKey: "c2dPtyDump").flatMap { FileHandle(forWritingAtPath: $0) ?? { FileManager.default.createFile(atPath: $0, contents: nil); return FileHandle(forWritingAtPath: $0) }($0) } : nil
            dump?.seekToEndOfFile()
            #endif
            for await chunk in session.output {
                guard !Task.isCancelled, let surface else { return }
                #if DEBUG
                dump?.write(Data(chunk))
                #endif
                surface.feed(byteArray: ArraySlice(chunk))
            }
            _ = self
        }
    }

    func write(_ data: Data) {
        guard let session else { return }
        Task {
            do { try await session.write(data) } catch { Log.pty.error("write failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Set while a second Ctrl-C would end the shell; the panel header shows a hint meanwhile.
    private(set) var interruptArmedUntil: Date?

    /// Ctrl-C in a shell panel. The ^C byte is always sent at once: zsh's line editor aborts the current
    /// input line (so a half-typed command is cleared). When the prompt is idle, the first press also
    /// arms for 2 s and shows a hint; a second press within that window ends the shell with `exit`, the
    /// way Claude Code quits on a double Ctrl-C. Busy/idle comes from the cached process context, so a
    /// running command is never mistaken for an idle prompt and double-^C cannot close the shell while a
    /// command is running. The ^C byte also reaches the line discipline, which sends SIGINT to the
    /// foreground group (the child owns the PTY as controlling tty since the ADR-010 amendment).
    /// Returns false for agent panels and panels without a session, which keep SwiftTerm's behaviour.
    func interrupt() -> Bool {
        guard agentPlan == nil, session != nil else { return false }
        let busy = context?.foregroundCommand != nil
        let wasArmed = interruptArmedUntil.map { Date() < $0 } ?? false
        interruptArmedUntil = nil
        write(Data([0x03]))
        guard !busy else { return true }   // a command is running: pass ^C through, never arm-to-close
        if wasArmed { write(Data("exit\n".utf8)); return true }   // second ^C at an idle prompt → close
        let until = Date().addingTimeInterval(2)
        interruptArmedUntil = until
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.interruptArmedUntil == until { self?.interruptArmedUntil = nil }
        }
        return true
    }

    func disarmInterrupt() { interruptArmedUntil = nil }

    func gridChanged(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastGrid = (cols, rows)
        debugTrace("grid \(cols)x\(rows) view=\(Int(hostedView?.frame.width ?? 0)) visible=\(Int(hostedView?.visibleRect.width ?? 0))")
        guard let session else { return }
        // A live window/divider drag fires a size change per frame. Forwarding each one makes a TUI
        // (Claude Code's ink renderer) repaint on every SIGWINCH and leave stale rows and torn lines
        // behind. Coalesce: only a grid that holds for 80 ms reaches the PTY, so the program redraws
        // once at the settled size. A single programmatic resize still lands, just 80 ms later.
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let grid = self?.lastGrid else { return }
            do { try await session.resize(TerminalSize(rows: UInt16(grid.rows), columns: UInt16(grid.cols))); debugTrace("pty resized \(grid.cols)x\(grid.rows)") }
            catch { debugTrace("pty resize failed: \(error)") }
        }
    }

    func terminate() async {
        guard let session else { return }
        await session.terminate(gracePeriod: .seconds(2))
    }

    func terminateAndClose() async {
        await terminate()
        detach()
        await session?.close()
        session = nil
    }

    func rename(_ title: String) {
        guard let id = record?.id else { return }
        record?.userTitle = title
        app.updateSession(id) { $0.userTitle = title }
    }

    func describe(_ error: PTYError) -> String {
        switch error {
        case .invalidExecutable(let p): "shell not executable: \(p)"
        case .invalidWorkingDirectory(let p): "directory unavailable: \(p)"
        case .spawnFailed(let e): "spawn failed (errno \(e))"
        case .ptyAllocationFailed(let step, let e): "PTY allocation failed at \(step) (errno \(e))"
        case .loginShellUnavailable: "login shell unavailable"
        default: "\(error)"
        }
    }

    // MARK: Buffer access for tests/diagnostics

    /// Whole active buffer (scrollback + screen), one line per row.
    func screenText() -> String {
        guard let surface else { return "" }
        return String(decoding: surface.getBufferAsData(), as: UTF8.self)
    }

    /// Scrollback evidence for runtime checks: buffer line count, whether a line equal to `marker`
    /// is still retained, and the scroll position after jumping to the top (0 = oldest line shown).
    func scrollbackProbe(marker: String) -> (lines: Int, retainsMarker: Bool, topPositionAfterScroll: Double)? {
        guard let surface else { return nil }
        let rows = screenText().split(separator: "\n", omittingEmptySubsequences: false)
        let retains = rows.contains { $0.trimmingCharacters(in: .whitespaces) == marker }
        surface.scrollTo(row: 0)
        return (rows.count, retains, surface.scrollPosition)
    }
}

extension TerminalPanelController: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // AppKit layout calls this on the main thread; applying it inline keeps the sizes in order.
        MainActor.assumeIsolated { self.gridChanged(cols: newCols, rows: newRows) }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        Task { @MainActor in self.write(d) }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        Task { @MainActor in self.handleOpenLink(link) }
    }
    nonisolated func bell(source: TerminalView) { Task { @MainActor in NSSound.beep() } }
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        Task { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
        }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    nonisolated func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    nonisolated func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    nonisolated func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    nonisolated func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

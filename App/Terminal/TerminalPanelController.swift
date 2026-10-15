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
    let agentPlan: AgentLaunchPlan?
    private(set) var agentRecord: AgentSessionRecord?
    private(set) var record: TerminalSessionRecord?
    private(set) var state: PTYSessionState?
    /// True when a surface is attached and output is being fed.
    private(set) var attached = false

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var session: PTYSession?
    @ObservationIgnored private weak var surface: TerminalView?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var lastGrid: (cols: Int, rows: Int) = (0, 0)
    /// Output is read only after `start()` succeeded; reading an unstarted session would end the stream.
    @ObservationIgnored private var started = false

    init(panelID: PanelID, projectPath: String, app: AppModel, previousRecord: TerminalSessionRecord?,
         agentPlan: AgentLaunchPlan? = nil, previousAgentRecord: AgentSessionRecord? = nil) {
        self.panelID = panelID
        self.projectPath = projectPath
        self.app = app
        self.record = previousRecord
        self.agentPlan = agentPlan
        self.agentRecord = previousAgentRecord
        super.init()
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
        if let plan = agentPlan {
            executable = plan.executable
            arguments = plan.arguments
            directory = plan.workingDirectory
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
        if agentPlan != nil { let loginPath = AgentDiscovery.loginShellPath(); if !loginPath.isEmpty { env["PATH"] = loginPath } }
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "C2DTerminal"
        env["TERM_PROGRAM_VERSION"] = app.diagnostics.appVersion
        for (k, v) in agentPlan?.environmentAdditions ?? [:] { env[k] = v }
        let size = lastGrid.cols > 0 ? TerminalSize(rows: UInt16(lastGrid.rows), columns: UInt16(lastGrid.cols)) : TerminalSize(rows: 24, columns: 80)
        let config = PTYSessionConfiguration(executable: executable, arguments: arguments, environment: env,
                                             workingDirectory: directory, initialSize: size)
        let rec = TerminalSessionRecord(panelID: panelID, projectPath: projectPath, initialDirectory: directory, shell: executable)
        if let plan = agentPlan {
            var a = AgentSessionRecord(providerID: plan.provider.id, panelID: panelID, projectPath: projectPath, workingDirectory: directory)
            a.terminalSessionID = rec.id
            a.taskSummary = plan.task
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
                    self.app.updateSession(id) { $0.lifecycle = .running; $0.pid = pid }
                    self.record?.lifecycle = .running; self.record?.pid = pid
                    if let agentID { self.app.updateAgentSession(agentID) { $0.lifecycle = .running }; self.agentRecord?.lifecycle = .running }
                case .exited(let status):
                    self.app.updateSession(id) {
                        $0.lifecycle = .exited; $0.endedAt = Date(); $0.pid = nil
                        if case .exited(let c) = status { $0.exitCode = c }
                        if case .signaled(let g) = status { $0.signal = g }
                    }
                    self.record = self.app.sessions.record(id)
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

    func attach(_ view: TerminalView) {
        surface = view
        attached = true
        if started { startFeeding() }
    }

    func detach() {
        feedTask?.cancel()
        feedTask = nil
        surface = nil
        attached = false
    }

    private func startFeeding() {
        guard feedTask == nil, let session, let surface else { return }
        feedTask = Task { [weak self, weak surface] in
            for await chunk in session.output {
                guard !Task.isCancelled, let surface else { return }
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

    func gridChanged(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastGrid = (cols, rows)
        guard let session else { return }
        Task { try? await session.resize(TerminalSize(rows: UInt16(rows), columns: UInt16(cols))) }
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

    func screenText() -> String {
        guard let surface else { return "" }
        return String(decoding: surface.getBufferAsData(), as: UTF8.self)
    }
}

extension TerminalPanelController: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in self.gridChanged(cols: newCols, rows: newRows) }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let d = Data(data)
        Task { @MainActor in self.write(d) }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
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

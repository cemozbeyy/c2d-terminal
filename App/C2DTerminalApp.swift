import AppKit
import C2DCore
import SwiftUI

@main
struct C2DTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        Log.app.info("launch: \(DiagnosticsReport.current().summary, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup("C2D Terminal") {
            MainWindowView()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    delegate.openTerminalWindow = { openWindow(id: "terminal", value: TerminalWindowRequest(directory: model.terminalWindowDirectory)) }
                    // C2D restores its own workspace; AppKit window restoration would resurrect stale
                    // windows from earlier launches (seen as blank 500×500 windows).
                    NSApp.windows.forEach { $0.isRestorable = false; $0.tabbingMode = .disallowed }   // terminal tabs never merge into the main window
                    #if DEBUG
                    // `-c2dTerminalWindowCheck YES`: two terminal windows become native tabs of one window,
                    // each with its own live shell; closing one ends its shell; quit ends the rest.
                    if UserDefaults.standard.bool(forKey: "c2dTerminalWindowCheck") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            openWindow(id: "terminal", value: TerminalWindowRequest(directory: model.terminalWindowDirectory))
                            try? await Task.sleep(for: .seconds(1))
                            // What the native "+" in the tab bar sends: `newWindowForTab:` with a nil target up the responder chain.
                            let sent = NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: NSApp.keyWindow)
                            debugTrace("terminalWindowCheck: plusViaResponderChain=\(sent) keyWindow=\(NSApp.keyWindow?.title ?? "nil")")
                            try? await Task.sleep(for: .milliseconds(2500))
                            for (win, panes) in model.standaloneWindowPanes {   // what each pane's split buttons send
                                if let first = panes.first { model.splitStandalone(window: win, after: first); model.splitStandalone(window: win, after: first, down: true) }
                            }
                            try? await Task.sleep(for: .milliseconds(800))
                            debugTrace("terminalWindowCheck: nested trees=\(model.standaloneWindowLayouts.values.map { "\($0)" })")
                            if let (win, panes) = model.standaloneWindowPanes.first, let first = panes.first {   // closing a nested pane collapses its split
                                await model.closeStandalonePane(window: win, first)
                                debugTrace("terminalWindowCheck: afterPaneClose panes=\(model.standaloneWindowPanes[win]?.count ?? 0) tree=\(model.standaloneWindowLayouts[win].map { "\($0)" } ?? "nil")")
                            }
                            if let first = model.standaloneWindowTitles.first { model.revealStandaloneWindow(first.id) }   // what the page menu sends
                            try? await Task.sleep(for: .milliseconds(1500))
                            debugTrace("terminalWindowCheck: menuTitles=\(model.standaloneWindowTitles.map(\.title)) keyIsTerminal=\(NSApp.keyWindow?.tabbingIdentifier == "c2d.terminal")")
                            if let f = model.focusedStandalonePane {   // what ⌘D sends
                                let before = model.standaloneWindowPanes[f.window]?.count ?? 0
                                model.splitStandalone(window: f.window, after: f.pane)
                                debugTrace("terminalWindowCheck: cmdD panes \(before)→\(model.standaloneWindowPanes[f.window]?.count ?? 0)")
                            } else { debugTrace("terminalWindowCheck: cmdD no focused pane") }
                            debugTrace("terminalWindowCheck: split panesPerWindow=\(model.standaloneWindowPanes.values.map(\.count)) running=\(model.standaloneTerminals.values.filter(\.isRunning).count)")
                            let wins = NSApp.windows.filter { $0.tabbingIdentifier == "c2d.terminal" && $0.isVisible }
                            let tabs = wins.first?.tabbedWindows?.count ?? -1
                            let running = model.standaloneTerminals.values.filter(\.isRunning).count
                            NSApp.activate(ignoringOtherApps: true); wins.first?.tabGroup?.selectedWindow?.makeKeyAndOrderFront(nil)
                            debugTrace("terminalWindowCheck: windowNumber=\(wins.first?.tabGroup?.selectedWindow?.windowNumber ?? -1) tabBarVisible=\(wins.first?.tabGroup?.isTabBarVisible ?? false) windows=\(wins.count) tabsInFirst=\(tabs) running=\(running) mainHasTabs=\(NSApp.windows.first { $0.tabbingIdentifier != "c2d.terminal" && $0.isVisible }?.tabbedWindows?.count ?? 0)")
                            try? await Task.sleep(for: .seconds(3))   // leaves time for a window-ID screencapture of the tab bar
                            wins.last?.close()
                            try? await Task.sleep(for: .seconds(1))
                            debugTrace("terminalWindowCheck: afterClose running=\(model.standaloneTerminals.values.filter(\.isRunning).count) tracked=\(model.standaloneTerminals.count)")
                        }
                    }
                    #endif
                    #if DEBUG
                    // `-c2dResizeCheck YES`: after 3 s shrink the main window by 400×200 pt; every terminal
                    // panel's grid must follow (trace "grid …"), proving Bible Part 4 §5.2 resize→PTY.
                    if UserDefaults.standard.bool(forKey: "c2dResizeCheck") {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.tabbingIdentifier != "c2d.terminal" }) else { return }
                            var f = w.frame; f.size.width -= 400; f.size.height -= 200; f.origin.y += 200
                            debugTrace("resizeCheck: \(Int(w.frame.width))x\(Int(w.frame.height)) → \(Int(f.width))x\(Int(f.height))")
                            w.setFrame(f, display: true)
                        }
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        let desc = NSApp.windows.map { "\(type(of: $0)) '\($0.title)' \(Int($0.frame.width))x\(Int($0.frame.height)) visible=\($0.isVisible)" }
                        debugTrace("windows: \(desc.joined(separator: " | "))")
                        // `-c2dSnapshot <png>` renders the window content in-process (works while occluded).
                        if let path = UserDefaults.standard.string(forKey: "c2dSnapshot"), let cv = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                            try? await Task.sleep(for: .seconds(2))
                            cv.window?.layoutIfNeeded(); cv.displayIfNeeded()
                            if let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                                cv.cacheDisplay(in: cv.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                debugTrace("snapshot written: \(path)")
                            }
                        }
                        if UserDefaults.standard.bool(forKey: "c2dDumpViews"), let cv = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                            debugTrace("view tree:\n\(cv.value(forKey: "_subtreeDescription") ?? "n/a")")
                        }
                    }
                    #endif
                }
                .frame(minWidth: 980, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandMenu("Shell") {
                // iTerm's split shortcuts; act on the focused pane of the key terminal window.
                Button("Split Right") { if let f = model.focusedStandalonePane { model.splitStandalone(window: f.window, after: f.pane) } }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { if let f = model.focusedStandalonePane { model.splitStandalone(window: f.window, after: f.pane, down: true) } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Terminal Window") { openWindow(id: "terminal", value: TerminalWindowRequest(directory: model.terminalWindowDirectory)) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Project…") { model.promptOpenProject() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("New Terminal") { model.workspace?.newTerminal() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(model.workspace == nil)
                Button("New Page…") { model.promptOpenProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Next Page") { model.cyclePage(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(model.openWorkspaces.count < 2)
                Button("Previous Page") { model.cyclePage(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(model.openWorkspaces.count < 2)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.workspace?.saveActiveEditor() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.workspace?.editors.values.contains { $0.activeTab != nil } != true)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Files & Commands…") { model.showPalette() }
                    .keyboardShortcut("p", modifiers: .command)   // ⌘P, alongside ⌘K
                Button("Find in Project…") { model.showPalette(prefill: "/") }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.workspace == nil)
                Button("Go to Line…") { model.showPalette(prefill: ":") }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.workspace?.editors.values.contains { $0.activeTab != nil } != true)
            }
            CommandMenu("Workspace") {
                Button("Toggle Focus Mode") {
                    guard let ws = model.workspace else { return }
                    if ws.layout.maximizedGroup != nil { ws.exitFocusMode() } else if let g = ws.layout.groupIDs.first { ws.maximize(g) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
                Divider()
                ForEach(LayoutPreset.allCases, id: \.self) { preset in
                    Button("Apply \(preset.displayName) Layout") { model.workspace?.apply(preset) }
                        .disabled(model.workspace == nil)
                }
                Divider()
                Button("Save as Default Layout") { model.workspace?.saveAsGlobalDefault() }
                    .disabled(model.workspace == nil)
            }
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") { model.prepareDiagnosticsExport() }
            }
            CommandGroup(after: .windowArrangement) {
                Button(BuddyPet.shared.isVisible ? "Hide Buddy" : "Show Buddy") { BuddyPet.shared.toggle() }
                Divider()
                // ⌘1…⌘9 pick a tab of the key window's native tab group (terminal windows), like other terminals.
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") {
                        if let tabs = NSApp.keyWindow?.tabbedWindows, tabs.indices.contains(n - 1) { tabs[n - 1].makeKeyAndOrderFront(nil) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }

        // Plain terminals in their own windows; macOS groups them as native tabs (the "+" in the tab
        // bar and ⌘N open another). They belong to no page and end when their window closes.
        WindowGroup("Terminal", id: "terminal", for: TerminalWindowRequest.self) { $request in
            TerminalWindowView(request: request ?? TerminalWindowRequest(directory: NSHomeDirectory()))
                .environment(model)
                .frame(minWidth: 520, minHeight: 320)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 980, height: 620)
    }
}

/// A value-keyed `WindowGroup` reuses the window for an equal value, so every request carries a fresh id.
struct TerminalWindowRequest: Hashable, Codable {
    var id = UUID()
    var directory: String
}

/// One terminal window: native macOS tabs across the top, side-by-side shells (panes) inside a tab.
private struct TerminalWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TerminalWindowRequest

    var body: some View {
        ZStack {   // never empty: onAppear must fire before the first pane exists
            Theme.window
            if let tree = model.standaloneWindowLayouts[request.id] { PaneTreeView(tree: tree, window: request.id, dismiss: { dismiss() }) }
        }
        .background(TerminalWindowConfigurator(window: request.id))
        .onAppear { model.openStandaloneWindow(request.id, directory: request.directory) }
        .onDisappear { Task { await model.closeStandaloneWindow(request.id) } }
        .navigationTitle(URL(fileURLWithPath: request.directory).lastPathComponent)
    }
}

/// One node of a terminal window's split tree: a shell pane, or a row/column of subtrees.
private struct PaneTreeView: View {
    @Environment(AppModel.self) private var model
    let tree: PaneTree
    let window: UUID
    let dismiss: () -> Void

    var body: some View {
        switch tree {
        case .pane(let id):
            if let t = model.standaloneTerminals[id] {
                TerminalPanelView(controller: t,
                                  onSplit: { model.splitStandalone(window: window, after: id, down: $0) },
                                  onClose: { Task { if await !model.closeStandalonePane(window: window, id) { dismiss() } } })
                    .frame(minWidth: 240, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            }
        case .split(let down, let kids):
            if down {
                VSplitView { ForEach(kids, id: \.self) { PaneTreeView(tree: $0, window: window, dismiss: dismiss) } }
            } else {
                HSplitView { ForEach(kids, id: \.self) { PaneTreeView(tree: $0, window: window, dismiss: dismiss) } }
            }
        }
    }
}

/// Marks the hosting NSWindow as a terminal tab: shared tabbing identifier (so windows group), never
/// restored by AppKit, and attached deterministically to an existing terminal window's tab group.
private struct TerminalWindowConfigurator: NSViewRepresentable {
    let window: UUID
    /// Configures as soon as AppKit attaches the view to its window — no timing assumptions.
    final class HookView: NSView {
        var id = UUID()
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); TerminalWindowConfigurator.configure(window, id: id) }
    }
    func makeNSView(context: Context) -> NSView { let v = HookView(); v.id = window; return v }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func configure(_ w: NSWindow?, id: UUID) {
        guard let w, w.tabbingIdentifier != "c2d.terminal" else { return }
        w.identifier = AppModel.terminalWindowIdentifier(id)   // lets the main window's menu bring this one back
        w.isRestorable = false
        w.tabbingIdentifier = "c2d.terminal"
        w.tabbingMode = .preferred
        if let host = NSApp.windows.first(where: { $0 !== w && $0.tabbingIdentifier == "c2d.terminal" && $0.isVisible }) {
            host.addTabbedWindow(w, ordered: .above)
        }
        w.makeKeyAndOrderFront(nil)
        // iTerm-style: the tab bar (with its "+") is always there, even for a single tab.
        if w.tabGroup?.isTabBarVisible != true { w.toggleTabBar(nil) }
        debugTrace("terminalWindow: configured '\(w.title)' tabGroup=\(w.tabGroup != nil) tabBarVisible=\(w.tabGroup?.isTabBarVisible ?? false) tabs=\(w.tabbedWindows?.count ?? 1)")
    }
}

/// Quit terminates live shells after confirmation, like Terminal.app. Nothing is left orphaned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false
    /// Installed by the app scene; opens another terminal window (the native tab bar's "+" sends `newWindowForTab:`).
    var openTerminalWindow: (() -> Void)?

    @objc func newWindowForTab(_ sender: Any?) { openTerminalWindow?() }

    /// Folders dropped on the Dock icon or passed to `open` become projects; anything else is
    /// ignored. Handling this here also stops SwiftUI from opening an empty window per argument.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    model?.openProject(at: url)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.windows.forEach { $0.isRestorable = false }
        BuddyPet.shared.restore()   // back on the desktop if it was out at quit
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        debugTrace("applicationShouldTerminate model=\(model != nil) terminating=\(terminating)")
        guard let model else { return .terminateNow }
        if terminating { return .terminateNow }
        #if DEBUG
        // `-c2dAutoConfirmQuit YES` skips the confirmation so automated runtime checks can exercise
        // the real quit path (terminate sessions, wait for exits). Debug builds only.
        let autoConfirm = UserDefaults.standard.bool(forKey: "c2dAutoConfirmQuit")
        #else
        let autoConfirm = false
        #endif
        if model.hasUnsavedEditors && !autoConfirm {
            let alert = NSAlert()
            alert.messageText = "You have unsaved files."
            alert.informativeText = "Quitting now discards unsaved edits. Save them first (⌘S) or discard."
            alert.addButton(withTitle: "Discard and Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if model.hasRunningSessions && !autoConfirm {
            let alert = NSAlert()
            alert.messageText = "Quit C2D Terminal?"
            alert.informativeText = "Running terminal sessions will be stopped (SIGHUP, then SIGKILL after 2 s)."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        // `.terminateLater` parks the run loop in a mode where main-actor tasks never run, so the
        // async shutdown happens first and termination is re-requested when it has finished.
        terminating = true
        Task { @MainActor in
            debugTrace("shutdown begin")
            await model.shutdown()
            debugTrace("shutdown done → terminate again")
            sender.terminate(nil)
        }
        return .terminateCancel
    }
}

/// Debug-only stderr trace for runtime checks that run the binary directly (os_log is not readable while the process lives).
func debugTrace(_ message: String) {
    #if DEBUG
    FileHandle.standardError.write(Data("[c2d] \(message)\n".utf8))
    #endif
}

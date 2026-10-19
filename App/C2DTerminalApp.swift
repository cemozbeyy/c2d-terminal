import AppKit
import C2DCore
import SwiftUI

@main
struct C2DTerminalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        Log.app.info("launch: \(DiagnosticsReport.current().summary, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup("C2D Terminal") {
            MainWindowView()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    // C2D restores its own workspace; AppKit window restoration would resurrect stale
                    // windows from earlier launches (seen as blank 500×500 windows).
                    NSApp.windows.forEach { $0.isRestorable = false }
                    #if DEBUG
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
            CommandGroup(replacing: .newItem) {
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
        }
    }
}

/// Quit terminates live shells after confirmation, like Terminal.app. Nothing is left orphaned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false

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
        if model.workspace?.hasUnsavedEditors == true && !autoConfirm {
            let alert = NSAlert()
            alert.messageText = "You have unsaved files."
            alert.informativeText = "Quitting now discards unsaved edits. Save them first (⌘S) or discard."
            alert.addButton(withTitle: "Discard and Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        if model.workspace?.hasRunningSessions == true && !autoConfirm {
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

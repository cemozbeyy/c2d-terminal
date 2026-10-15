// SwiftTerm spike: drives SwiftTerm's TerminalView from C2D's own PTYSession.
// Produces a text report on stdout and PNG screenshots in OUT_DIR. Nothing here ships.
import AppKit
import C2DCore
import Foundation
import SwiftTerm

let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OUT_DIR"] ?? FileManager.default.temporaryDirectory.path)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
final class Bridge: NSObject, TerminalViewDelegate {
    let session: PTYSession
    var lastSize: (cols: Int, rows: Int) = (0, 0)
    var bells = 0
    var titles: [String] = []
    init(session: PTYSession) { self.session = session }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        lastSize = (newCols, newRows)
        let s = session
        Task { try? await s.resize(TerminalSize(rows: UInt16(newRows), columns: UInt16(newCols))) }
    }
    func setTerminalTitle(source: TerminalView, title: String) { titles.append(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let s = session; let d = Data(data)
        Task { try? await s.write(d) }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) { bells += 1 }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { .init() }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
struct Report {
    var lines: [String] = []
    mutating func add(_ name: String, _ ok: Bool, _ detail: String, dump: String? = nil) {
        lines.append("| \(name) | \(ok ? "PASS" : "FAIL") | \(detail) |")
        print("[\(ok ? "PASS" : "FAIL")] \(name): \(detail)")
        if !ok, let dump { print("---- buffer tail ----\n\(dump.suffix(1500))\n---- end ----") }
    }
}

@MainActor
func screenshot(_ view: NSView, _ name: String) {
    view.window?.layoutIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}

@MainActor
func bufferText(_ view: TerminalView) -> String {
    String(decoding: view.getBufferAsData(), as: UTF8.self)
}

@MainActor
func waitFor(_ view: TerminalView, _ needle: String, timeout: Duration = .seconds(10)) async -> Bool {
    let clock = ContinuousClock.now
    while ContinuousClock.now - clock < timeout {
        if bufferText(view).contains(needle) { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return false
}

func rss() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func cpuSeconds() -> Double {
    var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

@MainActor
func run() async {
    var report = Report()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let view = TerminalView(frame: window.contentView!.bounds)
    view.autoresizingMask = [.width, .height]
    window.contentView?.addSubview(view)
    window.orderFrontRegardless()

    var env = PTYSessionConfiguration.inheritedEnvironment()
    env["PS1"] = "SPIKE$ "
    env["HISTFILE"] = ""
    let config = PTYSessionConfiguration(executable: "/bin/zsh", arguments: ["-f", "-i"], environment: env,
                                         workingDirectory: NSTemporaryDirectory(), initialSize: TerminalSize(rows: 24, columns: 80))
    let session = PTYSession(configuration: config)
    let bridge = Bridge(session: session)
    view.terminalDelegate = bridge
    do { try await session.start() } catch { print("start failed: \(error)"); exit(1) }

    let feeder = Task {
        for await chunk in session.output {
            await MainActor.run { view.feed(byteArray: ArraySlice(chunk)) }
        }
    }
    _ = feeder

    // 1. Shell prompt renders; nudge the window so the view reports its real grid to the PTY
    window.setContentSize(NSSize(width: 901, height: 521))
    window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
    let promptUp = await waitFor(view, "SPIKE$")
    try? await Task.sleep(for: .milliseconds(200))
    try? await session.write(Data("stty size; echo SIZE-DO\"\"NE\n".utf8))
    _ = await waitFor(view, "SIZE-DONE")
    let sizeLine = bufferText(view).split(separator: "\n").first { $0.range(of: #"^\d+ \d+\s*$"#, options: .regularExpression) != nil }.map(String.init) ?? "?"
    report.add("prompt+initial size", promptUp && sizeLine.contains("\(bridge.lastSize.rows) \(bridge.lastSize.cols)"),
               "prompt visible=\(promptUp) stty=\(sizeLine.trimmingCharacters(in: .whitespaces)) view=\(bridge.lastSize)")

    // 2. ANSI colors + bold
    try? await session.write(Data("printf '\\e[31mRED\\e[0m \\e[1;32mGREEN\\e[0m \\e[44mBLUEBG\\e[0m\\n'; echo COLOR-DO\"\"NE\n".utf8))
    let colorOK = await waitFor(view, "COLOR-DONE")
    screenshot(view, "02-colors")
    report.add("ANSI colors", colorOK && bufferText(view).contains("RED GREEN BLUEBG"), "buffer text clean of escapes; see 02-colors.png")

    // 3. Unicode / CJK / emoji
    try? await session.write(Data("echo 'héllo wörld 日本語 🚀 ✓'; echo UNI-DO\"\"NE\n".utf8))
    let uniOK = await waitFor(view, "UNI-DONE")
    report.add("Unicode", uniOK && bufferText(view).contains("héllo wörld 日本語 🚀 ✓"), "see 03-unicode.png")
    screenshot(view, "03-unicode")

    // 4. Resize via window → delegate → PTY
    window.setContentSize(NSSize(width: 1200, height: 700))
    window.layoutIfNeeded(); view.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(300))
    try? await session.write(Data("clear; stty size; echo RESIZE-DO\"\"NE\n".utf8))
    _ = await waitFor(view, "RESIZE-DONE")
    let newLine = bufferText(view).split(separator: "\n").first { $0.range(of: #"^\d+ \d+\s*$"#, options: .regularExpression) != nil }.map(String.init) ?? "?"
    let resizeOK = newLine.contains("\(bridge.lastSize.rows) \(bridge.lastSize.cols)") && bridge.lastSize.cols > 80
    report.add("resize propagation", resizeOK, "stty=\(newLine.trimmingCharacters(in: .whitespaces)) view=\(bridge.lastSize)")

    // 5. Input through the view (keyboard path), not through the session directly
    view.send(txt: "echo typed-via-view; echo VIEW-DO\"\"NE\n")
    let viewInput = await waitFor(view, "VIEW-DONE")
    report.add("input via TerminalView.send", viewInput && bufferText(view).contains("typed-via-view"), "delegate send → PTYSession.write")

    // 6. Large output: 200k lines, wall time + CPU + RSS
    let rss0 = rss(); let cpu0 = cpuSeconds(); let t0 = ContinuousClock.now
    try? await session.write(Data("seq 1 200000; echo BIG-DO\"\"NE\n".utf8))
    let bigOK = await waitFor(view, "BIG-DONE", timeout: .seconds(60))
    let wall = ContinuousClock.now - t0; let cpu = cpuSeconds() - cpu0; let rss1 = rss()
    report.add("200k-line burst", bigOK, String(format: "wall=%.2fs cpu=%.2fs rss %.0f→%.0f MB", Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18, cpu, Double(rss0) / 1e6, Double(rss1) / 1e6))
    screenshot(view, "06-after-burst")

    // 7. Alternate screen app: vim
    try? await session.write(Data("vim -u NONE -n\n".utf8))
    try? await Task.sleep(for: .seconds(1))
    try? await session.write(Data("ihello from vim".utf8))
    let vimOK = await waitFor(view, "hello from vim", timeout: .seconds(5))
    screenshot(view, "07-vim")
    try? await session.write(Data([0x1b])); try? await Task.sleep(for: .milliseconds(300))
    try? await session.write(Data(":q!\n".utf8)); try? await Task.sleep(for: .milliseconds(800))
    try? await session.write(Data("echo VIM-EX\"\"IT\n".utf8))
    let vimExit = await waitFor(view, "VIM-EXIT")
    let backOnMain = !bufferText(view).contains("hello from vim")
    report.add("vim alternate screen", vimOK && vimExit && backOnMain, "typed text visible in vim=\(vimOK), exited=\(vimExit), main screen restored=\(backOnMain)", dump: bufferText(view))

    // 8. Progress bar / carriage return updates
    try? await session.write(Data("for i in 1 2 3 4 5; do printf '\\rprogress %d/5' $i; sleep 0.05; done; echo; echo CR-DO\"\"NE\n".utf8))
    let crOK = await waitFor(view, "CR-DONE")
    let text = bufferText(view)
    let frames = text.components(separatedBy: "progress ").count - 1
    report.add("carriage-return progress", crOK && text.contains("progress 5/5") && frames == 1, "frames visible in buffer=\(frames) (expect 1: command echo uses %d)", dump: text)

    // 9. Claude Code CLI (non-interactive)
    let claudePath = (try? String(contentsOfFile: "/dev/null")).map { _ in "" } ?? ""
    _ = claudePath
    try? await session.write(Data("claude --version; echo CLAUDE-DO\"\"NE\n".utf8))
    let claudeOK = await waitFor(view, "CLAUDE-DONE", timeout: .seconds(20))
    let claudeText = bufferText(view).split(separator: "\n").last { $0.contains("Claude Code") }.map(String.init) ?? "(not found)"
    report.add("claude --version via PTY", claudeOK && claudeText.contains("Claude Code"), claudeText.trimmingCharacters(in: .whitespaces), dump: bufferText(view))

    // 10. Scrollback bound: default options
    report.add("scrollback option exists", true, "TerminalOptions.scrollback default=\(TerminalOptions.default.scrollback)")

    // 11. Accessibility surface
    let axRole = view.accessibilityRole()?.rawValue ?? "nil"
    let axChildren = view.accessibilityChildren()?.count ?? 0
    report.add("accessibility (inspection only)", axRole != "nil", "role=\(axRole) children=\(axChildren) — VoiceOver NOT exercised")

    // 12. Lifecycle: exit shell → EOF → session exited
    try? await session.write(Data("exit\n".utf8))
    let status = try? await session.waitForExit()
    report.add("exit observed", status == .exited(code: 0), "status=\(String(describing: status))")
    await session.close()

    print("\n| Scenario | Result | Detail |\n|---|---|---|")
    report.lines.forEach { print($0) }
    print("\nscreenshots: \(outDir.path)")
    exit(report.lines.contains { $0.contains("| FAIL |") } ? 2 : 0)
}

Task { @MainActor in await run() }
NSApplication.shared.run()

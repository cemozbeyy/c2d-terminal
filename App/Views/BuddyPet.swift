import AppKit
import C2DCore
import SwiftUI

/// Buddy as a desktop pet: a small transparent, borderless panel holding only the mascot. It floats above
/// ordinary windows of every app (`.floating`, below alerts, menus and system prompts), follows you across
/// Spaces, never takes focus or activates C2D, and is entirely separate from workspaces and sessions.
/// Shown/hidden state and position persist in UserDefaults; nothing else is stored.
@MainActor
@Observable
final class BuddyPet {
    static let shared = BuddyPet()

    private(set) var isVisible = false
    /// What the mascot view renders; mutated by the panel's mouse handling.
    let state = BuddyPetState()

    @ObservationIgnored private var panel: BuddyPetPanel?
    @ObservationIgnored private var bubbleTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// State file → the modification date the user last acknowledged (by clicking Buddy).
    @ObservationIgnored private var acknowledged: [String: Date] = [:]
    /// How long Buddy waves "Done!" after a session finishes, unless clicked sooner.
    private static let doneBubbleSeconds: TimeInterval = 15
    @ObservationIgnored private var lastSeen: [String: (AgentActivity, Date)] = [:]
    private static let size = NSSize(width: 140, height: 150)
    private static let originKey = "c2dBuddyPetOrigin"
    private static let visibleKey = "c2dBuddyPetVisible"
    private static let clickLines = ["Hi!", "Boop!", "Hehe", ">_ ready", "Hey there!"]
    @ObservationIgnored private var clickLine = 0

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BuddyPet.shared.keepOnScreen(save: false) }
        }
    }

    /// Relaunch: bring Buddy back if it was out when the app quit.
    @ObservationIgnored private var restored = false

    func restore() {
        guard !restored else { return }   // the main window can appear more than once
        restored = true
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "c2dBuddyPetCheck") { Task { await runCheck() }; return }
        #endif
        if UserDefaults.standard.bool(forKey: Self.visibleKey) { show() }
    }

    /// Sidebar / menu: show Buddy, or bounce it to the front if it's already out. Never duplicates.
    func summon() {
        if let panel { panel.orderFrontRegardless(); state.hop += 1 } else { show() }
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard panel == nil else { return }
        let p = BuddyPetPanel(contentRect: NSRect(origin: savedOrigin() ?? defaultOrigin(), size: Self.size))
        let content = BuddyPetContentView(frame: NSRect(origin: .zero, size: Self.size), state: state)
        content.onClick = { [weak self] in self?.acknowledge(); self?.poke() }
        content.onDrop = { [weak self] in self?.keepOnScreen(save: true); self?.state.hop += 1 }
        content.onHide = { [weak self] in self?.hide() }
        p.contentView = content
        panel = p
        keepOnScreen(save: false)
        p.orderFrontRegardless()
        isVisible = true
        UserDefaults.standard.set(true, forKey: Self.visibleKey)
        say("Hi there!", for: 2.4)
        watchTask = Task { [weak self] in await self?.watchAgents() }
    }

    /// The panel is dropped, not just ordered out: no hidden view keeps animating.
    func hide() {
        guard let panel else { return }
        bubbleTask?.cancel()
        watchTask?.cancel(); watchTask = nil
        state.bubble = nil
        state.held = false
        state.working = false
        state.waving = false
        panel.orderOut(nil)
        self.panel = nil
        isVisible = false
        UserDefaults.standard.set(false, forKey: Self.visibleKey)
    }

    /// Polls the agents' activity files once a second while Buddy is out (a handful of tiny files).
    /// working anywhere → amber antenna and thinking pose; a finished session → wave and "Done!" for
    /// `doneBubbleSeconds` (or until clicked); a session waiting for the user → "Needs you!" until they
    /// click Buddy or answer it (which flips it back to working).
    private func watchAgents() async {
        let dir = AgentActivity.directory()
        var lastHop = Date.distantPast
        // Leftovers from sessions that ended while C2D wasn't running.
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(m) > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        while !Task.isCancelled {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var seen: [String: (AgentActivity, Date)] = [:]
            for url in files {
                guard let a = AgentActivity.read(url),
                      let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                seen[url.lastPathComponent] = (a, m)
            }
            lastSeen = seen
            // A "working" file untouched for 20 min is a session that died without its hooks firing.
            let working = seen.values.contains { $0.0 == .working && Date().timeIntervalSince($0.1) < 1200 }
            // "Done!" fades on its own after a while; "Needs you!" stays until answered or clicked.
            let pending = seen.filter { name, value in
                guard value.0 == .done || value.0 == .waiting, value.1 > (acknowledged[name] ?? .distantPast) else { return false }
                return value.0 == .waiting || Date().timeIntervalSince(value.1) < Self.doneBubbleSeconds
            }
            state.working = working
            let waving = !working && !pending.isEmpty
            if waving != state.waving {
                state.waving = waving
                if waving { bubbleTask?.cancel(); state.bubble = pending.values.contains { $0.0 == .waiting } ? "Needs you!" : "Done!" }
                else if state.bubble == "Done!" || state.bubble == "Needs you!" { state.bubble = nil }
            }
            if waving, Date().timeIntervalSince(lastHop) > 3 { state.hop += 1; lastHop = Date() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Clicking Buddy says "seen it" for every finished/waiting session right now.
    private func acknowledge() {
        for (name, value) in lastSeen where value.0 == .done || value.0 == .waiting { acknowledged[name] = value.1 }
        if state.waving { state.waving = false; state.bubble = nil }
    }

    private func poke() {
        state.hop += 1
        say(Self.clickLines[clickLine % Self.clickLines.count], for: 1.6)
        clickLine += 1
    }

    private func say(_ text: String, for seconds: Double) {
        bubbleTask?.cancel()
        state.bubble = text
        bubbleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.state.bubble = nil
        }
    }

    /// Pull the panel fully inside the visible frame (menu bar and Dock excluded) of the display it is
    /// mostly on; if it is on none (display unplugged), onto the main display.
    private func keepOnScreen(save: Bool) {
        guard let panel else { return }
        var f = panel.frame
        let screen = NSScreen.screens.max { $0.visibleFrame.intersection(f).area < $1.visibleFrame.intersection(f).area }
        guard let vis = (screen.flatMap { $0.visibleFrame.intersects(f) ? $0 : nil } ?? NSScreen.main)?.visibleFrame else { return }
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
        if save { UserDefaults.standard.set([f.origin.x, f.origin.y], forKey: Self.originKey) }
    }

    private func savedOrigin() -> NSPoint? {
        guard let a = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], a.count == 2 else { return nil }
        return NSPoint(x: a[0], y: a[1])
    }

    private func defaultOrigin() -> NSPoint {
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: vis.maxX - Self.size.width - 40, y: vis.minY + 24)
    }
}

#if DEBUG
extension BuddyPet {
    /// `-c2dBuddyPetCheck YES`: window shape, no duplicates, no activation/focus theft, survives another app
    /// becoming active, off-screen clamp + saved position, hide/restore. Drag and Reduce Motion need a real
    /// mouse / system setting and are not covered here.
    func runCheck() async {
        func pets() -> [NSWindow] { NSApp.windows.filter { $0 is BuddyPetPanel && $0.isVisible } }
        // Same bundle id as the user's app: put their Buddy position/visibility back afterwards.
        let defaults = UserDefaults.standard, userOrigin = defaults.object(forKey: Self.originKey), userVisible = defaults.object(forKey: Self.visibleKey)
        defer { defaults.set(userOrigin, forKey: Self.originKey); defaults.set(userVisible, forKey: Self.visibleKey) }
        try? await Task.sleep(for: .seconds(2))
        let activeBefore = NSApp.isActive, keyBefore = NSApp.keyWindow?.title ?? "nil"
        show(); summon(); summon(); show()
        try? await Task.sleep(for: .milliseconds(500))
        guard let p = panel else { debugTrace("buddyCheck: FAIL no panel"); return }
        debugTrace("buddyCheck: pets=\(pets().count) borderless=\(p.styleMask.contains(.borderless)) nonactivating=\(p.styleMask.contains(.nonactivatingPanel)) opaque=\(p.isOpaque) clearBg=\(p.backgroundColor == .clear) level=\(p.level.rawValue) canKey=\(p.canBecomeKey) frame=\(p.frame)")
        debugTrace("buddyCheck: activeBefore=\(activeBefore) activeAfter=\(NSApp.isActive) keyBefore=\(keyBefore) keyAfter=\(NSApp.keyWindow?.title ?? "nil") hop=\(state.hop) bubble=\(state.bubble ?? "nil")")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        try? await Task.sleep(for: .seconds(1.5))
        debugTrace("buddyCheck: otherAppActive c2dActive=\(NSApp.isActive) petVisible=\(p.isVisible) occludedVisible=\(p.occlusionState.contains(.visible))")
        p.setFrameOrigin(NSPoint(x: -5000, y: -5000)); keepOnScreen(save: true)
        let vis = NSScreen.main?.visibleFrame ?? .zero
        debugTrace("buddyCheck: clamp origin=\(p.frame.origin) inside=\(vis.contains(p.frame)) saved=\(savedOrigin().map { "\($0)" } ?? "nil")")
        p.setFrameOrigin(NSPoint(x: vis.midX, y: vis.midY)); keepOnScreen(save: true)
        let kept = p.frame.origin
        hide()
        try? await Task.sleep(for: .milliseconds(300))
        debugTrace("buddyCheck: hidden pets=\(pets().count) isVisible=\(isVisible) flag=\(UserDefaults.standard.bool(forKey: Self.visibleKey))")
        show()
        try? await Task.sleep(for: .milliseconds(300))
        debugTrace("buddyCheck: reshown pets=\(pets().count) samePosition=\(panel?.frame.origin == kept) mainWindowVisible=\(NSApp.windows.contains { $0.canBecomeMain && $0.isVisible })")
        // Agent activity: working → amber antenna; done → wave + "Done!" until clicked (acknowledged).
        let dir = AgentActivity.directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("check-session")
        try? Data("working".utf8).write(to: file)
        try? await Task.sleep(for: .seconds(1.5))
        debugTrace("buddyCheck: activity working → working=\(state.working) waving=\(state.waving)")
        try? Data("done".utf8).write(to: file)
        try? await Task.sleep(for: .seconds(1.5))
        debugTrace("buddyCheck: activity done → working=\(state.working) waving=\(state.waving) bubble=\(state.bubble ?? "nil")")
        acknowledge()
        try? await Task.sleep(for: .seconds(1.5))
        debugTrace("buddyCheck: after click → waving=\(state.waving) bubble=\(state.bubble ?? "nil")")
        try? Data("working".utf8).write(to: file); try? await Task.sleep(for: .seconds(1.2))
        try? Data("waiting".utf8).write(to: file); try? await Task.sleep(for: .seconds(1.5))
        debugTrace("buddyCheck: answered then waiting → waving=\(state.waving) bubble=\(state.bubble ?? "nil")")
        try? FileManager.default.removeItem(at: file)
    }
}
#endif

/// The few things the pet view reacts to.
@MainActor
@Observable
final class BuddyPetState {
    var hop = 0
    var held = false
    var bubble: String?
    /// From the agents' activity hooks (see `BuddyPet.watchAgents`).
    var working = false
    var waving = false
}

/// Borderless, transparent, non-activating; can't become key, so clicking Buddy never steals focus
/// from whatever you are typing in.
final class BuddyPetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                 // the mascot draws its own soft ground shadow
        hidesOnDeactivate = false         // stays out when you switch apps
        isReleasedWhenClosed = false
        isMovable = false                 // moved by BuddyPetContentView, which tells drags from clicks
        isExcludedFromWindowsMenu = true
        isRestorable = false
        animationBehavior = .none
        // Every Space, but not over full-screen apps (no `.fullScreenAuxiliary`); skipped by ⌘` cycling.
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI mascot and owns the mouse: press → (moves past 3 pt → drag) → release.
/// A release without a drag is a click; a release after a drag is a drop. Right-click opens a tiny menu.
final class BuddyPetContentView: NSView {
    var onClick: () -> Void = {}
    var onDrop: () -> Void = {}
    var onHide: () -> Void = {}

    private enum Gesture { case idle, pressed(mouse: NSPoint, origin: NSPoint), dragging(mouse: NSPoint, origin: NSPoint) }
    private var gesture = Gesture.idle
    private let state: BuddyPetState
    private static let dragThreshold: CGFloat = 3

    init(frame: NSRect, state: BuddyPetState) {
        self.state = state
        super.init(frame: frame)
        let host = NSHostingView(rootView: BuddyPetView(state: state))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Only the mascot itself is grabbable; the transparent margin (speech-bubble room) is not.
    private var mascotRect: NSRect { NSRect(x: (bounds.width - 104) / 2, y: 0, width: 104, height: 108) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        mascotRect.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(mascotRect, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Control-click is a right-click on macOS: menu, not a poke.
        if event.modifierFlags.contains(.control) { showMenu(event); return }
        gesture = .pressed(mouse: NSEvent.mouseLocation, origin: window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        switch gesture {
        case .idle: return
        case let .pressed(mouse, origin):
            guard hypot(now.x - mouse.x, now.y - mouse.y) >= Self.dragThreshold else { return }
            gesture = .dragging(mouse: mouse, origin: origin)
            state.held = true
            NSCursor.closedHand.set()
            fallthrough
        case .dragging:
            guard case let .dragging(mouse, origin) = gesture else { return }
            window.setFrameOrigin(NSPoint(x: origin.x + now.x - mouse.x, y: origin.y + now.y - mouse.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let was = gesture
        gesture = .idle
        switch was {
        case .idle: return
        case .pressed: onClick()
        case .dragging:
            state.held = false
            NSCursor.openHand.set()
            onDrop()
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    override func menu(for event: NSEvent) -> NSMenu? { petMenu() }

    private func showMenu(_ event: NSEvent) {
        gesture = .idle
        NSMenu.popUpContextMenu(petMenu(), with: event, for: self)
    }

    private func petMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hide Buddy", action: #selector(hideBuddy), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open C2D Terminal", action: #selector(openApp), keyEquivalent: "").target = self
        return menu
    }

    @objc private func hideBuddy() { onHide() }

    @objc private func openApp() {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }
}

/// The pet's SwiftUI face: speech bubble above, mascot below. Nothing else is drawn, so the panel shows
/// only Buddy and its ground shadow.
private struct BuddyPetView: View {
    let state: BuddyPetState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let text = state.bubble {
                    Text(text)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.24))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
                }
            }
            .frame(height: 38)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.bubble)
            BuddyMascotView(size: 104, held: state.held, hop: state.hop, working: state.working, waving: state.waving)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

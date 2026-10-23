import AppKit
import C2DCore
import SwiftUI

/// One executable command. Only commands that are actually wired exist (Bible §2.3).
struct PaletteCommand: Identifiable {
    enum Kind: String { case action, project, file, layout, panel, task, branch, destination, match, line }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let symbol: String
    let run: @MainActor () -> Void
}

/// Builds the command list from real state: deterministic, no AI suggestions (GAP-17 open).
@MainActor
enum CommandCatalog {
    nonisolated static let fileScanLimit = 5000
    nonisolated static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", ".swiftpm", "dist", "build"]

    /// `/text` searches file contents, `:42` goes to a line in the active editor (Bible Part 5 §7.2–7.3).
    static func isPrefixed(_ query: String) -> Bool { query.hasPrefix("/") || query.hasPrefix(":") }

    static func commands(model: AppModel, query: String) -> [PaletteCommand] {
        if query.hasPrefix(":") {
            guard let ws = model.workspace, let n = Int(query.dropFirst().trimmingCharacters(in: .whitespaces)), n > 0,
                  let e = ws.editors.values.first(where: { $0.activeTab != nil }), let tab = e.activeTab else { return [] }
            return [PaletteCommand(id: "goto-\(n)", kind: .line, title: "Go to line \(n)", subtitle: tab.name, symbol: "arrow.right.to.line") {
                e.goTo(line: n); model.destination = .workspace
            }]
        }
        if query.hasPrefix("/") { return [] }   // content matches are produced asynchronously by the view
        return plainCommands(model: model, query: query)
    }

    static func matchCommands(_ hits: [ContentHit], model: AppModel) -> [PaletteCommand] {
        guard let ws = model.workspace else { return [] }
        return hits.map { hit in
            let rel = relativePath(hit.path, root: ws.projectPath)
            return PaletteCommand(id: "match-\(hit.path):\(hit.line)", kind: .match, title: "\(rel):\(hit.line)", subtitle: hit.text, symbol: "text.magnifyingglass") {
                ws.openFile(path: hit.path, line: hit.line); model.destination = .workspace
            }
        }
    }

    private static func plainCommands(model: AppModel, query: String) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        out.append(PaletteCommand(id: "open-project", kind: .action, title: "Open Project…", subtitle: "Choose a local folder", symbol: "folder.badge.plus") {
            model.promptOpenProject()
        })
        for p in model.registry.projects where p.isAvailable {
            out.append(PaletteCommand(id: "project-\(p.path)", kind: .project, title: "Open \(p.name)", subtitle: p.path, symbol: "folder") { model.openProject(p) })
        }
        for d in Destination.allCases where d != .workspace || model.workspace != nil {
            out.append(PaletteCommand(id: "go-\(d.rawValue)", kind: .destination, title: "Go to \(d.label)", subtitle: nil, symbol: d.symbol) { model.destination = d })
        }
        out.append(PaletteCommand(id: "buddy", kind: .action, title: BuddyPet.shared.isVisible ? "Hide Buddy" : "Show Buddy", subtitle: "Desktop pet", symbol: "face.smiling") { BuddyPet.shared.toggle() })
        if let ws = model.workspace {
            out.append(PaletteCommand(id: "new-terminal", kind: .action, title: "New Terminal", subtitle: ws.projectName, symbol: "plus.rectangle") { ws.newTerminal(); model.destination = .workspace })
            out.append(PaletteCommand(id: "focus", kind: .action, title: ws.layout.maximizedGroup == nil ? "Enter Focus Mode" : "Exit Focus Mode", subtitle: nil, symbol: "arrow.up.left.and.arrow.down.right") {
                if ws.layout.maximizedGroup != nil { ws.exitFocusMode() } else if let g = ws.layout.groupIDs.first { ws.maximize(g) }
            })
            for preset in LayoutPreset.allCases {
                out.append(PaletteCommand(id: "layout-\(preset.rawValue)", kind: .layout, title: "Apply \(preset.displayName) Layout", subtitle: preset.summary, symbol: "rectangle.3.group") { ws.apply(preset); model.destination = .workspace })
            }
            for id in ws.layout.hidden {
                let title = ws.layout.panels[id]?.title ?? id.rawValue
                out.append(PaletteCommand(id: "restore-\(id.rawValue)", kind: .panel, title: "Show panel: \(title)", subtitle: "hidden", symbol: "eye") { ws.restore(id); model.destination = .workspace })
            }
            for t in ws.tasks.tasks {
                out.append(PaletteCommand(id: "task-\(t.id)", kind: .task, title: t.title, subtitle: "Task · \(t.status.rawValue)", symbol: "checklist") { model.destination = .tasks; Task { await ws.tasks.select(t) } })
            }
            if ws.git.isAvailable {
                for b in ws.git.branches where !b.isCurrent {
                    out.append(PaletteCommand(id: "branch-\(b.name)", kind: .branch, title: "Switch to branch \(b.name)", subtitle: "Refused if the working tree is dirty", symbol: "arrow.triangle.branch") { Task { await ws.git.checkout(b.name) } })
                }
            }
            // Files: only when the query looks like a file search (≥ 2 chars) to keep the list sane.
            let q = query.trimmingCharacters(in: .whitespaces)
            if q.count >= 2 {
                for path in scanFiles(root: ws.projectPath, matching: q) {
                    let rel = relativePath(path, root: ws.projectPath)
                    out.append(PaletteCommand(id: "file-\(path)", kind: .file, title: rel, subtitle: "Open in editor", symbol: "doc.text") { ws.openFile(path: path); model.destination = .workspace })
                }
            }
        }
        return out
    }

    struct ContentHit: Sendable, Hashable { let path: String; let line: Int; let text: String }

    /// Project-relative display path. The enumerator reports symlinks resolved (`/private/tmp/…`)
    /// while the project root may not be (`/tmp/…`); compare both resolved.
    nonisolated static func relativePath(_ path: String, root: String) -> String {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : path
    }
    nonisolated static let contentFileLimit = 2000, contentMatchLimit = 100, contentFileSizeLimit = 512 * 1024

    /// Case-insensitive literal search over UTF-8 text files (Bible Part 5 §7.2). Documented limits:
    /// first 2000 eligible files, files ≤ 512 KB, 100 matches; the same directories are skipped as
    /// for file search. Pure function; call off the main actor.
    nonisolated static func searchContent(root: String, query: String) -> [ContentHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var hits: [ContentHit] = []
        var visited = 0
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            visited += 1
            if visited > contentFileLimit || hits.count >= contentMatchLimit { break }
            guard (v?.fileSize ?? 0) <= contentFileSizeLimit, let data = try? Data(contentsOf: url), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var line = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                if raw.range(of: q, options: .caseInsensitive) != nil {
                    hits.append(ContentHit(path: url.path, line: line, text: String(raw.trimmingCharacters(in: .whitespaces).prefix(160))))
                    if hits.count >= contentMatchLimit { break }
                }
            }
        }
        return hits
    }

    /// Bounded, synchronous walk; skips well-known generated directories. Documented limit: 5000 files.
    static func scanFiles(root: String, matching query: String) -> [String] {
        let q = query.lowercased()
        var results: [String] = []
        var visited = 0
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .nameKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            visited += 1
            if visited > fileScanLimit { break }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            if v?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if url.lastPathComponent.lowercased().contains(q) { results.append(url.path) }
            if results.count >= 40 { break }
        }
        return results
    }
}

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0
    @State private var hits: [CommandCatalog.ContentHit] = []

    private var filtered: [PaletteCommand] {
        if query.hasPrefix("/") { return CommandCatalog.matchCommands(hits, model: model) }
        let all = CommandCatalog.commands(model: model, query: query)
        if CommandCatalog.isPrefixed(query) { return all }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(all.prefix(30)) }
        return all.filter { $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }.prefix(40).map { $0 }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search files, commands · /text in files · :line", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .onSubmit { run(items.indices.contains(selection) ? items[selection] : items.first) }
                    .onChange(of: query) { selection = 0 }
                    .onAppear { if let q = model.paletteInitialQuery { query = q; model.paletteInitialQuery = nil } }
                    .task(id: query) {
                        guard query.hasPrefix("/"), let root = model.workspace?.projectPath else { hits = []; return }
                        let q = String(query.dropFirst())
                        try? await Task.sleep(for: .milliseconds(250))   // debounce keystrokes
                        guard !Task.isCancelled else { return }
                        let found = await Task.detached { CommandCatalog.searchContent(root: root, query: q) }.value
                        if !Task.isCancelled { hits = found }
                    }
                Text("esc").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(Array(items.enumerated()), id: \.element.id) { index, cmd in
                    HStack {
                        Image(systemName: cmd.symbol).frame(width: 18).foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading) {
                            Text(cmd.title).lineLimit(1)
                            if let s = cmd.subtitle { Text(s).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle) }
                        }
                        Spacer()
                        Text(cmd.kind.rawValue).font(Theme.Typography.caption2).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(index == selection ? Theme.accent.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle()).clickCursor()
                    .onTapGesture { run(cmd) }
                    .id(cmd.id)
                }
                .listStyle(.plain)
                .onChange(of: selection) { if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) } }
            }
            .frame(height: 320)
            if items.isEmpty { Text(query.hasPrefix("/") ? "No matches (first \(CommandCatalog.contentFileLimit) files, ≤ 512 KB each)" : "No matching command").font(.caption).foregroundStyle(Theme.textSecondary).padding(8) }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.textMuted.opacity(0.3)))
        .shadow(radius: 20)
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .accessibilityLabel("Command palette")
    }

    private func run(_ cmd: PaletteCommand?) {
        guard let cmd else { return }
        isPresented = false
        cmd.run()
    }
}

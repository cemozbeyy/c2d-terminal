import AppKit
import C2DCore
import SwiftUI

/// One executable command. Only commands that are actually wired exist (Bible §2.3).
struct PaletteCommand: Identifiable {
    enum Kind: String { case action, project, file, layout, panel, task, branch, destination }
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
    static let fileScanLimit = 5000
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", ".swiftpm", "dist", "build"]

    static func commands(model: AppModel, query: String) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        out.append(PaletteCommand(id: "open-project", kind: .action, title: "Open Project…", subtitle: "Choose a local folder", symbol: "folder.badge.plus") {
            model.destination = .projects; NotificationCenter.default.post(name: .c2dOpenProject, object: nil)
        })
        for p in model.registry.projects where p.isAvailable {
            out.append(PaletteCommand(id: "project-\(p.path)", kind: .project, title: "Open \(p.name)", subtitle: p.path, symbol: "folder") { model.openProject(p) })
        }
        for d in Destination.allCases where d != .workspace || model.workspace != nil {
            out.append(PaletteCommand(id: "go-\(d.rawValue)", kind: .destination, title: "Go to \(d.label)", subtitle: nil, symbol: d.symbol) { model.destination = d })
        }
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
                    let rel = String(path.dropFirst(ws.projectPath.count + 1))
                    out.append(PaletteCommand(id: "file-\(path)", kind: .file, title: rel, subtitle: "Open in editor", symbol: "doc.text") { ws.openFile(path: path); model.destination = .workspace })
                }
            }
        }
        return out
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

    private var filtered: [PaletteCommand] {
        let all = CommandCatalog.commands(model: model, query: query)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(all.prefix(30)) }
        return all.filter { $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }.prefix(40).map { $0 }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search files, commands, tasks, branches…", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .onSubmit { run(items.indices.contains(selection) ? items[selection] : items.first) }
                    .onChange(of: query) { selection = 0 }
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
                        Text(cmd.kind.rawValue).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(index == selection ? Theme.accent.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { run(cmd) }
                    .id(cmd.id)
                }
                .listStyle(.plain)
                .onChange(of: selection) { if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) } }
            }
            .frame(height: 320)
            if items.isEmpty { Text("No matching command").font(.caption).foregroundStyle(Theme.textSecondary).padding(8) }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
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

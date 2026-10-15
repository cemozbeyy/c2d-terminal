import AppKit
import C2DCore
import SwiftUI

struct ExplorerPanelView: View {
    @Bindable var explorer: ExplorerController
    let workspace: WorkspaceController
    @State private var naming: (kind: String, directory: String, entry: FileEntry?)?
    @State private var newName = ""
    @State private var trashTarget: FileEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: explorer.rootPath).lastPathComponent).font(.caption).bold().lineLimit(1)
                Spacer()
                Toggle(isOn: $explorer.includeHidden) { Image(systemName: "eye") }.toggleStyle(.button).controlSize(.small).help("Show hidden files")
                    .onChange(of: explorer.includeHidden) { explorer.reloadAll() }
                Button { explorer.reloadAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh")
            }
            .padding(.horizontal, 8).frame(height: 24)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattened()) { item in
                        row(item.entry, depth: item.depth)
                    }
                }
                .padding(.vertical, 4)
            }
            if let err = explorer.lastError {
                Text(err).font(.caption).foregroundStyle(Theme.warning).padding(6)
            }
        }
        .sheet(isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) { namingSheet }
        .alert("Move to Trash?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("Move to Trash", role: .destructive) { if let t = trashTarget { explorer.trash(t) }; trashTarget = nil }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: { Text("\(trashTarget?.path ?? "") will be moved to the Trash on disk. This is the real file, not just the list entry.") }
    }

    private struct Item: Identifiable {
        let entry: FileEntry
        let depth: Int
        var id: String { entry.id }
    }

    /// Depth-first flattening of the expanded tree; recursion in data, not in view types.
    private func flattened() -> [Item] {
        var out: [Item] = []
        func walk(_ directory: String, _ depth: Int) {
            for entry in explorer.entries(in: directory) {
                out.append(Item(entry: entry, depth: depth))
                if entry.isDirectory && explorer.expanded.contains(entry.path) { walk(entry.path, depth + 1) }
            }
        }
        walk(explorer.rootPath, 0)
        return out
    }

    private func row(_ entry: FileEntry, depth: Int) -> some View {
        HStack(spacing: 4) {
            if entry.isDirectory {
                Image(systemName: explorer.expanded.contains(entry.path) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text").foregroundStyle(entry.isDirectory ? Theme.info : Theme.textSecondary).font(.system(size: 11))
            Text(entry.name).font(.system(size: 12)).lineLimit(1)
            if entry.isSymlink { Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(Theme.textSecondary) }
            Spacer()
            if let badge = workspace.git.badges[entry.path] {
                Text(badge).font(.system(size: 10, design: .monospaced)).bold()
                    .foregroundStyle(badge == "D" ? Color.red : badge == "U" || badge == "A" ? Color.green : Color.yellow)
                    .padding(.trailing, 8).accessibilityLabel("git status \(badge)")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 8).padding(.vertical, 2)
        .background(explorer.selectedPath == entry.path ? Theme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            explorer.selectedPath = entry.path
            if entry.isDirectory { explorer.toggle(entry) } else { workspace.openFile(path: entry.path) }
        }
        .contextMenu {
            if !entry.isDirectory { Button("Open") { workspace.openFile(path: entry.path) } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
            Divider()
            let dir = entry.isDirectory ? entry.path : entry.url.deletingLastPathComponent().path
            Button("New File…") { newName = ""; naming = ("file", dir, nil) }
            Button("New Folder…") { newName = ""; naming = ("folder", dir, nil) }
            Button("Rename…") { newName = entry.name; naming = ("rename", dir, entry) }
            Divider()
            Button("Move to Trash…", role: .destructive) { trashTarget = entry }
        }
        .accessibilityLabel("\(entry.isDirectory ? "Folder" : "File") \(entry.name)")
    }

    private var namingSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(naming?.kind == "rename" ? "Rename" : naming?.kind == "folder" ? "New Folder" : "New File").font(.headline)
            Text("In \(naming?.directory ?? "")").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(commitNaming)
            HStack { Spacer(); Button("Cancel") { naming = nil }; Button("OK", action: commitNaming).keyboardShortcut(.defaultAction) }
        }
        .padding(16).frame(width: 380)
    }

    private func commitNaming() {
        guard let n = naming else { return }
        switch n.kind {
        case "file": if let p = explorer.createFile(in: n.directory, name: newName) { workspace.openFile(path: p) }
        case "folder": explorer.createFolder(in: n.directory, name: newName)
        case "rename": if let e = n.entry, let p = explorer.rename(e, to: newName), !e.isDirectory { workspace.fileRenamed(from: e.path, to: p) }
        default: break
        }
        naming = nil
    }
}

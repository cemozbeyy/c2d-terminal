import AppKit
import C2DCore
import SwiftUI

struct ExplorerPanelView: View {
    @Bindable var explorer: ExplorerController
    let workspace: WorkspaceController
    @State private var naming: (kind: String, directory: String, entry: FileEntry?)?
    @State private var newName = ""
    @State private var trashTarget: FileEntry?
    @State private var hoveredPath: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: explorer.rootPath).lastPathComponent).font(.caption).bold().lineLimit(1)
                Spacer()
                Toggle(isOn: $explorer.includeHidden) { Image(systemName: "eye") }.toggleStyle(.button).controlSize(.small).clickCursor().help("Show hidden files")
                    .onChange(of: explorer.includeHidden) { explorer.reloadAll() }
                Button { explorer.reloadAll() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.clickPlain).help("Refresh")
            }
            .padding(.horizontal, 8).frame(height: 24)
            Divider()
            ScrollView {
                let badges = workspace.git.badges
                let dirty = Self.dirtyFolders(badges.keys, root: explorer.rootPath)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattened()) { item in
                        row(item.entry, depth: item.depth, badge: badges[item.entry.path], dirty: dirty.contains(item.entry.path))
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

    /// Every folder above a changed path, so a collapsed folder still shows VS Code's change dot.
    static func dirtyFolders(_ paths: some Sequence<String>, root: String) -> Set<String> {
        var out = Set<String>()
        for p in paths {
            var dir = (p as NSString).deletingLastPathComponent
            while dir.count > root.count, out.insert(dir).inserted { dir = (dir as NSString).deletingLastPathComponent }
        }
        return out
    }

    static func badgeColor(_ badge: String) -> Color {
        badge == "D" || badge == "C" ? Theme.error : badge == "U" || badge == "A" ? Theme.success : Theme.warning
    }

    private func row(_ entry: FileEntry, depth: Int, badge: String?, dirty: Bool) -> some View {
        HStack(spacing: 4) {
            if entry.isDirectory {
                Image(systemName: explorer.expanded.contains(entry.path) ? "chevron.down" : "chevron.right").font(Theme.Typography.micro).frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            let style = entry.isDirectory ? (explorer.expanded.contains(entry.path) ? "folder" : "folder.fill", Theme.info) : FileIcon.style(for: entry.name)
            Image(systemName: style.0).foregroundStyle(style.1).font(Theme.Typography.body).frame(width: 16)
            // VS Code tints a changed file's name, and a folder holding changes, by git status
            Text(entry.name).font(Theme.Typography.title2).lineLimit(1)
                .foregroundStyle(badge.map(Self.badgeColor) ?? (dirty ? Theme.warning : Theme.textPrimary))
                .strikethrough(badge == "D")
            if entry.isSymlink { Image(systemName: "arrow.turn.down.right").font(.system(size: 8)).foregroundStyle(Theme.textSecondary) }
            Spacer()
            if let badge {
                Text(badge).font(Theme.Typography.monoMetadata).bold()
                    .foregroundStyle(Self.badgeColor(badge))
                    .padding(.trailing, 8).accessibilityLabel("git status \(badge)")
            } else if dirty {
                Circle().fill(Theme.warning.opacity(0.8)).frame(width: 6, height: 6)
                    .padding(.trailing, 10).accessibilityLabel("contains changes")
            }
        }
        .padding(.leading, CGFloat(depth) * 16 + 8).frame(height: 22)
        // indent guides, one per ancestor level
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(Theme.borderSubtle).frame(width: 1).padding(.leading, 12).frame(width: 16, alignment: .leading)
                }
            }
            .padding(.leading, 8)
        }
        .background(explorer.selectedPath == entry.path ? Theme.accentSoft : hoveredPath == entry.path ? Theme.elevated : .clear)
        .contentShape(Rectangle()).clickCursor()
        .onHover { hoveredPath = $0 ? entry.path : (hoveredPath == entry.path ? nil : hoveredPath) }
        .clickCursor().onTapGesture {
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

/// Symbol and tint per file type so a tree is scannable at a glance (VS-Code-style file icons, SF Symbols only).
enum FileIcon {
    static func style(for name: String) -> (String, Color) {
        let lower = name.lowercased()
        if lower == "dockerfile" || lower.hasPrefix("docker-compose") { return ("shippingbox.fill", Theme.info) }
        if lower.hasSuffix(".lock") || lower.hasSuffix("-lock.json") || lower.hasSuffix("-lock.yaml") { return ("lock.fill", Theme.textMuted) }
        switch (lower as NSString).pathExtension {
        case "swift": return ("swift", .orange)
        case "js", "mjs", "cjs", "jsx": return ("curlybraces", .yellow)
        case "ts", "tsx", "mts": return ("curlybraces", Theme.info)
        case "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "cs", "php": return ("chevron.left.forwardslash.chevron.right", .mint)
        case "sh", "zsh", "bash", "fish", "command": return ("terminal.fill", Theme.success)
        case "md", "markdown", "txt", "rst": return ("text.alignleft", Theme.accent)
        case "json", "yml", "yaml", "toml", "plist", "xml", "ini", "env", "cfg", "conf": return ("gearshape.fill", .purple)
        case "html", "htm", "vue", "svelte": return ("chevron.left.slash.chevron.right", .orange)
        case "css", "scss", "sass", "less": return ("paintbrush.fill", .pink)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "heic": return ("photo.fill", .pink)
        case "pdf": return ("doc.richtext.fill", Theme.error)
        case "sqlite", "db", "sql": return ("cylinder.fill", .teal)
        case "zip", "tar", "gz", "dmg": return ("archivebox.fill", Theme.textMuted)
        case "xcodeproj", "xcworkspace", "pbxproj": return ("hammer.fill", Theme.info)
        default: return ("doc.text", Theme.textSecondary)
        }
    }
}

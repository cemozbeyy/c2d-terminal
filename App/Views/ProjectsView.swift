import AppKit
import C2DCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var relocating: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects").font(.title2)
                Spacer()
                Button { chooseFolder() } label: { Label("Open Folder…", systemImage: "folder.badge.plus") }
            }
            if model.registry.projects.isEmpty {
                VStack(spacing: 8) {
                    Text("No recent projects").font(.headline)
                    Text("Open a local folder to start a terminal in it.").foregroundStyle(.secondary)
                    Button("Open Folder…") { chooseFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.registry.projects) { project in
                        ProjectRow(project: project, isActive: model.workspace?.projectPath == project.path,
                                   open: { model.openProject(project) },
                                   relocate: { relocating = project; chooseFolder() },
                                   remove: { model.removeProject(project) },
                                   pin: { model.setPinned(!project.pinned, project) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: .c2dOpenProject)) { _ in chooseFolder() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = relocating == nil ? "Open Project" : "Locate \(relocating!.name)"
        guard panel.runModal() == .OK, let url = panel.url else { relocating = nil; return }
        if let r = relocating { model.relocateProject(r, to: url); relocating = nil } else { model.openProject(at: url) }
    }
}

struct ProjectRow: View {
    let project: Project
    let isActive: Bool
    let open: () -> Void
    let relocate: () -> Void
    let remove: () -> Void
    let pin: () -> Void

    var body: some View {
        let available = project.isAvailable
        HStack {
            Image(systemName: available ? (project.pinned ? "pin.fill" : "folder") : "questionmark.folder")
                .foregroundStyle(available ? Color.accentColor : .orange)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(project.name).bold()
                    if isActive { Text("active").font(.caption).foregroundStyle(.secondary) }
                }
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !available { Text("Folder not found").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if available {
                Button("Open", action: open).buttonStyle(.borderedProminent)
            } else {
                Button("Locate…", action: relocate)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if available { open() } }
        .contextMenu {
            Button(project.pinned ? "Unpin" : "Pin", action: pin)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }.disabled(!available)
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.path, forType: .string) }
            Divider()
            Button("Remove from Recent", role: .destructive, action: remove)
        }
        .padding(.vertical, 4)
    }
}

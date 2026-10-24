import AppKit
import C2DCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Projects").font(.title2)
                Spacer()
                Button { model.promptOpenProject() } label: { Label("Open Folder…", systemImage: "folder.badge.plus") }
            }
            if model.registry.projects.isEmpty {
                VStack(spacing: 8) {
                    Text("No recent projects").font(.headline)
                    Text("Open a local folder to start a terminal in it.").foregroundStyle(Theme.textSecondary)
                    Button("Open Folder…") { model.promptOpenProject() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.registry.projects) { project in
                            ProjectRow(project: project, isActive: model.workspace?.projectPath == project.path,
                                       open: { model.openProject(project) },
                                       relocate: { model.promptRelocate(project) },
                                       remove: { model.removeProject(project) },
                                       pin: { model.setPinned(!project.pinned, project) })
                            .padding(10)
                            .panelCard()
                        }
                    }
                }
            }
        }
        .padding(16)
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
            IconTile(symbol: available ? (project.pinned ? "pin.fill" : "folder.fill") : "questionmark.folder", tint: available ? Theme.accent : Theme.warning, size: 34)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(project.name).bold()
                    if isActive { StatusChip(text: "active", color: Theme.success, symbol: "circle.fill") }
                }
                Text(project.path).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                if !available { Text("Folder not found").font(.caption).foregroundStyle(Theme.warning) }
            }
            Spacer()
            if available {
                Button("Open", action: open).buttonStyle(.clickProminent)
            } else {
                Button("Locate…", action: relocate)
            }
        }
        .contentShape(Rectangle()).clickCursor()
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

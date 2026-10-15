import AppKit
import C2DCore
import Foundation
import Observation

/// A lazily expanded directory tree over the real filesystem. Re-lists on expansion and on
/// watcher hints; never trusts a cached listing after a change (Bible Part 5 §3.6).
@MainActor
@Observable
final class ExplorerController {
    let rootPath: String
    private(set) var children: [String: [FileEntry]] = [:]   // directory path → entries
    private(set) var errors: [String: String] = [:]           // directory path → listing error
    var expanded: Set<String> = []
    var includeHidden = false
    var selectedPath: String?
    var lastError: String?

    init(rootPath: String) {
        self.rootPath = rootPath
        expanded.insert(rootPath)
        reload(rootPath)
    }

    func entries(in directory: String) -> [FileEntry] {
        children[directory] ?? []
    }

    func toggle(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            reload(entry.path)
        }
    }

    func reload(_ directory: String) {
        do {
            children[directory] = try DirectoryListing.list(URL(fileURLWithPath: directory), includeHidden: includeHidden)
            errors[directory] = nil
        } catch {
            children[directory] = []
            errors[directory] = error.localizedDescription
        }
    }

    func reloadAll() {
        for dir in expanded { reload(dir) }
    }

    /// Watcher hint: refresh the affected expanded directories only.
    func filesChanged(_ paths: [String]) {
        var dirs = Set<String>()
        for p in paths {
            let dir = FileManager.default.fileExists(atPath: p) && isDirectory(p) ? p : URL(fileURLWithPath: p).deletingLastPathComponent().path
            if expanded.contains(dir) { dirs.insert(dir) }
            if expanded.contains(p) { dirs.insert(p) }
        }
        for d in dirs { reload(d) }
    }

    private func isDirectory(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    // MARK: File operations (Bible Part 5 §3.4) — explicit targets, no silent overwrite

    func createFile(in directory: String, name: String) -> String? {
        let target = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        guard validName(name), !FileManager.default.fileExists(atPath: target) else { lastError = "\(name) already exists or is not a valid name."; return nil }
        guard FileManager.default.createFile(atPath: target, contents: Data()) else { lastError = "Could not create \(name)."; return nil }
        reload(directory); expanded.insert(directory)
        return target
    }

    func createFolder(in directory: String, name: String) {
        let target = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        guard validName(name), !FileManager.default.fileExists(atPath: target) else { lastError = "\(name) already exists or is not a valid name."; return }
        do { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false) } catch { lastError = "\(error.localizedDescription)" }
        reload(directory)
    }

    func rename(_ entry: FileEntry, to name: String) -> String? {
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name).path
        guard validName(name) else { lastError = "Invalid name."; return nil }
        guard !FileManager.default.fileExists(atPath: target) else { lastError = "\(name) already exists; rename refused rather than overwrite."; return nil }
        do {
            try FileManager.default.moveItem(atPath: entry.path, toPath: target)
            reload(entry.url.deletingLastPathComponent().path)
            return target
        } catch { lastError = "\(error.localizedDescription)"; return nil }
    }

    /// Moves to the Trash (recoverable), never a permanent delete.
    func trash(_ entry: FileEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            reload(entry.url.deletingLastPathComponent().path)
        } catch { lastError = "\(error.localizedDescription)" }
    }

    private func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}

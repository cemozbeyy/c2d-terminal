import Foundation

/// One entry of a real directory. Never cached as truth; re-list on change.
public struct FileEntry: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let size: Int64?
    public var id: String { url.path }
    public var path: String { url.path }
}

public enum DirectoryListing {
    /// Directories first, then files, case-insensitive. Hidden entries included only on request.
    /// Permission problems surface as errors; nothing is silently skipped.
    public static func list(_ directory: URL, includeHidden: Bool = false) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .nameKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        var entries: [FileEntry] = []
        for url in urls {
            let v = try url.resourceValues(forKeys: Set(keys))
            let hidden = v.isHidden ?? url.lastPathComponent.hasPrefix(".")
            if hidden && !includeHidden { continue }
            // A symlink to a directory is listed as a directory so it can be expanded; the flag stays visible.
            var isDir = v.isDirectory ?? false
            if v.isSymbolicLink == true {
                var d: ObjCBool = false
                isDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            }
            entries.append(FileEntry(url: url, name: v.name ?? url.lastPathComponent, isDirectory: isDir,
                                     isSymlink: v.isSymbolicLink ?? false, isHidden: hidden, size: v.fileSize.map(Int64.init)))
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

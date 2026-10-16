import Darwin
import Foundation

/// What the kernel reports about a session's processes right now (Bible §3.6 "developer details",
/// Part 4 §5.1–5.2). Nothing here is parsed from terminal text.
public struct PTYProcessContext: Sendable, Hashable {
    /// The shell's working directory as the kernel reports it; nil when the lookup fails.
    public var currentDirectory: String?
    /// Leader of the foreground process group when it is not the shell itself.
    public var foregroundPID: pid_t?
    public var foregroundCommand: String?

    public init(currentDirectory: String? = nil, foregroundPID: pid_t? = nil, foregroundCommand: String? = nil) {
        self.currentDirectory = currentDirectory
        self.foregroundPID = foregroundPID
        self.foregroundCommand = foregroundCommand
    }
}

enum ProcessProbe {
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Direct children, oldest first (kernel order). Empty when the lookup fails.
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(buffer.prefix(Int(n)))
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

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

    /// Every descendant of `pid` (children, grandchildren, …), nearest first. Bounded so a fork bomb
    /// cannot spin this forever.
    static func descendants(of pid: pid_t, limit: Int = 4096) -> [pid_t] {
        var out: [pid_t] = []
        var queue = children(of: pid)
        var seen: Set<pid_t> = [pid]
        while let next = queue.first, out.count < limit {
            queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            queue += children(of: next)
        }
        return out
    }

    /// Processes whose controlling terminal is `device` (`KERN_PROC_TTY`). Only meaningful while the
    /// session leader is alive: when it exits the kernel revokes the tty for the whole session and
    /// this list becomes empty even though descendants may still run.
    static func processes(onTTY device: dev_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(truncatingIfNeeded: device))]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = buffer.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
    }

    /// Kernel-recorded start time of `pid`, or nil when the process no longer exists. Unchanged by
    /// `exec`, so `(pid, startTime)` identifies one process even if the pid number is later reused.
    static func startTime(of pid: pid_t) -> (seconds: UInt64, microseconds: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

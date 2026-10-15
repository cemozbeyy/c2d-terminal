import Foundation
import os

/// Unified logging entry points. One subsystem, one category per module.
/// Never log secrets, environment variables, or terminal contents through these.
public enum Log {
    public static let subsystem = "works.c2d.terminal"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let pty = Logger(subsystem: subsystem, category: "pty")
    public static let git = Logger(subsystem: subsystem, category: "git")
}

/// Facts about the running build and host, for the About/diagnostics surface and bug reports.
/// Contains no user data.
public struct DiagnosticsReport: Sendable, Equatable {
    public let appVersion: String
    public let buildNumber: String
    public let osVersion: String
    public let architecture: String

    public init(appVersion: String, buildNumber: String, osVersion: String, architecture: String) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.osVersion = osVersion
        self.architecture = architecture
    }

    /// Reads version info from the main bundle; falls back to "unknown" outside an app bundle (e.g. `swift test`).
    public static func current() -> DiagnosticsReport {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return DiagnosticsReport(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            architecture: arch
        )
    }

    public var summary: String {
        "C2D Terminal \(appVersion) (\(buildNumber)) · macOS \(osVersion) · \(architecture)"
    }
}

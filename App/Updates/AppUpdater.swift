import AppKit
import Sparkle

/// Sparkle 2 updater (ADR-039). UI layer only; C2DCore never links Sparkle.
///
/// Feed resolution, first match wins:
///   1. user default `C2DUpdateFeedURL` (local/beta testing: `defaults write works.c2d.terminal C2DUpdateFeedURL http://127.0.0.1:8000/appcast.xml`)
///   2. Info.plist `SUFeedURL` (build setting `C2D_UPDATE_FEED_URL`, default https://c2dterminal.com/appcast.xml)
///
/// Without an EdDSA public key in Info.plist (`SUPublicEDKey`, injected by the release signer) Sparkle refuses to
/// install anything — the right behaviour for unsigned local builds; "Check for Updates…" then reports the error.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    nonisolated static let feedOverrideKey = "C2DUpdateFeedURL"

    private(set) var controller: SPUStandardUpdaterController!
    /// Why Sparkle refused to start, if it did (ad-hoc build without `SUPublicEDKey` is the usual reason). `nil` = running.
    private(set) var startError: Error?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do { try controller.updater.start() } catch { startError = error }
    }

    var canCheckForUpdates: Bool { startError == nil && controller.updater.canCheckForUpdates }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// One line for `-c2dSparkleCheck` / diagnostics: did the updater start, where does it look, which version is it.
    var statusLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String).map { $0.isEmpty ? "absent" : "present" } ?? "absent"
        let state = startError.map { "not started: \($0.localizedDescription)" } ?? "started, canCheck=\(controller.updater.canCheckForUpdates)"
        return "sparkle: \(state) · feed=\(feedDescription) · publicKey=\(key) · app=\(v) (\(b))"
    }

    /// Where the updater will look, for the About/Diagnostics text.
    var feedDescription: String {
        if let o = UserDefaults.standard.string(forKey: Self.feedOverrideKey), !o.isEmpty { return "\(o) (user default override)" }
        return (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).map { $0.isEmpty ? "none" : $0 } ?? "none"
    }

    #if DEBUG
    /// `-c2dSparkleCheck YES`: after printing `statusLine`, ask the feed once and report what Sparkle decided, then exit.
    /// Exercises the real feed fetch, appcast parse and version comparison headlessly (ADR-039 update-logic test).
    /// The delegate callbacks below only act in that mode; an ordinary Debug "Check for Updates…" is left to Sparkle's UI.
    nonisolated private static var headless: Bool { UserDefaults.standard.bool(forKey: "c2dSparkleCheck") }
    func runHeadlessCheck() {
        print(statusLine)
        guard startError == nil else { exit(0) }
        controller.updater.checkForUpdateInformation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("sparkle-check: timeout (no answer in 20 s)"); exit(2) }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard Self.headless else { return }
        print("sparkle-check: found update \(item.displayVersionString) (\(item.versionString)) from \(item.fileURL?.absoluteString ?? "?")"); exit(0)
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard Self.headless else { return }
        print("sparkle-check: no update (\(error.localizedDescription))"); exit(0)
    }
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard Self.headless else { return }
        print("sparkle-check: aborted (\(error.localizedDescription))"); exit(1)
    }
    #endif

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard let o = UserDefaults.standard.string(forKey: Self.feedOverrideKey), !o.isEmpty else { return nil }   // nil → SUFeedURL
        return o
    }
}

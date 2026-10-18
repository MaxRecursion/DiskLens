#if canImport(Sparkle)
import Foundation
import Sparkle

/// Direct edition only: Sparkle 2 auto-update (EdDSA-signed appcast; feed URL and public key in
/// Info.plist as SUFeedURL / SUPublicEDKey — see docs/LICENSING.md and scripts/release/appcast.sh).
/// The Mac App Store target does not link Sparkle, so this file compiles out there and in plain
/// SwiftPM builds.
@MainActor
final class SparkleUpdater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    func checkForUpdates() { controller.checkForUpdates(nil) }
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
#endif

import Foundation
import Observation
import Sparkle

/// Sparkle's standard updater, left unstarted while the build carries no real EdDSA public key,
/// so development builds never show Sparkle's "update error" alert.
@MainActor
@Observable
final class UpdaterService {
    static let placeholderKey = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    init(bundle: Bundle = .main, start: Bool = true) {
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard start, !key.isEmpty, key != Self.placeholderKey else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (build \(build))"
    }
}

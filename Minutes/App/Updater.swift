import Foundation
import Observation
import Sparkle

/// Owns Sparkle. The controller is created by `start()`, not `init()`, so exactly one
/// updater exists and diagnostic modes and the gallery never start one.
///
/// A meeting always wins over an update: background checks are skipped while one runs,
/// and an update the user accepts mid-meeting waits to relaunch until the meeting ends,
/// so an update can never cut a transcript short.
@MainActor @Observable
final class Updater: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var isStarted = false

    var automaticallyChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var isBusy: () -> Bool = { false }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Starts Sparkle once. `isBusy` reports whether a meeting is running.
    func start(isBusy: @escaping () -> Bool) {
        guard controller == nil else { return }
        self.isBusy = isBusy
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        isStarted = true
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Skips scheduled background checks during a meeting (Sparkle tries again at the
    /// next interval). Checks the user asks for always run.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground, isBusy() {
            throw NSError(domain: "com.northwoods.Minutes", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Minutes is transcribing a meeting; update check skipped.",
            ])
        }
    }

    /// Holds the relaunch until the meeting stops, so the final save always happens.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        Task { @MainActor [weak self] in
            while self?.isBusy() == true {
                try? await Task.sleep(for: .seconds(5))
            }
            installHandler()
        }
        return true
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Minutes is a menu bar app. Letting the standard driver show scheduled updates
    /// means it shows them behind other windows unless the Mac was idle or Minutes just
    /// launched, which is the gentle behavior Sparkle asks background apps to opt into.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }
}

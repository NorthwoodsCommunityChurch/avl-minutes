import Foundation

/// Which app the shared Notes code is running inside: Minutes on Aaron's laptop or
/// Hermes Helper on the assistant mini. Logs and user-facing messages use these so
/// neither app reports itself under the other's name.
enum AppIdentity {
    /// The running app's bundle id; also the unified-log subsystem.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.northwoods.Minutes"

    /// "Minutes" or "Hermes Helper".
    static let name: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Minutes"
    }()
}

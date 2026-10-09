import Foundation
import MinutesKit
import OSLog

/// Sends the feed changes Hermes should hear about to the Teams relay on this Mac (`POST /notify`), which
/// asks Hermes and posts her line to Aaron's chat. Reads the relay's port and notify key from its config
/// file, so there is nothing to configure on the helper side.
enum FeedNotifierClient {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "FeedNotifier")
    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("hermes-teams/config/local.json")

    struct Relay { let url: URL; let key: String }

    static func relay() -> Relay? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["notifyKey"] as? String, !key.isEmpty else { return nil }
        let port = json["port"] as? Int ?? 8787
        let host = json["host"] as? String ?? "127.0.0.1"
        guard let url = URL(string: "http://\(host):\(port)/notify") else { return nil }
        return Relay(url: url, key: key)
    }

    /// Posts the lines; returns a short status for the log. Never throws, never blocks longer than 10 s.
    /// `kind` is "feed" (calendar changes, sent mail) or "meeting" (a meeting starting soon); the relay picks the prompt.
    static func send(_ lines: [String], kind: String = "feed") async -> String {
        guard !lines.isEmpty else { return "nothing to send" }
        guard let relay = relay() else { return "relay not configured (no notifyKey in hermes-teams config)" }
        var request = URLRequest(url: relay.url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(relay.key, forHTTPHeaderField: "x-notify-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["records": lines, "kind": kind])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 202 { return "sent \(lines.count) line(s) to the relay" }
            return "relay answered \(status)"
        } catch {
            logger.error("Notify failed: \(error.localizedDescription, privacy: .public)")
            return "relay unreachable: \(error.localizedDescription)"
        }
    }
}

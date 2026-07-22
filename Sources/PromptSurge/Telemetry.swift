import Foundation
import CryptoKit
import UIKit

// MARK: - Wire models

/// Free-form event payload. Only non-nil fields are encoded, producing `{}` for empty events.
struct EventPayload: Encodable {
    /// Copy variant the server served, when it identified one. Nil means "not attributable" —
    /// which is honest, unlike the literal `"api"` this used to send for every prompt.
    var promptId: String?
    /// Locale actually rendered, after the server's fallback chain (`de-DE` → `de` → `en`).
    var resolvedLocale: String?
    /// Must be an integer in JSON — schema rejects string values.
    var servedPromptNumber: Int?
}

struct EventDto: Encodable {
    let eventType: String
    let eventId: String
    let timestamp: String
    let sessionId: String
    let deviceId: String
    let appVersion: String
    let sdkVersion: String
    let locale: String
    let platform: String
    let holdout: Bool
    let payload: EventPayload
}

/// Batch envelope expected by POST /v1/events.
private struct EventBatch: Encodable {
    let events: [EventDto]
}

// MARK: - Telemetry

final class Telemetry {
    static let sdkVersion = "1.1.0"
    private static let platform = "ios"
    private static let firstOpenKey = "ps_first_open_fired"

    private let apiKey: String
    private let apiBaseUrl: String
    let sessionId: String
    private let holdoutManager: HoldoutManager
    private let defaults: UserDefaults
    private let session: URLSession
    private let encoder: JSONEncoder

    init(
        apiKey: String,
        apiBaseUrl: String,
        sessionId: String,
        holdoutManager: HoldoutManager,
        defaults: UserDefaults = .standard
    ) {
        self.apiKey = apiKey
        self.apiBaseUrl = apiBaseUrl
        self.sessionId = sessionId
        self.holdoutManager = holdoutManager
        self.defaults = defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
        self.encoder = JSONEncoder()
    }

    /// Fires `initialize` (every launch) and `first_open` (once per install).
    ///
    /// Neither event was ever sent from iOS, so installs and DAU from iOS apps were invisible
    /// in the dashboard while Android reported both.
    func fireLifecycleEvents() {
        send(eventType: EventTypes.initialize)
        guard !defaults.bool(forKey: Self.firstOpenKey) else { return }
        defaults.set(true, forKey: Self.firstOpenKey)
        send(eventType: EventTypes.firstOpen)
    }

    func send(eventType: String, payload: EventPayload = EventPayload()) {
        let dto = EventDto(
            eventType: eventType,
            eventId: UUID().uuidString,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sessionId: sessionId,
            deviceId: deviceId(),
            appVersion: appVersion(),
            sdkVersion: Self.sdkVersion,
            locale: currentLocaleTag(),
            platform: Self.platform,
            holdout: holdoutManager.isHoldout,
            payload: payload
        )

        // Wrap in batch envelope — server expects { "events": [...] }.
        let batch = EventBatch(events: [dto])
        guard let url = URL(string: "\(apiBaseUrl)/v1/events"),
              let body = try? encoder.encode(batch) else {
            PSLog.error("Could not build the \(eventType) request for apiBaseUrl '\(apiBaseUrl)'.")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-PromptSurge-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        session.dataTask(with: req) { _, response, error in
            if let error {
                PSLog.warning("Event '\(eventType)' was not delivered: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299:
                PSLog.debug("Event '\(eventType)' accepted (HTTP \(status)).")
            case 401, 403:
                PSLog.error("Event '\(eventType)' rejected: the API key is not valid (HTTP \(status)).")
            case 400:
                PSLog.error("Event '\(eventType)' rejected as malformed (HTTP 400) — the SDK and server event schemas disagree.")
            default:
                PSLog.warning("Event '\(eventType)' rejected with HTTP \(status).")
            }
        }.resume()
    }

    // SHA-256(vendorId + bundleId) → stable, non-reversible device fingerprint.
    private func deviceId() -> String {
        let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let raw = vendorId + bundleId
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

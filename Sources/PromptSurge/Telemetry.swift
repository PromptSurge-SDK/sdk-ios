import Foundation
import CryptoKit
import UIKit

// MARK: - Wire models

/// Free-form event payload. Only non-nil fields are encoded, producing `{}` for empty events.
struct EventPayload: Encodable {
    /// Copy variant the server served, when it identified one. Nil means "not attributable" -
    /// which is honest, unlike the literal `"api"` this used to send for every prompt.
    var promptId: String?
    /// Locale actually rendered, after the server's fallback chain (`de-DE` → `de` → `en`).
    var resolvedLocale: String?
    /// Must be an integer in JSON - schema rejects string values.
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
///
/// `verifyToken` is the one-shot app-ownership token from the dashboard's Verify page. The
/// server declares it `.optional()`, which rejects an explicit `null` - the key must be absent
/// when unset. The synthesized `Encodable` uses `encodeIfPresent` for optionals, so a nil here
/// is omitted rather than encoded, which is exactly the behaviour Android needed
/// `explicitNulls = false` for. Internal (not private) so the encoding contract is testable.
struct EventBatch: Encodable {
    let events: [EventDto]
    let verifyToken: String?
}

/// What `POST /v1/events` answers with. Card 349 phase 4.
///
/// `assignment` is present only when the batch spoke for exactly one device AND the server had
/// or could create a row for it. It is the group the SERVER remembers for a device id that
/// survives a reinstall, and it is the whole point of the feature: `UserDefaults` does not
/// survive an uninstall, so without this a reinstalling device flips the coin again and is
/// counted in both groups under one id.
///
/// Every field is optional, so a body missing one - or carrying fields a later server adds -
/// still decodes. Absent `assignment` decodes to nil, which means "keep the local group", never
/// "you are in the treatment group".
struct EventBatchResponse: Decodable {
    struct Assignment: Decodable {
        let holdout: Bool
    }

    let accepted: Int?
    let skipped: Int?
    let assignment: Assignment?
}

// MARK: - Telemetry

final class Telemetry {
    static let sdkVersion = "1.2.0"
    private static let platform = "ios"
    private static let firstOpenKey = "ps_first_open_fired"

    private let apiKey: String
    private let apiBaseUrl: String
    let sessionId: String
    private let holdoutManager: HoldoutManager
    /// One-shot app-ownership token. Rides along with every batch while set - the server
    /// consumes it once, and the integrator removes it from code after the dashboard shows
    /// the app as verified. Mirrors `EventBus.verifyToken` on Android.
    private let verifyToken: String?
    private let defaults: UserDefaults
    private let session: URLSession
    private let encoder: JSONEncoder

    init(
        apiKey: String,
        apiBaseUrl: String,
        sessionId: String,
        holdoutManager: HoldoutManager,
        verifyToken: String? = nil,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.apiBaseUrl = apiBaseUrl
        self.sessionId = sessionId
        self.holdoutManager = holdoutManager
        self.verifyToken = verifyToken
        self.defaults = defaults
        self.encoder = JSONEncoder()
        // `session` is nil in the SDK; the tests pass one that answers without a network.
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
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

        // Wrap in batch envelope - server expects { "events": [...] }.
        let batch = EventBatch(events: [dto], verifyToken: verifyToken)
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

        session.dataTask(with: req) { [holdoutManager = self.holdoutManager] data, response, error in
            if let error {
                PSLog.warning("Event '\(eventType)' was not delivered: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299:
                PSLog.debug("Event '\(eventType)' accepted (HTTP \(status)).")
                // Card 349 phase 4: adopt the group the server remembers for this device, for
                // the NEXT session. Silent on every failure by design - the batch was already
                // accepted, so a body that is missing, truncated or shaped differently from what
                // this SDK version expects must not turn a successful send into a logged
                // failure. The device simply keeps its local group until the next event.
                //
                // Only on 2xx: a server that answered 500 with a JSON error page must never be
                // able to move a device's group.
                if let data,
                   let decoded = try? JSONDecoder().decode(EventBatchResponse.self, from: data),
                   let assignment = decoded.assignment {
                    holdoutManager.adoptFromServer(assignment.holdout)
                }
            case 401, 403:
                PSLog.error("Event '\(eventType)' rejected: the API key is not valid (HTTP \(status)).")
            case 400:
                PSLog.error("Event '\(eventType)' rejected as malformed (HTTP 400) - the SDK and server event schemas disagree.")
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

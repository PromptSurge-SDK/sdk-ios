import Foundation
import CryptoKit
import UIKit

// MARK: - Wire models

/// Free-form event payload. Only non-nil fields are encoded, producing `{}` for empty events.
struct EventPayload: Encodable {
    var promptId: String?
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
    static let sdkVersion = "1.0.1"
    private static let platform = "ios"

    private let apiKey: String
    private let apiBaseUrl: String
    private let sessionId: String
    private let holdoutManager: HoldoutManager
    private let session: URLSession
    private let encoder: JSONEncoder

    init(apiKey: String, apiBaseUrl: String, holdoutManager: HoldoutManager) {
        self.apiKey = apiKey
        self.apiBaseUrl = apiBaseUrl
        self.sessionId = UUID().uuidString
        self.holdoutManager = holdoutManager
        self.session = URLSession(configuration: .ephemeral)
        self.encoder = JSONEncoder()
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
            locale: Locale.current.identifier,
            platform: Self.platform,
            holdout: holdoutManager.isHoldout,
            payload: payload
        )

        // Wrap in batch envelope — server expects { "events": [...] }.
        let batch = EventBatch(events: [dto])
        guard let url = URL(string: "\(apiBaseUrl)/v1/events"),
              let body = try? encoder.encode(batch) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-PromptSurge-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        session.dataTask(with: req).resume()
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

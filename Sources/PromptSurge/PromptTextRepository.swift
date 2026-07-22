import Foundation

/// Outcome of a `/v1/prompts` fetch. Every branch the server can take has a case here, so a
/// caller can no longer confuse "the server said no" with "the server said yes".
enum PromptFetchResult {
    /// Copy to render, from the cache or from the network.
    case prompt(PromptResponse)
    /// 402 — the app is over its monthly impression limit for its tier.
    case limitExceeded
    /// 404 `app_deleted` — the app was deleted in the admin panel.
    case appDeleted
    /// 401/403 — the API key is missing, wrong, or revoked. Never show a dialog for this.
    case unauthorized
    /// Network failure, unparseable body, or an unexpected status. Caller may fall back to
    /// the bundled English copy.
    case unavailable
}

final class PromptTextRepository {
    // Suffixed because the cached shape changed in 1.1.0 (theme field names, optional
    // promptId). A blob written by 1.0.x would decode into a theme with every colour nil.
    private static let cacheKey   = "ps_cached_prompt_v2"
    private static let limitKey   = "ps_impression_limit_exceeded"
    private static let deletedKey = "ps_app_deleted"
    private static let cacheExpiry: TimeInterval = 6 * 3600

    private let apiKey: String
    private let apiBaseUrl: String
    private let sessionId: String
    private let defaults: UserDefaults
    private let session: URLSession

    init(apiKey: String, apiBaseUrl: String, sessionId: String, defaults: UserDefaults = .standard) {
        self.apiKey = apiKey
        self.apiBaseUrl = apiBaseUrl
        self.sessionId = sessionId
        self.defaults = defaults
        // The URLSession defaults are 60 s per request and 7 days per resource, which on a
        // captive portal means a minute of nothing before the caller hears back. Match the
        // Android SDK's OkHttp settings instead.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    /// The server told us this app was deleted. Persisted, cleared by the next 200.
    var isAppDeleted: Bool { defaults.bool(forKey: Self.deletedKey) }

    /// The server told us the monthly impression limit is spent. Persisted, cleared by the
    /// next 200 — which is how it recovers when the billing period rolls over.
    var isImpressionLimitExceeded: Bool { defaults.bool(forKey: Self.limitKey) }

    /// Resolves the prompt to show, consulting the six-hour cache first.
    func fetch(completion: @escaping (PromptFetchResult) -> Void) {
        // Both flags are hard suppressions, so a warm cache must never satisfy the call while
        // one is set: doing that let billing overshoot for up to the full cache lifetime after
        // the limit was hit, and kept serving a dialog for an app that no longer exists.
        if isAppDeleted || isImpressionLimitExceeded {
            let lastVerdict: PromptFetchResult = isAppDeleted ? .appDeleted : .limitExceeded
            fetchAndCache { result in
                if case .unavailable = result {
                    // Offline: keep honouring the last verdict rather than falling back to a
                    // dialog the server has already told us not to show.
                    completion(lastVerdict)
                } else {
                    completion(result)
                }
            }
            return
        }

        if let cached = loadCache() {
            completion(.prompt(cached))
            // Silent refresh so the cache, and both suppression flags, stay current.
            fetchAndCache { _ in }
            return
        }

        fetchAndCache(completion: completion)
    }

    private func fetchAndCache(completion: @escaping (PromptFetchResult) -> Void) {
        // appVersion drives per-version warm-up buckets server-side. Match the value
        // the SDK reports on events so device counts line up. Older servers ignore it.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var comps = URLComponents(string: "\(apiBaseUrl)/v1/prompts")
        comps?.queryItems = [
            // The server reads the `locale` query parameter and nothing else. This SDK used to
            // send an `Accept-Language` header, which the route never inspects — which is why
            // no iOS user had ever received localized copy.
            URLQueryItem(name: "locale", value: currentLocaleTag()),
            // Makes A/B copy selection stable for the lifetime of a session.
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "appVersion", value: version),
        ]
        guard let url = comps?.url else {
            PSLog.error("apiBaseUrl '\(apiBaseUrl)' is not a valid URL — no prompt can be fetched.")
            completion(.unavailable)
            return
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-PromptSurge-Key")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else {
                completion(.unavailable)
                return
            }
            if let error {
                PSLog.warning("Prompt fetch failed: \(error.localizedDescription)")
                completion(.unavailable)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                PSLog.warning("Prompt fetch returned no HTTP response.")
                completion(.unavailable)
                return
            }

            switch http.statusCode {
            case 200...299:
                break
            case 401, 403:
                PSLog.error("""
                    API key rejected (HTTP \(http.statusCode)). Check the key passed to \
                    PromptSurge.initialize(apiKey:) against the one shown in the admin panel at \
                    https://admin.promptsurge.me — it should start with 'ps_live_'. \
                    No pre-prompt will be shown until this is fixed.
                    """)
                completion(.unauthorized)
                return
            case 402:
                self.setFlag(Self.limitKey, true)
                PSLog.warning("Monthly impression limit reached — the native review prompt fires directly. See https://admin.promptsurge.me/billing")
                completion(.limitExceeded)
                return
            case 404:
                if self.indicatesAppDeleted(data) {
                    self.setFlag(Self.deletedKey, true)
                    PSLog.warning("This app was deleted in the PromptSurge admin panel; the pre-prompt is suppressed.")
                    completion(.appDeleted)
                } else {
                    PSLog.warning("Prompt endpoint returned 404 for \(url.absoluteString) — check apiBaseUrl.")
                    completion(.unavailable)
                }
                return
            default:
                PSLog.warning("Prompt fetch returned HTTP \(http.statusCode).")
                completion(.unavailable)
                return
            }

            guard let data else {
                PSLog.warning("Prompt fetch returned an empty body.")
                completion(.unavailable)
                return
            }
            let apiResp: APIPromptResponse
            do {
                apiResp = try JSONDecoder().decode(APIPromptResponse.self, from: data)
            } catch {
                PSLog.error("Prompt response did not match the expected shape and was discarded: \(error)")
                completion(.unavailable)
                return
            }

            // A 200 supersedes both suppression flags — this is how an app recovers from a
            // transient 404 during a deploy, and from a limit that reset with the billing period.
            self.setFlag(Self.limitKey, false)
            self.setFlag(Self.deletedKey, false)

            let mapped = mapAPIResponse(apiResp)
            // Do not cache warm-up responses — they must stay live so the threshold
            // counter can advance and warm-up completion is detected on the next fetch.
            if !mapped.warmup { self.saveCache(mapped) }
            PSLog.info("Prompt fetched (locale=\(mapped.text.locale), warmup=\(mapped.warmup)).")
            completion(.prompt(mapped))
        }.resume()
    }

    // MARK: - Persistence

    private struct ErrorEnvelope: Decodable { let error: String? }

    /// Matches the parsed `error` field rather than searching the raw body, so an unrelated
    /// 404 page that happens to contain the words cannot disable the SDK.
    private func indicatesAppDeleted(_ data: Data?) -> Bool {
        guard let data,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { return false }
        return envelope.error == "app_deleted"
    }

    private func setFlag(_ key: String, _ value: Bool) {
        guard defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
    }

    private func loadCache() -> PromptResponse? {
        guard let data = defaults.data(forKey: Self.cacheKey),
              let wrapper = try? JSONDecoder().decode(CacheWrapper.self, from: data),
              Date().timeIntervalSince(wrapper.savedAt) < Self.cacheExpiry else { return nil }
        return wrapper.response
    }

    private func saveCache(_ response: PromptResponse) {
        let wrapper = CacheWrapper(response: response, savedAt: Date())
        if let data = try? JSONEncoder().encode(wrapper) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private struct CacheWrapper: Codable {
        let response: PromptResponse
        let savedAt: Date
    }
}

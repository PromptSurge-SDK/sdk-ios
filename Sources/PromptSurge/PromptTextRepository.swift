import Foundation

final class PromptTextRepository {
    private static let cacheKey    = "ps_cached_prompt"
    private static let cacheExpiry: TimeInterval = 6 * 3600

    private let apiKey: String
    private let apiBaseUrl: String
    private let defaults: UserDefaults
    private let session: URLSession

    init(apiKey: String, apiBaseUrl: String, defaults: UserDefaults = .standard) {
        self.apiKey = apiKey
        self.apiBaseUrl = apiBaseUrl
        self.defaults = defaults
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Fetches the current prompt.
    ///
    /// On success, calls `onSuccess` with the parsed response (may be nil on a network/parse error).
    /// On 402 (impression limit), calls `onLimitExceeded` — the server is the single source of
    /// truth for billing limits; nothing is cached locally for this signal.
    func fetch(
        onSuccess: @escaping (PromptResponse?) -> Void,
        onLimitExceeded: (() -> Void)? = nil
    ) {
        if let cached = loadCache() {
            onSuccess(cached)
            // Refresh in background (ignore 402 during silent refresh).
            fetchAndCache(onSuccess: { _ in }, onLimitExceeded: nil)
            return
        }
        fetchAndCache(onSuccess: onSuccess, onLimitExceeded: onLimitExceeded)
    }

    private func fetchAndCache(
        onSuccess: @escaping (PromptResponse?) -> Void,
        onLimitExceeded: (() -> Void)?
    ) {
        guard let url = URL(string: "\(apiBaseUrl)/v1/prompts") else {
            onSuccess(nil)
            return
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-PromptSurge-Key")
        req.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")

        session.dataTask(with: req) { [weak self] data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            if statusCode == 402 {
                // Server billing limit — handled transiently, not persisted on device.
                onLimitExceeded?()
                return
            }
            guard let data = data,
                  let apiResp = try? JSONDecoder().decode(APIPromptResponse.self, from: data) else {
                onSuccess(nil)
                return
            }
            let mapped = mapAPIResponse(apiResp)
            // Do not cache warm-up responses — they must stay live so the threshold
            // counter can advance and warm-up completion is detected on the next fetch.
            if !mapped.warmup { self?.saveCache(mapped) }
            onSuccess(mapped)
        }.resume()
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

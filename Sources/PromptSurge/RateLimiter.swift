import Foundation

/// How often a store will actually show its native review UI, as far as the SDK can mirror it.
///
/// The store never tells an app whether a review request displayed anything, so the SDK cannot
/// know how much of the quota is left. What it can know is how many requests it made itself, and
/// it uses that count as the gate: once it has asked as often as the store will answer, it stops
/// asking, and it stops showing the pre-prompt too, because a "Sure" followed by nothing is worse
/// than no dialog at all. Both stores warn against a button that leads to the review API for
/// exactly that reason.
///
/// What the count cannot see: requests the host app makes itself through StoreKit, and requests
/// the store silently declined. So it can err either way, and the rule is the store's published
/// limit rather than a guess at the remainder.
struct ReviewQuota: Equatable {
    /// Requests allowed inside `window`.
    let limit: Int
    /// Rolling window, in seconds.
    let window: TimeInterval

    /// Apple shows the rating sheet at most three times in 365 days, per app, per device.
    static let appStore = ReviewQuota(limit: 3, window: 365 * 24 * 3600)

    /// Epoch seconds at which the next request becomes possible, or nil when one is possible now.
    ///
    /// Pure, so the rule can be tested without a clock or a store. With `k` requests inside the
    /// window and a limit of `n`, the count drops below `n` when the request at position `k - n`
    /// (oldest first) ages out.
    func nextPossibleRequest(requests: [TimeInterval], now: TimeInterval) -> TimeInterval? {
        let recent = requests.filter { now - $0 < window }.sorted()
        guard recent.count >= limit else { return nil }
        return recent[recent.count - limit] + window
    }
}

/// The local gates on the review moment: the two pre-prompt cooldowns, and the store's own review
/// quota mirrored from the SDK's record of its native requests (`ReviewQuota`).
final class RateLimiter {
    private static let shownKey = "ps_last_shown_at"
    private static let dismissedKey = "ps_last_dismissed_at"
    /// Epoch seconds of the SDK's own native review requests, oldest first. Capped at
    /// `maxStoredRequests`, which only has to be at least the quota's limit.
    static let nativeRequestsKey = "ps_native_review_requests"
    static let maxStoredRequests = 5

    private static let shownCooldown: TimeInterval = 90 * 24 * 3600
    private static let dismissedCooldown: TimeInterval = 7 * 24 * 3600

    private let defaults: UserDefaults
    private let now: () -> Date
    let quota: ReviewQuota

    /// - Parameter now: the clock. Injectable so the tests can move time instead of waiting a year.
    init(defaults: UserDefaults = .standard, quota: ReviewQuota = .appStore, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.quota = quota
        self.now = now
    }

    var canShow: Bool {
        let now = self.now()
        if let shown = defaults.object(forKey: Self.shownKey) as? Date,
           now.timeIntervalSince(shown) < Self.shownCooldown {
            return false
        }
        if let dismissed = defaults.object(forKey: Self.dismissedKey) as? Date,
           now.timeIntervalSince(dismissed) < Self.dismissedCooldown {
            return false
        }
        return true
    }

    func recordShown() {
        defaults.set(now(), forKey: Self.shownKey)
    }

    func recordDismissed() {
        defaults.set(now(), forKey: Self.dismissedKey)
    }

    // MARK: - Store review quota

    /// When the SDK's own native requests have used up the store's quota, the moment the next one
    /// becomes possible. Nil when a request is possible now.
    var quotaBlockedUntil: Date? {
        guard let next = quota.nextPossibleRequest(
            requests: nativeRequests,
            now: now().timeIntervalSince1970
        ) else { return nil }
        return Date(timeIntervalSince1970: next)
    }

    /// Call on EVERY native review request the SDK makes - the confirm path and every path that
    /// asks without a dialog (holdout, warm-up, impression limit). Keeps the last few entries only.
    func recordNativeRequest() {
        var all = nativeRequests
        all.append(now().timeIntervalSince1970)
        defaults.set(Array(all.suffix(Self.maxStoredRequests)), forKey: Self.nativeRequestsKey)
    }

    /// The stored request timestamps, epoch seconds, oldest first.
    var nativeRequests: [TimeInterval] {
        (defaults.array(forKey: Self.nativeRequestsKey) as? [TimeInterval]) ?? []
    }
}

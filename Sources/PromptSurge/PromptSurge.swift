import UIKit
import StoreKit

/// Entry point for the PromptSurge iOS SDK.
///
/// Call `initialize(apiKey:)` once at app launch, then call `requestReview(in:)`
/// at a natural moment in the user journey (e.g. after completing a level or purchase).
///
/// Everything the SDK decides - a suppressed dialog, a rejected key, a failed fetch - is
/// written to the unified log under subsystem `com.promptsurge.sdk`. Errors and warnings are
/// always emitted; call `setLogLevel(.info)` while integrating for one line per decision.
public final class PromptSurge {
    private static var shared: PromptSurge?
    private static let optOutKey = "com.promptsurge.optedOut"

    private let repository: PromptTextRepository
    private let telemetry: Telemetry
    private let rateLimiter: RateLimiter
    private let holdoutManager: HoldoutManager

    /// Asks iOS for the rating sheet from the presenter's window scene and returns false when it
    /// has none. The only place the SDK reaches StoreKit's review API. A property rather than a
    /// call so the tests can count requests: no unit test has a window scene to hand it.
    var nativeReviewRequest: (UIViewController) -> Bool = PromptSurge.askSystemForReview(from:)

    /// True between a `requestReview(in:)` call and its dialog being resolved. Stops two calls
    /// from stacking two dialogs. Only ever touched on the main queue.
    private var isRequestInFlight = false

    private convenience init(apiKey: String, apiBaseUrl: String, verifyToken: String?) {
        let holdout = HoldoutManager()
        // One session id shared by the prompt fetch and every event, so the server can select
        // a copy variant deterministically and the events attribute to that same session.
        let sessionId = UUID().uuidString
        self.init(
            repository: PromptTextRepository(apiKey: apiKey, apiBaseUrl: apiBaseUrl, sessionId: sessionId),
            telemetry: Telemetry(
                apiKey: apiKey,
                apiBaseUrl: apiBaseUrl,
                sessionId: sessionId,
                holdoutManager: holdout,
                verifyToken: verifyToken
            ),
            rateLimiter: RateLimiter(),
            holdoutManager: holdout
        )
    }

    /// Every dependency handed in. Internal so the tests can build an instance on their own
    /// `UserDefaults` suite and clock; the public entry point is `initialize(apiKey:)`.
    init(repository: PromptTextRepository, telemetry: Telemetry, rateLimiter: RateLimiter, holdoutManager: HoldoutManager) {
        self.repository = repository
        self.telemetry = telemetry
        self.rateLimiter = rateLimiter
        self.holdoutManager = holdoutManager
    }

    // MARK: - Public API

    /// - Parameter verifyToken: optional one-shot app-ownership token from the PromptSurge
    ///   dashboard's Verify page. It rides along with the event batches and can be removed from
    ///   your code once the dashboard shows the app as verified.
    public static func initialize(apiKey: String, verifyToken: String? = nil, apiBaseUrl: String = "https://api.promptsurge.me") {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            PSLog.error("initialize(apiKey:) was called with an empty key. The SDK is not active; requestReview(in:) will do nothing. Copy your key from https://admin.promptsurge.me.")
            shared = nil
            return
        }
        if key != apiKey {
            PSLog.warning("The API key had surrounding whitespace, which has been trimmed.")
        }
        if !key.hasPrefix("ps_live_") {
            PSLog.warning("The API key does not start with 'ps_live_'. Check you have not pasted an Android or Unity key, or an admin session token.")
        }

        let token = verifyToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instance = PromptSurge(
            apiKey: key,
            apiBaseUrl: apiBaseUrl,
            verifyToken: (token?.isEmpty == false) ? token : nil
        )
        shared = instance
        PSLog.info("Initialized (sdkVersion \(Telemetry.sdkVersion), apiBaseUrl \(apiBaseUrl)).")
        instance.telemetry.fireLifecycleEvents()
    }

    /// Sets how much the SDK writes to the unified log. Errors and warnings are always logged;
    /// this raises the floor for informational output. Safe to call before `initialize`.
    public static func setLogLevel(_ level: PromptSurgeLogLevel) {
        PSLog.level = level
    }

    /// Warms the prompt cache in the background without showing any dialog.
    ///
    /// Call this early (e.g. in `applicationDidFinishLaunching`) so the prompt text is already
    /// cached when `requestReview(in:)` is called later, eliminating the network round-trip
    /// delay at the moment of the request. Safe to call multiple times - a fresh cache is served
    /// immediately and revalidated in the background, so this always costs one request.
    public static func prefetch() {
        guard let shared else {
            PSLog.error("prefetch() was called before initialize(apiKey:) - nothing was fetched.")
            return
        }
        shared.repository.fetch { _ in }
    }

    /// Presents the pre-prompt dialog from `viewController` if the cooldowns, the App Store's
    /// review quota and the holdout group allow. Does nothing if `initialize` has not been called
    /// or if the user has opted out; both cases are logged rather than swallowed.
    public static func requestReview(in viewController: UIViewController) {
        guard !isOptedOut else {
            PSLog.info("requestReview ignored: this user has opted out.")
            return
        }
        guard let shared else {
            PSLog.error("requestReview(in:) was called before initialize(apiKey:) - no dialog will appear. Call PromptSurge.initialize(apiKey:) at app launch.")
            return
        }
        shared.showDialog(from: viewController)
    }

    /// Opt this user out of all PromptSurge pre-prompt dialogs permanently (until `optIn()` is called).
    /// Persisted in UserDefaults across launches. Safe to call before `initialize`.
    public static func optOut() {
        UserDefaults.standard.set(true, forKey: optOutKey)
    }

    /// Re-enable pre-prompt dialogs for this user after a previous `optOut()` call.
    public static func optIn() {
        UserDefaults.standard.set(false, forKey: optOutKey)
    }

    /// Whether the user has opted out of review prompts.
    public static var isOptedOut: Bool {
        UserDefaults.standard.bool(forKey: optOutKey)
    }

    // MARK: - Internal

    /// Internal rather than private so the tests can drive one decision without `shared`.
    func showDialog(from presenter: UIViewController) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showDialog(from: presenter) }
            return
        }
        guard !isRequestInFlight else {
            PSLog.info("requestReview ignored: a request is already in flight.")
            return
        }
        guard rateLimiter.canShow else {
            PSLog.info("requestReview ignored: still inside the cooldown window (90 days after a shown prompt, 7 after a dismissal).")
            return
        }

        // The App Store's own quota, checked before anything else can reach StoreKit. A "Sure"
        // that opens nothing is the failure both stores warn about, so when the quota is spent
        // there is no pre-prompt AND no native call. Deliberately ahead of the holdout branch:
        // both arms of the experiment skip under the same rule, so neither one is credited with
        // requests iOS would not have shown (Faeden card 615).
        if let next = rateLimiter.quotaBlockedUntil {
            let quota = rateLimiter.quota
            PSLog.info("requestReview ignored: the SDK has already asked iOS for the rating sheet \(quota.limit) times in the last \(Int(quota.window / 86_400)) days, the most iOS will show, so there is no pre-prompt and no native request this time. Next request possible after \(ISO8601DateFormatter().string(from: next)).")
            return
        }

        // Holdout group - skip pre-prompt but still fire native review as a baseline.
        if holdoutManager.isHoldout {
            fireNativeReview(from: presenter, reason: "this device is in the holdout group")
            return
        }

        isRequestInFlight = true
        repository.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRequestInFlight = false

                switch result {
                case .prompt(let response):
                    if response.warmup {
                        // Warm-up phase: fire native review to build baseline, never show dialog.
                        self.fireNativeReview(from: presenter, reason: "the app is still in its warm-up phase")
                    } else {
                        self.present(response, from: presenter)
                    }
                case .limitExceeded:
                    self.fireNativeReview(from: presenter, reason: "the monthly impression limit is spent")
                case .appDeleted:
                    self.fireNativeReview(from: presenter, reason: "this app was deleted in the admin panel")
                case .unauthorized:
                    // A rejected key is a configuration bug, not a network blip. Showing bundled
                    // English copy here is what made a broken key look like a working install.
                    PSLog.warning("No pre-prompt shown: the API key was rejected. The native review prompt fires instead.")
                    self.fireNativeReview(from: presenter, reason: "the API key was rejected")
                case .unavailable:
                    PSLog.info("Server unreachable; showing the bundled English copy.")
                    self.present(PromptResponse.bundledDefault, from: presenter)
                }
            }
        }
    }

    /// Asks iOS for the rating sheet, records the request against the review quota, and fires
    /// its telemetry event. Every native request goes through here: the confirm path, holdout,
    /// warm-up, the impression limit, a deleted app and a rejected key.
    /// - Parameter recordCooldown: pass `false` when the 90-day cooldown was already recorded
    ///   for this interaction, i.e. the pre-prompt was shown first and the user confirmed.
    private func fireNativeReview(from presenter: UIViewController, reason: String, recordCooldown: Bool = true) {
        PSLog.info("Requesting the native review prompt: \(reason).")
        guard nativeReviewRequest(presenter) else {
            PSLog.warning("Cannot request the native review prompt (\(reason)): the view controller passed to requestReview(in:) is not in a window.")
            return
        }
        // Recorded whether or not iOS then shows anything: iOS does not say, so the count of
        // requests is all the SDK can hold the quota against.
        rateLimiter.recordNativeRequest()
        telemetry.send(eventType: EventTypes.nativePromptRequested)
        if recordCooldown { rateLimiter.recordShown() }
    }

    /// The default `nativeReviewRequest`: StoreKit's review API, in the presenter's window scene.
    ///
    /// iOS 16 and later use `AppStore.requestReview(in:)`, Apple's current StoreKit API for
    /// this. Below 16 it does not exist, so `SKStoreReviewController.requestReview(in:)` stays as
    /// the fallback for iOS 14 and 15. Both are subject to the same limit of three displays in
    /// 365 days.
    static func askSystemForReview(from presenter: UIViewController) -> Bool {
        guard let scene = presenter.view.window?.windowScene else { return false }
        if #available(iOS 16.0, *) {
            // `AppStore.requestReview(in:)` is main-actor isolated. The SDK only gets here on the
            // main thread, but from code the compiler cannot prove is on the main actor, so the
            // hop is explicit rather than assumed. It runs on the next turn of the main loop.
            Task { @MainActor in
                AppStore.requestReview(in: scene)
            }
        } else {
            SKStoreReviewController.requestReview(in: scene)
        }
        return true
    }

    private func present(_ response: PromptResponse, from presenter: UIViewController) {
        guard presenter.view.window != nil, presenter.presentedViewController == nil else {
            PSLog.warning("Skipped the pre-prompt: the view controller passed to requestReview(in:) can no longer present. No impression was recorded.")
            return
        }

        let vc = PrePromptViewController(
            promptResponse: response,
            onAccept: { [weak self] in
                guard let self else { return }
                self.telemetry.send(
                    eventType: EventTypes.prePromptConfirmed,
                    payload: self.promptPayload(response)
                )
                // The cooldown was already recorded when the dialog appeared.
                self.fireNativeReview(from: presenter, reason: "the user accepted the pre-prompt", recordCooldown: false)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.rateLimiter.recordDismissed()
                self.telemetry.send(
                    eventType: EventTypes.prePromptDismissed,
                    payload: self.promptPayload(response)
                )
            }
        )

        // Record the impression and the cooldown only once UIKit confirms the dialog is on
        // screen. `pre_prompt_shown` is the billable unit, so firing it before the presentation
        // is known to have succeeded billed the customer for a dialog nobody saw - and burned
        // the 90-day cooldown along with it.
        presenter.present(vc, animated: true) { [weak self] in
            guard let self else { return }
            self.rateLimiter.recordShown()
            self.telemetry.send(
                eventType: EventTypes.prePromptShown,
                payload: self.promptPayload(response)
            )
            PSLog.info("Pre-prompt shown (locale=\(response.text.locale)).")
        }
    }

    private func promptPayload(_ response: PromptResponse) -> EventPayload {
        return EventPayload(
            promptId: response.promptId,
            resolvedLocale: response.text.locale,
            servedPromptNumber: response.appPromptNumber
        )
    }
}

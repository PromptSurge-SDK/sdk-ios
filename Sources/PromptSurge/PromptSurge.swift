import UIKit
import StoreKit

/// Entry point for the PromptSurge iOS SDK.
///
/// Call `initialize(apiKey:)` once at app launch, then call `requestReview(in:)`
/// at a natural moment in the user journey (e.g. after completing a level or purchase).
///
/// Everything the SDK decides — a suppressed dialog, a rejected key, a failed fetch — is
/// written to the unified log under subsystem `com.promptsurge.sdk`. Errors and warnings are
/// always emitted; call `setLogLevel(.info)` while integrating for one line per decision.
public final class PromptSurge {
    private static var shared: PromptSurge?
    private static let optOutKey = "com.promptsurge.optedOut"

    private let repository: PromptTextRepository
    private let telemetry: Telemetry
    private let rateLimiter: RateLimiter
    private let holdoutManager: HoldoutManager

    /// True between a `requestReview(in:)` call and its dialog being resolved. Stops two calls
    /// from stacking two dialogs. Only ever touched on the main queue.
    private var isRequestInFlight = false

    private init(apiKey: String, apiBaseUrl: String) {
        let holdout = HoldoutManager()
        // One session id shared by the prompt fetch and every event, so the server can select
        // a copy variant deterministically and the events attribute to that same session.
        let sessionId = UUID().uuidString
        self.holdoutManager = holdout
        self.repository = PromptTextRepository(apiKey: apiKey, apiBaseUrl: apiBaseUrl, sessionId: sessionId)
        self.telemetry = Telemetry(
            apiKey: apiKey,
            apiBaseUrl: apiBaseUrl,
            sessionId: sessionId,
            holdoutManager: holdout
        )
        self.rateLimiter = RateLimiter()
    }

    // MARK: - Public API

    public static func initialize(apiKey: String, apiBaseUrl: String = "https://api.promptsurge.me") {
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

        let instance = PromptSurge(apiKey: key, apiBaseUrl: apiBaseUrl)
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
    /// delay at the moment of the request. Safe to call multiple times — a fresh cache is served
    /// immediately and revalidated in the background, so this always costs one request.
    public static func prefetch() {
        guard let shared else {
            PSLog.error("prefetch() was called before initialize(apiKey:) — nothing was fetched.")
            return
        }
        shared.repository.fetch { _ in }
    }

    /// Presents the pre-prompt dialog from `viewController` if rate limits and holdout allow.
    /// Does nothing if `initialize` has not been called or if the user has opted out; both
    /// cases are logged rather than swallowed.
    public static func requestReview(in viewController: UIViewController) {
        guard !isOptedOut else {
            PSLog.info("requestReview ignored: this user has opted out.")
            return
        }
        guard let shared else {
            PSLog.error("requestReview(in:) was called before initialize(apiKey:) — no dialog will appear. Call PromptSurge.initialize(apiKey:) at app launch.")
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

    private func showDialog(from presenter: UIViewController) {
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

        // Holdout group — skip pre-prompt but still fire native review as a baseline.
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

    /// Fires `SKStoreReviewController` plus its telemetry event.
    /// - Parameter recordCooldown: pass `false` when the 90-day cooldown was already recorded
    ///   for this interaction, i.e. the pre-prompt was shown first and the user confirmed.
    private func fireNativeReview(from presenter: UIViewController, reason: String, recordCooldown: Bool = true) {
        guard let scene = presenter.view.window?.windowScene else {
            PSLog.warning("Cannot request the native review prompt (\(reason)): the view controller passed to requestReview(in:) is not in a window.")
            return
        }
        PSLog.info("Requesting the native review prompt: \(reason).")
        SKStoreReviewController.requestReview(in: scene)
        telemetry.send(eventType: EventTypes.nativePromptRequested)
        if recordCooldown { rateLimiter.recordShown() }
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
        // is known to have succeeded billed the customer for a dialog nobody saw — and burned
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

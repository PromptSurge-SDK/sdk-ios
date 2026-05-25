import UIKit
import StoreKit

/// Entry point for the PromptSurge iOS SDK.
///
/// Call `initialize(apiKey:)` once at app launch, then call `requestReview(in:)`
/// at a natural moment in the user journey (e.g. after completing a level or purchase).
public final class PromptSurge {
    private static var shared: PromptSurge?
    private static let optOutKey = "com.promptsurge.optedOut"

    private let repository: PromptTextRepository
    private let telemetry: Telemetry
    private let rateLimiter: RateLimiter
    private let holdoutManager: HoldoutManager

    private init(apiKey: String, apiBaseUrl: String) {
        let holdout = HoldoutManager()
        self.holdoutManager = holdout
        self.repository = PromptTextRepository(apiKey: apiKey, apiBaseUrl: apiBaseUrl)
        self.telemetry = Telemetry(apiKey: apiKey, apiBaseUrl: apiBaseUrl, holdoutManager: holdout)
        self.rateLimiter = RateLimiter()
    }

    // MARK: - Public API

    public static func initialize(apiKey: String, apiBaseUrl: String = "https://api.promptsurge.me") {
        shared = PromptSurge(apiKey: apiKey, apiBaseUrl: apiBaseUrl)
    }

    /// Warms the prompt cache in the background without showing any dialog.
    ///
    /// Call this early (e.g. in `applicationDidFinishLaunching`) so the prompt text is already
    /// cached when `requestReview(in:)` is called later, eliminating the network round-trip
    /// delay at the moment of the request. Safe to call multiple times; no-ops if cache is fresh.
    public static func prefetch() {
        shared?.repository.fetch(onSuccess: { _ in }, onLimitExceeded: nil)
    }

    /// Presents the pre-prompt dialog from `viewController` if rate limits and holdout allow.
    /// Does nothing (silently) if `initialize` has not been called or if the user has opted out.
    public static func requestReview(in viewController: UIViewController) {
        guard !isOptedOut else { return }
        shared?.showDialog(from: viewController)
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
        guard rateLimiter.canShow else { return }

        // Holdout group — skip pre-prompt but still fire native review as a baseline.
        if holdoutManager.isHoldout {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let scene = presenter.view.window?.windowScene {
                    SKStoreReviewController.requestReview(in: scene)
                    self.telemetry.send(eventType: EventTypes.nativePromptRequested)
                    self.rateLimiter.recordShown()
                }
            }
            return
        }

        repository.fetch(
            onSuccess: { [weak self] response in
                DispatchQueue.main.async {
                    guard let self else { return }

                    let effectiveResponse = response ?? PromptResponse(
                        promptId: "default",
                        appPromptNumber: nil,
                        text: defaultPromptText,
                        theme: nil,
                        imageUrl: nil,
                        warmup: false
                    )

                    // Warm-up phase: fire native review to build baseline, never show dialog.
                    if effectiveResponse.warmup {
                        if let scene = presenter.view.window?.windowScene {
                            SKStoreReviewController.requestReview(in: scene)
                            self.telemetry.send(eventType: EventTypes.nativePromptRequested)
                            self.rateLimiter.recordShown()
                        }
                        return
                    }

                    let vc = PrePromptViewController(
                        promptResponse: effectiveResponse,
                        onAccept: { [weak self] in
                            guard let self else { return }
                            self.telemetry.send(
                                eventType: EventTypes.prePromptConfirmed,
                                payload: self.promptPayload(effectiveResponse)
                            )
                            if let scene = presenter.view.window?.windowScene {
                                SKStoreReviewController.requestReview(in: scene)
                            }
                            self.telemetry.send(eventType: EventTypes.nativePromptRequested)
                        },
                        onDismiss: { [weak self] in
                            guard let self else { return }
                            self.rateLimiter.recordDismissed()
                            self.telemetry.send(
                                eventType: EventTypes.prePromptDismissed,
                                payload: self.promptPayload(effectiveResponse)
                            )
                        }
                    )

                    // Fire shown event once before presenting.
                    self.rateLimiter.recordShown()
                    self.telemetry.send(
                        eventType: EventTypes.prePromptShown,
                        payload: self.promptPayload(effectiveResponse)
                    )

                    presenter.present(vc, animated: true)
                }
            },
            onLimitExceeded: { [weak self] in
                // Server billing limit hit — fire native review directly.
                // No client-side caching: every call checks the server fresh.
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let scene = presenter.view.window?.windowScene {
                        SKStoreReviewController.requestReview(in: scene)
                        self.telemetry.send(eventType: EventTypes.nativePromptRequested)
                        self.rateLimiter.recordShown()
                    }
                }
            }
        )
    }

    private func promptPayload(_ response: PromptResponse) -> EventPayload {
        return EventPayload(
            promptId: response.promptId,
            servedPromptNumber: response.appPromptNumber
        )
    }
}

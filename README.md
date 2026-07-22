# PromptSurge iOS SDK

Swift Package Manager SDK for iOS 14+. Shows a pre-prompt dialog before triggering `SKStoreReviewController`, increasing review tap-through rates.

## Installation

In Xcode: **File → Add Package Dependencies**, paste `https://github.com/PromptSurge-SDK/sdk-ios`, select the `PromptSurge` product.

Or in `Package.swift`:
```swift
.package(url: "https://github.com/PromptSurge-SDK/sdk-ios.git", from: "1.1.0")
```

The published repository is `PromptSurge-SDK/sdk-ios`. The old `promptsurge/sdk-ios` URL still resolves through a GitHub redirect, but use the canonical one.

## Usage

```swift
// AppDelegate / @main
import PromptSurge

PromptSurge.initialize(apiKey: "ps_live_xxxx")

// Optional, while integrating: one log line per decision the SDK makes.
PromptSurge.setLogLevel(.info)

// At a natural moment (level complete, purchase success, etc.)
PromptSurge.requestReview(in: self) // self = UIViewController
```

## Diagnostics

The SDK logs to the unified log under subsystem `com.promptsurge.sdk`. Errors and warnings are always emitted — a rejected API key, a suppressed dialog and a failed fetch each say so, by name. `setLogLevel(.info)` adds one line per decision, `.debug` adds per-event delivery results, `.quiet` (the default) leaves only errors and warnings.

```
log stream --predicate 'subsystem == "com.promptsurge.sdk"'
```

If nothing appears at all, `initialize(apiKey:)` was never called.

## Behaviour

- **Holdout group:** 10% of devices are silently skipped (control group for measuring lift). Assignment is random and persists for the device's lifetime.
- **Rate limiting:** After a "shown" event, the dialog won't reappear for 90 days. After a dismiss, 7 days. The cooldown is recorded when the dialog actually appears on screen, not when it is requested.
- **Impression limit:** When your plan's monthly cap is reached the API returns `402`. The SDK persists this in `UserDefaults`, suppresses the dialog and fires `SKStoreReviewController` directly. The flag clears on the next successful response, i.e. when the billing period rolls over.
- **Deleted apps:** if the app is deleted in the admin panel the API returns `404 app_deleted`, and the SDK suppresses the pre-prompt while still firing the native review prompt. Restoring the app clears the flag on the next successful response.
- **Invalid API key:** `401`/`403` is logged as an error and no pre-prompt is shown. The SDK deliberately does *not* fall back to bundled copy here, so a broken key cannot look like a working install.
- **Fallback:** If the API is unreachable, a bundled English default prompt is shown.
- **Localization:** the device locale is sent as a BCP-47 tag (`de-DE`) on every prompt request; the server resolves it through its fallback chain and the SDK reports the locale it actually rendered.
- **No sentiment gating:** Both buttons lead to `SKStoreReviewController` — required for Apple App Store Review guideline 5.6.1 compliance.

## Requirements

- iOS 14+
- Xcode 14+

## Releasing

`Telemetry.sdkVersion` is the single source of truth for the version. CI (`.github/workflows/sync-sdks.yml`) mirrors this directory to `PromptSurge-SDK/sdk-ios` and tags the mirror with that exact string, so `from: "x.y.z"` in a consumer's `Package.swift` resolves. Bump `sdkVersion` in the same commit as the change you are releasing; existing tags are never moved.

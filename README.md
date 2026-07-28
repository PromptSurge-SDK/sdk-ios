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

## Privacy

### What the SDK collects

One identifier: `SHA-256(identifierForVendor + your bundle identifier)`. The raw
`identifierForVendor` is never stored, transmitted or logged, and the bundle-id salt is the part
that matters - `identifierForVendor` alone is shared across all of one vendor's apps, so hashing
it with your bundle id means the same device produces a different value in each of your apps and
cannot be correlated between them.

Alongside it, each event records which prompt step happened (`pre_prompt_shown`,
`pre_prompt_confirmed`, `pre_prompt_dismissed`, `native_prompt_requested`, `initialize`,
`first_open`), your app version, the SDK version and the device locale. Nothing else.

**There is no IDFA and no ATT prompt.** You do not need to call
`ATTrackingManager.requestTrackingAuthorization` because of this SDK, and adding one would be
asking your users for permission you do not use.

### The privacy manifest

`PrivacyInfo.xcprivacy` ships inside the package and is declared in `Package.swift` as
`resources: [.copy(...)]`. That second half is not optional: SwiftPM only copies files it is told
about, and a manifest that is present in the repo but missing from the built product produces no
warning at all - you find out as **ITMS-91053** at App Store submission, from a build that
compiled and ran perfectly.

It declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason **CA92.1**. `UserDefaults` is a
required-reason API and the SDK uses it for the `first_open` flag and the cooldown timestamps, all
read and written by your app alone, which is exactly what CA92.1 covers.

### App Store Connect &rsaquo; App Privacy: what to declare

You fill this in yourself and the enforcement lands on you, so here is what this SDK adds. Declare
it **in addition to** whatever the rest of your app collects.

| Data type | Purpose | Linked to identity | Used for tracking |
| --- | --- | --- | --- |
| Identifiers &rsaquo; Device ID | Analytics | **No** | **No** |
| Usage Data &rsaquo; Product Interaction | Analytics | **No** | **No** |

"Used for tracking" is No because the SDK neither joins this data with data from other companies
nor sends it to a data broker - which is Apple's actual definition, and the reason no ATT prompt
is required.

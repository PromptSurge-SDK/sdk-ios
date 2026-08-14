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

### Verifying app ownership (SDK 1.2.0+)

The dashboard's Verify page hands you a one-shot token that proves this App Store app is
yours. Pass it once at initialisation:

```swift
PromptSurge.initialize(apiKey: "ps_live_xxxx", verifyToken: "vt_xxxx")
```

It rides along with the event batches; remove it from your code once the dashboard shows the
app as verified — it has no effect after that.

## Diagnostics

The SDK logs to the unified log under subsystem `com.promptsurge.sdk`. Errors and warnings are always emitted — a rejected API key and a failed fetch each say so, by name.

**A suppressed dialog usually does not.** The two server-side suppressions — impression cap and deleted app — are warnings and always print. But warm-up, holdout, both cooldowns and opted-out are **info**, and `.quiet` is the default. Those four cover every reason a correctly wired integration shows nothing, so the most confusing case is also the quietest one:

```swift
PromptSurge.setLogLevel(.info)
```

Do that first, before anything else in this section. `.debug` adds per-event delivery results.

```
log stream --predicate 'subsystem == "com.promptsurge.sdk"'
```

If nothing appears at all, `initialize(apiKey:)` was never called.

### Nothing is showing and I do not know why

With `.info` set, the SDK says which of these it hit, in this order. Without it, all of them are silent.

| What you will see | What it means |
|---|---|
| `requestReview ignored: this user has opted out.` | `setOptedOut(true)` was called at some point; it persists. |
| `Requesting the native review prompt: the app is still in its warm-up phase.` | **The one that catches every new integration.** See Behaviour below. |
| `Requesting the native review prompt: this device is in the holdout group.` | The 10% control group, for this device's lifetime. Try another device. |
| `requestReview ignored: still inside the cooldown window (90 days after a shown prompt, 7 after a dismissal).` | Already shown or dismissed on this device. |
| `Monthly impression limit reached...` (warning) | Always prints. Plan cap spent; clears when the billing period rolls over. |
| `This app was deleted in the PromptSurge admin panel...` (warning) | Always prints. Restore the app to clear it. |
| `requestReview ignored: a request is already in flight.` | Two calls raced; harmless. |

In every one of these cases the **native** review sheet still fires where the platform allows it. A missing pre-prompt does not mean nothing happened — and note that `SKStoreReviewController` itself is rate-limited by iOS, so an invisible native sheet is normal too.

## Behaviour

- **Warm-up phase:** a brand-new app shows **no pre-prompt at all** until it has recorded **50 distinct devices** firing `native_prompt_requested`. Until then every `requestReview` fires `SKStoreReviewController` directly, which is what builds the baseline the whole product measures lift against. Default mode is `once` — one warm-up for the app's lifetime, not per release. **A test device will never reach 50 on its own**, so this is the expected state during an integration rather than a bug. Turn it off for an app from its overview page in the dashboard (Warm-up control), or leave it on and test with `setLogLevel(.info)`.
- **Holdout group:** 10% of devices are silently skipped (control group for measuring lift). Assignment is random and persists for the device's lifetime.
- **Rate limiting:** After a "shown" event, the dialog won't reappear for 90 days. After a dismiss, 7 days. The cooldown is recorded when the dialog actually appears on screen, not when it is requested.
- **Impression limit:** When your plan's monthly cap is reached the API returns `402`. The SDK persists this in `UserDefaults`, suppresses the dialog and fires `SKStoreReviewController` directly. The flag clears on the next successful response, i.e. when the billing period rolls over.
- **Deleted apps:** if the app is deleted in the admin panel the API returns `404 app_deleted`, and the SDK suppresses the pre-prompt while still firing the native review prompt. Restoring the app clears the flag on the next successful response.
- **Invalid API key:** `401`/`403` is logged as an error and no pre-prompt is shown. The SDK deliberately does *not* fall back to bundled copy here, so a broken key cannot look like a working install.
- **Fallback:** If the API is unreachable, a bundled English default prompt is shown.
- **Localization:** the device locale is sent as a BCP-47 tag (`de-DE`) on every prompt request; the server resolves it through its fallback chain and the SDK reports the locale it actually rendered.
- **The two buttons differ:** confirm calls `SKStoreReviewController`, dismiss does not. A dismissal records the cooldown and fires `pre_prompt_dismissed`. This is deliberate: a user who says "not now" is answering the question, so the rating sheet stays closed.

## The copy is where the policy risk lives

The default copy is a plain call to action ("Leave a review?"), and it must stay one. Because
only the confirm button opens the native sheet, rewriting the four strings into a satisfaction
question - "Are you enjoying the app?", "How are we doing?" - turns the dialog into a filter that
routes only happy users to the store. That is the pattern App Store Review guideline 5.6.1 and
Google Play's in-app review policy are about, and the consequence lands on your listing.

Keep it a request to review. Do not make it a question about how the user feels.

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

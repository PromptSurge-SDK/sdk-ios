# PromptSurge iOS SDK

Swift Package Manager SDK for iOS 14+. Shows a pre-prompt dialog before asking StoreKit for the rating sheet (`AppStore.requestReview(in:)` on iOS 16 and later, `SKStoreReviewController.requestReview(in:)` on iOS 14 and 15), increasing review tap-through rates.

## Installation

In Xcode: **File → Add Package Dependencies**, paste `https://github.com/PromptSurge-SDK/sdk-ios`, select the `PromptSurge` product.

Or in `Package.swift`:
```swift
.package(url: "https://github.com/PromptSurge-SDK/sdk-ios.git", from: "1.3.0")
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
app as verified - it has no effect after that.

## Diagnostics

The SDK logs to the unified log under subsystem `com.promptsurge.sdk`. Errors and warnings are always emitted - a rejected API key and a failed fetch each say so, by name.

**A suppressed dialog usually does not.** The two server-side suppressions - impression cap and deleted app - are warnings and always print. But warm-up, holdout, both cooldowns, the App Store review quota and opted-out are **info**, and `.quiet` is the default. Those cover every reason a correctly wired integration shows nothing, so the most confusing case is also the quietest one:

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
| `requestReview ignored: this user has opted out.` | `optOut()` was called at some point; it persists until `optIn()`. |
| `Requesting the native review prompt: the app is still in its warm-up phase.` | **The one that catches every new integration.** See Behaviour below. |
| `Requesting the native review prompt: this device is in the holdout group.` | The 10% control group, for this device's lifetime. Try another device. |
| `requestReview ignored: still inside the cooldown window (90 days after a shown prompt, 7 after a dismissal).` | Already shown or dismissed on this device. |
| `requestReview ignored: the SDK has already asked iOS for the rating sheet 3 times in the last 365 days...` | The App Store review quota is spent on this device; the line ends with the date the next request becomes possible. See Behaviour below. |
| `Monthly impression limit reached...` (warning) | Always prints. Plan cap spent; clears when the billing period rolls over. |
| `This app was deleted in the PromptSurge admin panel...` (warning) | Always prints. Restore the app to clear it. |
| `requestReview ignored: a request is already in flight.` | Two calls raced; harmless. |

In the warm-up, holdout, impression-limit and deleted-app cases the **native** review sheet is still requested, so a missing pre-prompt does not mean nothing happened - and iOS itself decides whether that sheet appears, so an invisible native sheet is normal too. In the review-quota case nothing is requested at all, on purpose.

## Behaviour

- **Warm-up phase:** a brand-new app shows **no pre-prompt at all** until it has recorded **50 distinct devices** firing `native_prompt_requested`. Until then every `requestReview` requests the native rating sheet directly, which is what builds the baseline the whole product measures lift against. Default mode is `once` - one warm-up for the app's lifetime, not per release. **A test device will never reach 50 on its own**, so this is the expected state during an integration rather than a bug. Turn it off for an app from its overview page in the dashboard (Warm-up control), or leave it on and test with `setLogLevel(.info)`.
- **Holdout group:** 10% of devices are silently skipped (control group for measuring lift). Assignment is random and persists for the device's lifetime.
- **Rate limiting:** After a "shown" event, the dialog won't reappear for 90 days. After a dismiss, 7 days. The cooldown is recorded when the dialog actually appears on screen, not when it is requested.
- **App Store review quota:** iOS shows the rating sheet at most 3 times in 365 days per app per device, and never tells the app whether a request displayed anything. So a "Sure" could be answered by nothing, which is what both stores warn about when an app puts a button in front of the review API. The SDK therefore records every native request it makes (the confirm path, holdout, warm-up, the impression limit) in `UserDefaults`, and once it has made **3 in the last 365 days** it shows **no pre-prompt and makes no native request** on that `requestReview(in:)` call. No impression is recorded. It logs one info line with the date the next request becomes possible, which is when the oldest of the three turns a year old. Holdout and warm-up devices are held to the same rule, so both sides of the lift comparison skip under the same condition. The count cannot see review requests your app makes itself through StoreKit; if you have your own, they share the same 3-a-year budget.
- **Impression limit:** When your plan's monthly cap is reached the API returns `402`. The SDK persists this in `UserDefaults`, suppresses the dialog and requests the native rating sheet directly. The flag clears on the next successful response, i.e. when the billing period rolls over.
- **Deleted apps:** if the app is deleted in the admin panel the API returns `404 app_deleted`, and the SDK suppresses the pre-prompt while still firing the native review prompt. Restoring the app clears the flag on the next successful response.
- **Invalid API key:** `401`/`403` is logged as an error and no pre-prompt is shown. The SDK deliberately does *not* fall back to bundled copy here, so a broken key cannot look like a working install.
- **Fallback:** If the API is unreachable, a bundled English default prompt is shown.
- **Localization:** the device locale is sent as a BCP-47 tag (`de-DE`) on every prompt request; the server resolves it through its fallback chain and the SDK reports the locale it actually rendered.
- **Native API:** iOS 16 and later go through `AppStore.requestReview(in:)`, Apple's current StoreKit API; iOS 14 and 15 keep `SKStoreReviewController.requestReview(in:)`, because the newer call does not exist there. Both share the same quota.
- **The two buttons differ:** confirm asks StoreKit for the rating sheet, dismiss does not. A dismissal records the cooldown and fires `pre_prompt_dismissed`. This is deliberate: a user who says "not now" is answering the question, so the rating sheet stays closed.

## The copy is where the policy risk lives

The bundled default is a statement, not a question, and it is the same on all three SDKs and on
the server's own fallback:

| Field | Default |
|---|---|
| Title | A quick favor |
| Body | A short review helps other people discover apps like this. |
| Confirm | Sure |
| Dismiss | Not now |

It asks nothing, because Google's in-app review guidance says an app should not ask the user any
questions before or while presenting the rating button or card, and the buttons already carry the
choice. Copy you set in the dashboard replaces it.

Because only the confirm button opens the native sheet, rewriting the four strings into a
satisfaction question - "Are you enjoying the app?", "How are we doing?" - turns the dialog into a
filter that routes only happy users to the store. That is the pattern App Store Review guideline
5.6.1 and Google Play's in-app review policy are about, and the consequence lands on your listing.

Keep it a request to review. Do not make it a question about how the user feels.

## App Store review notes

App Review sees the pre-prompt in front of the rating sheet, so say what it does before they ask.
Paste this into App Store Connect, under your app's version, **App Review Information > Notes**,
with `[action]` replaced by the moment you call `requestReview(in:)` (and your own button labels
if you changed them):

```
After a user completes [action], the app shows a short request to leave a review. Tapping Sure opens the system rating sheet; tapping Not now closes it. The app never asks how the user feels and never collects a rating itself.
```

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
required-reason API and the SDK uses it for the `first_open` flag, the cooldown timestamps and the
timestamps of its own review requests (the quota record), all read and written by your app alone,
which is exactly what CA92.1 covers.

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

# Changelog - PromptSurge iOS SDK

The version is `Telemetry.sdkVersion`. CI tags the public mirror (`PromptSurge-SDK/sdk-ios`) with
that string when it changes; tags are never moved.

## 1.3.0 - 2026-10-19


### Changed

- **The bundled default copy is a statement.** Title "A quick favor", body "A short review helps
  other people discover apps like this.", buttons "Sure" / "Not now" - identical on iOS, Android,
  Unity and the server's own fallback. It was "Leave a review?" / "Reviews help other people
  discover apps like this. Got a moment?". Google's in-app review guidance says an app should not
  ask the user any questions before or while presenting the rating button or card, and the old
  title was one; the no-satisfaction-question rule (App Store 5.6.1) is unchanged. The default only
  shows when the server cannot be reached; dashboard copy replaces it.
- **iOS 16 and later request the rating sheet with `AppStore.requestReview(in:)`.** iOS 14 and 15
  keep `SKStoreReviewController.requestReview(in:)`, which is the only API there.
- **Log lines use a plain hyphen where they had an em dash**, for example
  `requestReview(in:) was called before initialize(apiKey:) - no dialog will appear.` If you match
  SDK log text anywhere, update the pattern.

### Added

- **App Store review quota.** iOS shows the rating sheet at most 3 times in 365 days per app per
  device and never says whether a request displayed anything, so a "Sure" could open nothing. The
  SDK now records every native review request it makes - the confirm path, holdout, warm-up, the
  impression limit, a deleted app and a rejected key - in `UserDefaults` (`ps_native_review_requests`,
  last 5 entries), and once it has made **3 in the last 365 days** a `requestReview(in:)` call shows
  **no pre-prompt and makes no native request**. No impression is recorded. One info line names the
  date the next request becomes possible (when the oldest of the three turns a year old).
  - Holdout and warm-up devices are held to the same rule, so both sides of the lift comparison
    skip under the same condition.
  - No new telemetry event: a skipped call sends nothing, and `POST /v1/events` accepts only the
    six existing event types.
  - The 90-day and 7-day cooldowns are unchanged and are checked first.
- README: recommended **App Review Information > Notes** text for App Store Connect.

### Also unreleased since 1.2.0

- Card 349: the SDK adopts the holdout group the server remembers for this device (from the
  `POST /v1/events` response), from the next session on. In the source since 2026-09-14, in no tag.

### Upgrade notes

- **The request record starts empty on upgrade.** Versions up to 1.2.0 kept no record, so requests
  they made are not counted; a device can be asked up to 3 more times in its first year on this
  version, subject to the 90-day cooldown as before.
- The record cannot see review requests the host app makes itself through StoreKit.

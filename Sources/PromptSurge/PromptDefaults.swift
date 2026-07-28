import Foundation

// ─── API response (flat format returned by /v1/prompts) ───────────────────────

/// Wire format of `GET /v1/prompts`, matching `apps/api/src/routes/prompts.ts`.
///
/// The copy fields are non-optional **on purpose**. When every field was optional, Swift's
/// synthesized decoder accepted any JSON object at all — so an error body such as
/// `{"error":"invalid_api_key"}` decoded as a perfectly valid prompt and was then cached for
/// six hours. Requiring the fields the server always sends makes a decode failure mean what
/// it should: this is not a prompt.
struct APIPromptResponse: Codable {
    let locale: String
    let title: String
    let body: String
    let ctaConfirm: String
    let ctaDismiss: String
    let imageUrl: String?
    let promptNumber: Int?
    let theme: DialogTheme?
    /// Identifier of the copy variant served, for A/B attribution. Servers that predate
    /// this field omit it, and the SDK then reports no variant rather than inventing one.
    let promptId: String?
    /// True during the mandatory warm-up phase. SDK fires native review without dialog.
    let warmup: Bool?
}

// ─── Internal SDK model ───────────────────────────────────────────────────────

struct PromptText: Codable {
    let title: String
    let body: String
    let positiveButton: String
    let negativeButton: String
    let locale: String
}

/// Dialog theme as the server sends it (`resolveTheme` in `apps/api/src/routes/adminAppearance.ts`).
///
/// The field names must match the wire format exactly. They did not until 1.1.0, so every
/// themed app silently fell back to system colours — on the dark presets that meant a blue
/// button on a near-black card.
struct DialogTheme: Codable {
    let presetId: String?
    /// Fill colour of the confirm button, and the tint of the dismiss button's label.
    let accentColor: String?
    /// Card background.
    let backgroundColor: String?
    /// Title and body text.
    let textColor: String?
    /// Label colour *on top of* `accentColor`. Never used as a background.
    let buttonTextColor: String?
}

struct PromptResponse: Codable {
    /// Nil when the server did not identify a copy variant.
    let promptId: String?
    let appPromptNumber: Int?
    let text: PromptText
    let theme: DialogTheme?
    let imageUrl: String?
    /// True during the mandatory warm-up phase. SDK fires native review without dialog.
    let warmup: Bool

    /// Last-resort copy, used only when the server cannot be reached at all.
    static let bundledDefault = PromptResponse(
        promptId: nil,
        appPromptNumber: nil,
        text: defaultPromptText,
        theme: nil,
        imageUrl: nil,
        warmup: false
    )
}

// ─── Defaults ─────────────────────────────────────────────────────────────────

/// Bundled English fallback. Kept verbatim in step with the Android SDK's `PromptDefaults`
/// so the same app shows the same offline copy on both platforms.
///
/// The title is a call to action, not a satisfaction question, and must stay one: only the
/// confirm button opens `SKStoreReviewController`, so an "Are you enjoying...?" title would make
/// this a sentiment filter (App Store 5.6.1). See `docs/conventions.md`.
let defaultPromptText = PromptText(
    title: "Leave a review?",
    body: "Reviews help other people discover apps like this. Got a moment?",
    positiveButton: "Sure",
    negativeButton: "Not now",
    locale: "en"
)

/// Map a decoded APIPromptResponse to the internal PromptResponse model.
func mapAPIResponse(_ api: APIPromptResponse) -> PromptResponse {
    let text = PromptText(
        title: api.title,
        body: api.body,
        positiveButton: api.ctaConfirm,
        negativeButton: api.ctaDismiss,
        locale: api.locale
    )
    return PromptResponse(
        promptId: api.promptId,
        appPromptNumber: api.promptNumber,
        text: text,
        theme: api.theme,
        imageUrl: api.imageUrl,
        warmup: api.warmup ?? false
    )
}

// ─── Locale ───────────────────────────────────────────────────────────────────

/// BCP-47 language tag for the device locale, e.g. `de-DE`.
///
/// `Locale.identifier` is ICU-style (`de_DE`, occasionally with an `@key=value` suffix), but
/// the server's prompt lookup and the event schema both expect the hyphenated tag — which is
/// also what the Android SDK sends. `Locale.identifier(.bcp47)` would do this for us but is
/// iOS 16+, and this package supports iOS 14.
func currentLocaleTag() -> String {
    let raw = Locale.current.identifier
    let base = raw.split(separator: "@").first.map(String.init) ?? raw
    let tag = base.replacingOccurrences(of: "_", with: "-")
    // The event schema requires at least two characters; an empty identifier is not a locale.
    return tag.count >= 2 ? tag : "en"
}

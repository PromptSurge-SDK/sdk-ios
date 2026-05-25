import Foundation

// ─── API response (flat format returned by /v1/prompts) ───────────────────────

struct APIPromptResponse: Codable {
    let locale: String?
    let title: String?
    let body: String?
    let ctaConfirm: String?
    let ctaDismiss: String?
    let imageUrl: String?
    let promptNumber: Int?
    let theme: DialogTheme?
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

struct DialogTheme: Codable {
    let backgroundColor: String?
    let textColor: String?
    let positiveButtonColor: String?
    let negativeButtonColor: String?
    let borderRadius: Double?
}

struct PromptResponse: Codable {
    let promptId: String
    let appPromptNumber: Int?
    let text: PromptText
    let theme: DialogTheme?
    let imageUrl: String?
    /// True during the mandatory warm-up phase. SDK fires native review without dialog.
    let warmup: Bool
}

// ─── Defaults ─────────────────────────────────────────────────────────────────

let defaultPromptText = PromptText(
    title: "Enjoying the app?",
    body: "We'd love to hear your feedback! Would you like to leave a quick review?",
    positiveButton: "Sure!",
    negativeButton: "Not now",
    locale: "en"
)

/// Map a decoded APIPromptResponse to the internal PromptResponse model.
func mapAPIResponse(_ api: APIPromptResponse) -> PromptResponse {
    let text = PromptText(
        title: api.title ?? defaultPromptText.title,
        body: api.body ?? defaultPromptText.body,
        positiveButton: api.ctaConfirm ?? defaultPromptText.positiveButton,
        negativeButton: api.ctaDismiss ?? defaultPromptText.negativeButton,
        locale: api.locale ?? "en"
    )
    return PromptResponse(
        promptId: "api",
        appPromptNumber: api.promptNumber,
        text: text,
        theme: api.theme,
        imageUrl: api.imageUrl,
        warmup: api.warmup ?? false
    )
}

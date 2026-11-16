/// Event names accepted by `POST /v1/events`. Mirrors `EventTypes` in
/// `packages/shared-types/src/events.ts`; the server rejects the whole batch on a mismatch.
enum EventTypes {
    static let firstOpen             = "first_open"
    static let initialize            = "initialize"
    static let prePromptShown        = "pre_prompt_shown"
    static let prePromptConfirmed    = "pre_prompt_confirmed"
    static let prePromptDismissed    = "pre_prompt_dismissed"
    static let nativePromptRequested = "native_prompt_requested"
    /// Card 833: how long the app was away after asking for the rating sheet (`awayMs`).
    static let nativeSheetClosed     = "native_sheet_closed"
}

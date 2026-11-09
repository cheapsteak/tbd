import Foundation

/// TBD's own refusals of an answer to a prompt from the transcript, local or
/// remote.
///
/// They live in `Base` because the router (`Server`) writes them and the
/// phone app service (`PhoneBridge`) tells them from a provider's own words:
/// a phone hears these as they are, and never a provider's text, which can
/// quote a secret.
enum PromptAnswerRefusal {
    /// `transcript_prompt_answer_enabled` is off.
    static let disabled =
        "answering prompts from the transcript is off (config.transcript_prompt_answer_enabled)"

    /// `transcript_prompt_answer_enabled` could not be read, so the answer
    /// was refused before anything acted on it. A later read can succeed, so
    /// the text leaves out the column's name: the app takes a refusal that
    /// names it for the setting being off, which a retry cannot change
    /// (`PromptAnswerController.isRetryable`).
    static let settingUnread =
        "could not read the setting for answering prompts from the transcript; try again"

    /// The remote session has no mirror row, so there is no prompt to match
    /// the answer against.
    static let notMirrored = "session is not in the mirror; refresh and try again"
}

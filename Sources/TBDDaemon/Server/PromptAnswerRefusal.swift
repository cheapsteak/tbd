import Foundation
import TBDShared

/// TBD's own refusals of an answer to a prompt from the transcript, local or
/// remote.
///
/// Each is TBD's fixed words with its code (`CodedRefusal`), so a client may
/// show it. Clients decide from the code: the laptop's prompt card offers
/// "Try again" for every one but `disabled` (`PromptAnswerController.isRetryable`),
/// and a paired phone hears its own sentences for `disabled` and
/// `settingUnread`.
enum PromptAnswerRefusal {
    /// `transcript_prompt_answer_enabled` is off.
    static let disabled = CodedRefusal(
        text: "answering prompts from the transcript is off (config.transcript_prompt_answer_enabled)",
        code: .promptAnswerOff)

    /// `transcript_prompt_answer_enabled` could not be read, so the answer
    /// was refused before anything acted on it. A later read can succeed.
    static let settingUnread = CodedRefusal(
        text: "could not read the setting for answering prompts from the transcript; try again",
        code: .promptAnswerSettingUnread)

    /// The remote session has no mirror row, so there is no prompt to match
    /// the answer against.
    static let notMirrored = CodedRefusal(
        text: "session is not in the mirror; refresh and try again", code: .promptNotMirrored)
}

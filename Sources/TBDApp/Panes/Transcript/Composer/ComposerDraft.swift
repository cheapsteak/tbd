import Foundation
import Observation

/// One terminal's unsent message: the text, and a side map of staged images.
///
/// **The text decides what is sent; this map only says where the files are.** A
/// token the person deleted or edited drops its image at send time, and the strip
/// shows the orphan as detached rather than dropping it silently.
///
/// Held by `AppState`, deliberately **outside** the transcript's session-identity
/// reset: the table rebuilds under `.id(PaneIdentity(terminalID:sessionID:))`, so
/// a `/clear` tears the view down, and a draft that lived in the view would go
/// with it.
@Observable
@MainActor
final class ComposerDraft {
    struct Attachment: Equatable, Identifiable {
        /// The staged file's own id — also its filename under
        /// `~/tbd/attachments/<worktreeID>/`.
        let id: UUID
        /// The `[Image #N]` number this file answers to.
        let number: Int
        let path: String
    }

    var text: String = ""
    private(set) var attachments: [Int: Attachment] = [:]

    /// Monotonic within one message. A freed number is never reused, because
    /// reusing it would silently re-point a token the person had already typed
    /// somewhere else in the same sentence.
    private var nextNumber = 1

    /// Stage a prepared file and return the token number to insert at the caret.
    @discardableResult
    func stage(path: String, id: UUID) -> Int {
        let number = nextNumber
        nextNumber += 1
        attachments[number] = Attachment(id: id, number: number, path: path)
        return number
    }

    /// The x on a thumbnail: the image leaves the send, and its token leaves the
    /// text. (Removing the token from the text is the view's job — this forgets
    /// the file.)
    func removeAttachment(number: Int) {
        attachments[number] = nil
    }

    /// Staged images the text no longer anchors, in stable order. Shown greyed
    /// and marked "not in message".
    var detachedNumbers: [Int] {
        let attached = ComposerTokens.attachedNumbers(in: text)
        return attachments.keys.filter { !attached.contains($0) }.sorted()
    }

    /// Paths keyed by token number, the shape `ComposerTokens` wants.
    var pathsByNumber: [Int: String] {
        attachments.mapValues(\.path)
    }

    /// A successful send, or an explicit discard. Numbering restarts because a
    /// fresh message has no tokens to collide with.
    func clear() {
        text = ""
        attachments = [:]
        nextNumber = 1
    }
}

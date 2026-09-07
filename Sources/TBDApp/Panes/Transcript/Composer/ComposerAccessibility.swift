import Foundation

/// The composer's accessibility identifiers, in one place.
///
/// An identifier is **for automation** — a GUI driver, or the offscreen hosting
/// harness in the test suite, asking the accessibility tree for one control by a
/// name that does not move when the copy does. That is exactly what a label is
/// not: a label is the sentence a person hears, and it changes with the wording,
/// the terminal's name, and the attachment's number. So the two live side by
/// side here, and nothing reads a label to find a control.
///
/// Named constants rather than literals at the call sites for the ordinary
/// reason: a driver and a test that both spell `composer.send` by hand agree
/// only until one of them is edited.
enum ComposerAccessibility {
    /// The whole composer, as an accessibility container: everything below is
    /// somewhere inside it.
    static let root = "composer.root"
    /// The text view itself — the `NSTextView` inside the representable.
    static let field = "composer.field"
    /// The send/resume button, whatever it currently says.
    static let send = "composer.send"
    /// The note shown when the session is not running.
    static let note = "composer.note"
    /// The blocked banner's sentence, and the button beside it.
    static let blockedMessage = "composer.blocked.message"
    static let blockedReveal = "composer.blocked.reveal"
    /// The banner raised by a failed send or a refused attachment.
    static let error = "composer.error"
    /// The completion list, and one row inside it.
    static let menu = "composer.menu"
    /// The attachment strip.
    static let attachments = "composer.attachments"

    /// One completion row, named by its command — the row a driver means is
    /// "the one for `/compact`", never "the third one down", which moves as the
    /// ranking does.
    static func menuRow(command: String) -> String { "composer.menu.row.\(command)" }

    /// One staged image, and its remove button, named by the number the token in
    /// the message carries.
    static func attachmentItem(number: Int) -> String {
        "composer.attachments.item.\(number)"
    }

    static func attachmentRemove(number: Int) -> String {
        "composer.attachments.remove.\(number)"
    }
}

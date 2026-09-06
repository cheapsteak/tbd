import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// The composer view's three decisions that are not layout: what a key pressed
/// with the menu open means, what the send button says, and where a staged image
/// lands on disk.
///
/// Each one is a static function over its inputs precisely so it can be asserted
/// without mounting SwiftUI — the view body itself is wiring, and wiring is what
/// the rest of this PR's suites already pin.
@MainActor
@Suite("MessageComposerView")
struct MessageComposerViewTests {

    // MARK: - Enter versus Tab

    /// **Tab is the accept gesture.** It takes `acceptTarget` — the highlighted
    /// row, or the first one — whether or not anything is highlighted, which is
    /// exactly what makes it the way to accept without arrowing first.
    @Test func tabAcceptsWhetherOrNotARowIsHighlighted() {
        #expect(
            MessageComposerView.menuOutcome(for: .menuAccept, selectedIndex: nil) == .accept)
        #expect(
            MessageComposerView.menuOutcome(for: .menuAccept, selectedIndex: 2) == .accept)
    }

    /// **Enter never silently accepts.** With the menu open but nothing
    /// highlighted, Return sends the message as typed. Taking `rows.first` there
    /// would rewrite a person's words into a command they never chose — the one
    /// failure the whole Enter/Tab split exists to prevent.
    @Test func returnWithNothingHighlightedSubmits() {
        #expect(
            MessageComposerView.menuOutcome(
                for: .menuAcceptOrSubmit, selectedIndex: nil) == .submit)
    }

    /// Once a row is highlighted — the person arrowed to it — Return means that
    /// row, as it does in every completion list.
    @Test func returnWithARowHighlightedAcceptsIt() {
        #expect(
            MessageComposerView.menuOutcome(
                for: .menuAcceptOrSubmit, selectedIndex: 0) == .accept)
    }

    @Test func theArrowsAndEscapeDriveTheMenu() {
        #expect(MessageComposerView.menuOutcome(for: .menuUp, selectedIndex: nil) == .moveUp)
        #expect(MessageComposerView.menuOutcome(for: .menuDown, selectedIndex: 1) == .moveDown)
        #expect(MessageComposerView.menuOutcome(for: .menuClose, selectedIndex: 1) == .close)
    }

    /// The menu handler is reached only for menu actions; anything else the
    /// router resolved is somebody else's business and must not be re-decided
    /// here.
    @Test func nonMenuActionsAreNotTheMenusBusiness() {
        for action: ComposerKeyRouter.Action in [.submit, .newline, .blur, .passThrough] {
            #expect(
                MessageComposerView.menuOutcome(for: action, selectedIndex: 0) == .ignore,
                "\(action) must not be handled as a menu action")
        }
    }

    // MARK: - The button names the target

    /// The send button names the terminal, so an injection is never anonymous.
    @Test func theButtonNamesTheTargetTerminal() {
        #expect(
            MessageComposerView.sendButtonLabel(state: .running, terminalLabel: "worker 3")
                == "Send to worker 3")
        #expect(
            MessageComposerView.sendButtonLabel(
                state: .notRunning(exited: true), terminalLabel: "worker 3")
                == "Resume worker 3")
    }

    /// An unlabelled terminal still gets a name rather than an empty verb.
    @Test func anUnlabelledTerminalStillReadsAsAName() {
        #expect(
            MessageComposerView.sendButtonLabel(state: .running, terminalLabel: nil)
                == "Send to Claude")
    }

    /// The not-running note distinguishes a session that left on its own from one
    /// TBD parked — one wake path, two sentences.
    @Test func theNotRunningNoteDistinguishesExitFromPark() {
        let exited = MessageComposerView.notRunningNoteText(exited: true)
        let parked = MessageComposerView.notRunningNoteText(exited: false)
        #expect(exited != parked)
        #expect(exited.contains("exited"))
        #expect(parked.contains("hibernated"))
    }

    // MARK: - The draft a switched terminal gets

    /// Switching to a terminal whose draft is empty **clears** the box. The
    /// `NSTextView` is reused across the switch, so restoring only non-empty
    /// drafts would leave the previous terminal's message on screen, addressed
    /// to a session that never saw it typed.
    @Test func aTerminalWithAnEmptyDraftClearsTheBox() {
        #expect(MessageComposerView.restoreCommand(draftText: "") == .clear)
    }

    @Test func aTerminalWithADraftRestoresIt() {
        #expect(
            MessageComposerView.restoreCommand(draftText: "half a sentence")
                == .restore("half a sentence"))
    }

    // MARK: - Clicking a thumbnail that is in the message

    /// It moves the caret to that image's token — the token replaced with
    /// itself, which leaves the text untouched and the insertion point after it.
    /// It does not open Finder: the thumbnail carries one gesture, and where the
    /// image sits in the sentence is the question a click on an attached one is
    /// asking.
    @Test func clickingAnAttachedThumbnailMovesTheCaretToItsToken() throws {
        let token = ComposerTokens.text(for: 2)
        let text = "before \(token) after"

        let command = try #require(
            MessageComposerView.caretCommand(text: text, number: 2))

        let expected = (text as NSString).range(of: token)
        #expect(command == .replaceRange(expected, with: token))
    }

    /// A number the text no longer anchors has nowhere to put the caret, so the
    /// click does nothing rather than guessing at a position.
    @Test func aThumbnailWhoseTokenIsGoneMovesNothing() {
        #expect(MessageComposerView.caretCommand(text: "no tokens here", number: 1) == nil)
    }

    // MARK: - Removing an image

    /// **Every** occurrence goes. Re-inserting an image twice is how a person
    /// refers to it twice, and leaving the second copy behind would send a path
    /// for an image the strip no longer lists.
    @Test func removingADuplicatedTokenRemovesEveryOccurrence() throws {
        let token = ComposerTokens.text(for: 1)
        let text = "a \(token) b \(token) c"

        let command = try #require(
            MessageComposerView.removalCommand(text: text, number: 1))
        guard case .replaceRange(let range, let replacement) = command else {
            Issue.record("expected a range replacement, got \(command)")
            return
        }
        let updated = (text as NSString).replacingCharacters(in: range, with: replacement)

        #expect(updated == "a  b  c")
        #expect(ComposerTokens.attachedNumbers(in: updated).isEmpty)
    }

    /// Only that image's tokens. A neighbouring image keeps its anchor, and the
    /// text outside the removed span is not rewritten at all.
    @Test func removingOneImageLeavesTheOthersAnchored() throws {
        let text = "x \(ComposerTokens.text(for: 1)) y \(ComposerTokens.text(for: 2)) "
            + "z \(ComposerTokens.text(for: 1))"

        let command = try #require(
            MessageComposerView.removalCommand(text: text, number: 1))
        guard case .replaceRange(let range, let replacement) = command else {
            Issue.record("expected a range replacement, got \(command)")
            return
        }
        let updated = (text as NSString).replacingCharacters(in: range, with: replacement)

        #expect(ComposerTokens.attachedNumbers(in: updated) == [2])
        #expect(updated.hasPrefix("x "))
    }

    /// An image whose token the person already deleted removes nothing from the
    /// text — the strip's x still drops the image, but there is no edit to make.
    @Test func removingAnImageWithNoTokenLeftIssuesNoCommand() {
        #expect(MessageComposerView.removalCommand(text: "just words", number: 1) == nil)
    }

    // MARK: - The attachment write

    /// The PNG lands under the worktree's own attachment directory, derived from
    /// `TBDConstants` so `TBD_HOME` and the test fence apply, and it is written
    /// atomically — a half-written file behind a token that is already in the
    /// message would be sent as a broken path.
    @Test func aStagedImageIsWrittenUnderTheWorktreesAttachmentDirectory() throws {
        let root = fencedScratchRoot(prefix: "tbdcomposer")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let environment = ["TBD_HOME": root]
        let worktreeID = UUID()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let staged = try MessageComposerView.writeAttachment(
            bytes, worktreeID: worktreeID, environment: environment)

        #expect(staged.path == TBDConstants.attachmentPath(
            worktreeID: worktreeID, attachmentID: staged.id, environment: environment))
        #expect(staged.path.hasPrefix(root))
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged.path)) == bytes)
    }

    /// The directory is created on the way, so the first image in a worktree is
    /// not the one that fails.
    @Test func theWorktreeDirectoryIsCreatedOnDemand() throws {
        let root = fencedScratchRoot(prefix: "tbdcomposer")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let environment = ["TBD_HOME": root]
        let worktreeID = UUID()
        let directory = TBDConstants.attachmentsDir(
            worktreeID: worktreeID, environment: environment)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        _ = try MessageComposerView.writeAttachment(
            Data([0x01]), worktreeID: worktreeID, environment: environment)

        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Two images in one message get two files: the id is minted per write, so
    /// a second attachment can never overwrite the first.
    @Test func eachStagedImageGetsItsOwnFile() throws {
        let root = fencedScratchRoot(prefix: "tbdcomposer")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let environment = ["TBD_HOME": root]
        let worktreeID = UUID()

        let first = try MessageComposerView.writeAttachment(
            Data([0x01]), worktreeID: worktreeID, environment: environment)
        let second = try MessageComposerView.writeAttachment(
            Data([0x02]), worktreeID: worktreeID, environment: environment)

        #expect(first.id != second.id)
        #expect(first.path != second.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == Data([0x01]))
    }
}

import AppKit
import SwiftUI

/// One inline rename in the native sidebar.
///
/// It hosts the SwiftUI path's own `RenameableLabel` in an `NSHostingView`, so
/// the native cell gets the very same editor: `InlineTextField`, the `:emoji:`
/// autocomplete panel anchored to the field, Return to commit, Escape to
/// cancel, commit on focus loss, and the re-asserted focus that wins the race
/// with the terminal views. Nothing of that is reimplemented here.
///
/// The cell shows `view` in place of its name label for as long as the edit
/// runs. However the edit ends — Return, Escape, focus loss, or `close` from
/// outside — `onFinished` runs exactly once, and the controller then puts the
/// label back and releases its structure hold.
///
/// An edit handed over from another row opens with `seed`, the text typed
/// there, instead of the row's name; the name stays what a commit compares
/// against, so accepting the seed unchanged still renames the row.
@MainActor
final class SidebarRenameEditor {
    let session: SidebarRenameSession
    let view: NSView
    /// Runs once, when the edit is over.
    var onFinished: (() -> Void)?
    private(set) var isFinished = false

    init(text: String, seed: String? = nil, allowsEmptyCommit: Bool, commit: @escaping (String) -> Void) {
        let session = SidebarRenameSession(
            text: text, seed: seed, allowsEmptyCommit: allowsEmptyCommit, commit: commit)
        self.session = session
        let hosting = NSHostingView(rootView: SidebarRenameField(session: session))
        hosting.sizingOptions = []
        view = hosting
        session.onEditingEnded = { [weak self] in
            guard let self else { return }
            // Read now: the field goes once SwiftUI redraws without it.
            self.session.endedText = self.textField?.stringValue
            // `RenameableLabel` ends the edit from inside a SwiftUI callback
            // and calls `onCommit` or `onCancel` right after; tearing the
            // hosting view down waits for the next turn, so neither runs
            // against a removed view and both have run by then.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finishAfterEditorEnded() }
            }
        }
    }

    /// The editable field `RenameableLabel` shows, once SwiftUI has drawn it.
    var textField: NSTextField? {
        Self.firstTextField(in: view)
    }

    /// What the field holds now. Until the field is drawn and set up — it
    /// starts empty and takes its text a turn later, and nobody can type in
    /// it before it has focus — that is the text the edit opened with.
    var currentText: String {
        let opening = session.seed ?? session.originalText
        guard let field = textField else { return opening }
        let text = field.stringValue
        return text.isEmpty && field.currentEditor() == nil ? opening : text
    }

    /// Ends the edit now. With `commitPending`, what the field holds is
    /// committed by `RenameableLabel`'s own rule — trimmed, empty only when
    /// allowed, and only when it differs from the row's name — unless the
    /// editor already ended the edit itself. Without it nothing is
    /// committed: a cancel, or an edit handed over to another row.
    func close(commitPending: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if commitPending, session.isEditing {
            session.commitPending(currentText)
        }
        session.close()
        let finished = onFinished
        onFinished = nil
        finished?()
    }

    /// The editor ended the edit. `RenameableLabel` commits only text that
    /// differs from what it opened with, so a handed-over seed accepted as it
    /// was arrives with no commit; it is committed here.
    private func finishAfterEditorEnded() {
        guard !isFinished else { return }
        session.commitAcceptedSeed()
        close(commitPending: false)
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }
}

/// The state `RenameableLabel` binds to: whether the edit is open, the text
/// it started from, and where a committed name goes.
@MainActor
@Observable
final class SidebarRenameSession {
    var isEditing = true {
        didSet { if oldValue, !isEditing { onEditingEnded?() } }
    }
    /// The row's name: what a commit is compared against.
    let originalText: String
    /// The text the field opens with when it is not the row's name.
    let seed: String?
    let allowsEmptyCommit: Bool
    @ObservationIgnored var onEditingEnded: (() -> Void)?
    /// What the field held as the editor ended the edit.
    @ObservationIgnored var endedText: String?
    @ObservationIgnored private(set) var didCommit = false
    @ObservationIgnored private(set) var didCancel = false
    @ObservationIgnored private var commitName: ((String) -> Void)?

    init(text: String, seed: String?, allowsEmptyCommit: Bool, commit: @escaping (String) -> Void) {
        self.originalText = text
        self.seed = seed
        self.allowsEmptyCommit = allowsEmptyCommit
        self.commitName = commit
    }

    /// The text `RenameableLabel` opens with and compares against.
    var openingText: String { seed ?? originalText }

    /// `RenameableLabel`'s `onCommit`. Ignored once the editor has closed, so
    /// a focus-loss commit arriving after a forced close cannot land twice.
    func commit(_ name: String) {
        guard let commitName else { return }
        didCommit = true
        commitName(name)
    }

    /// `RenameableLabel`'s `onCancel`.
    func cancel() {
        didCancel = true
    }

    /// `RenameableLabel.commit()`'s rule, against the row's name, for text
    /// taken from the field when the edit is closed from outside.
    func commitPending(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if allowsEmptyCommit { commit("") }
            return
        }
        guard trimmed != originalText else { return }
        commit(trimmed)
    }

    /// A seed the editor ended on unchanged — committed rather than
    /// cancelled — renames the row as if it had been typed here.
    func commitAcceptedSeed() {
        guard let seed, !didCommit, !didCancel, let endedText else { return }
        let trimmed = endedText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed == seed.trimmingCharacters(in: .whitespaces) else { return }
        commitPending(trimmed)
    }

    func close() {
        commitName = nil
        onEditingEnded = nil
    }
}

/// `RenameableLabel` with nothing to display: the cell draws the name itself
/// whenever no edit is open.
struct SidebarRenameField: View {
    @Bindable var session: SidebarRenameSession

    var body: some View {
        RenameableLabel(
            text: session.openingText,
            isEditing: $session.isEditing,
            onCommit: { session.commit($0) },
            onCancel: { session.cancel() },
            allowsEmptyCommit: session.allowsEmptyCommit
        ) {
            EmptyView()
        }
    }
}

/// A cell that can swap its name label for a `SidebarRenameEditor`.
@MainActor
protocol SidebarRenamableCell: AnyObject {
    var renameEditor: SidebarRenameEditor? { get }
    /// Hides the name label and shows `editor.view` where it was.
    func beginRename(_ editor: SidebarRenameEditor)
    /// Removes the editor's view and shows the name label again.
    func endRename()
}

extension SidebarRenamableCell {
    var isRenaming: Bool { renameEditor != nil }

    /// A cell recycled mid-edit takes its edit with it: the label comes back
    /// now, and the field's text is committed and the controller told on the
    /// next turn. Reuse runs inside the outline's own layout, which must not
    /// see the structure hold end — and an apply start — underneath it.
    func releaseRenameForReuse() {
        guard let editor = renameEditor else { return }
        endRename()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { editor.close(commitPending: true) }
        }
    }
}

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
@MainActor
final class SidebarRenameEditor {
    let session: SidebarRenameSession
    let view: NSView
    /// Runs once, when the edit is over.
    var onFinished: (() -> Void)?
    private(set) var isFinished = false

    init(text: String, allowsEmptyCommit: Bool, commit: @escaping (String) -> Void) {
        let session = SidebarRenameSession(text: text, allowsEmptyCommit: allowsEmptyCommit, commit: commit)
        self.session = session
        let hosting = NSHostingView(rootView: SidebarRenameField(session: session))
        hosting.sizingOptions = []
        view = hosting
        session.onEditingEnded = { [weak self] in
            guard let self else { return }
            // `RenameableLabel` ends the edit from inside a SwiftUI callback
            // and calls `onCommit` right after; tearing the hosting view down
            // waits for the next turn, so neither runs against a removed view.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.close(commitPending: false) }
            }
        }
    }

    /// Ends the edit now. With `commitPending`, what the field holds is
    /// committed by `RenameableLabel`'s own rule — trimmed, empty only when
    /// allowed, and only when it differs — unless the editor already ended
    /// the edit itself. For a cell recycled mid-edit, and for a second rename
    /// starting while this one is open.
    func close(commitPending: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if commitPending, session.isEditing, let text = Self.firstTextField(in: view)?.stringValue {
            session.commitPending(text)
        }
        session.close()
        let finished = onFinished
        onFinished = nil
        finished?()
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
    let originalText: String
    let allowsEmptyCommit: Bool
    @ObservationIgnored var onEditingEnded: (() -> Void)?
    @ObservationIgnored private var commitName: ((String) -> Void)?

    init(text: String, allowsEmptyCommit: Bool, commit: @escaping (String) -> Void) {
        self.originalText = text
        self.allowsEmptyCommit = allowsEmptyCommit
        self.commitName = commit
    }

    /// `RenameableLabel`'s `onCommit`. Ignored once the editor has closed, so
    /// a focus-loss commit arriving after a forced close cannot land twice.
    func commit(_ name: String) {
        commitName?(name)
    }

    /// `RenameableLabel.commit()`'s rule, for text taken from the field when
    /// the edit is closed from outside.
    func commitPending(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if allowsEmptyCommit { commit("") }
            return
        }
        guard trimmed != originalText else { return }
        commit(trimmed)
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
            text: session.originalText,
            isEditing: $session.isEditing,
            onCommit: { session.commit($0) },
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

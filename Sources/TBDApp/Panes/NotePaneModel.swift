import Foundation
import Observation

/// The load/save state machine behind `NotePaneView`.
///
/// It lives outside the view because the thing it has to get right is a
/// *sequence*, not a rendering: one pane hosts many notes in succession, and a
/// pending write to the note being left has to land before the note being
/// entered is read. That ordering cannot be asserted through a SwiftUI view —
/// `NotePaneModelTests` asserts it here instead.
///
/// ## Why a pending save is flushed and never merely armed
///
/// `NotePaneView` is REUSED across notes: `navigateHistory` swaps the pane's
/// `noteID` while the view keeps its SwiftUI identity, so `onDisappear` does
/// not fire on a switch and `.task(id: noteID)` re-runs on the same instance.
///
/// A debounce that stays armed across that switch loses data. Edit note A;
/// inside the debounce window navigate A → B → A. The second load of A reads
/// A's file **while A's write is still pending**, so the editor comes back
/// holding the pre-edit text. The edit is not merely late — it is now the base
/// for everything typed next, and the next keystroke writes stale-base-plus-new
/// text over it.
///
/// So the unsaved text is held as data (`pendingSave`) rather than only inside
/// a task, every path that ends a debounce window *flushes* it rather than
/// cancelling it, and `load` flushes **before** it reads. Cancelling a debounce
/// task can therefore never discard an edit: the text is not in the task.
@MainActor
@Observable
final class NotePaneModel {
    /// The editor's text. Two-way bound to the `TextEditor`.
    var text: String = ""

    /// Whether `text` came from a successful read of the current note.
    ///
    /// A failed or missing load leaves this false on purpose, and `textEdited`
    /// refuses to record an edit while it is false — so a pane that never
    /// loaded cannot produce a `pendingSave`, and therefore cannot autosave its
    /// emptiness over a file that still has content.
    private(set) var loaded = false

    /// The armed debounce. Exposed so tests can await the write it performs
    /// instead of polling the filesystem; nothing in the app reads it.
    @ObservationIgnored private(set) var pendingSaveTask: Task<Void, Never>?

    /// Unsaved text, tagged with the note it belongs to.
    ///
    /// The tag is what makes a flush safe from any context: it writes to the
    /// note the text came from, never to whichever note the pane happens to be
    /// showing when the flush runs.
    @ObservationIgnored private var pendingSave: PendingSave?

    /// The note this pane is currently showing, set by `load`.
    @ObservationIgnored private var current: NoteRef?

    /// What the current note's text was last known to be on disk — the value
    /// `load` read, or the value the last save wrote. An "edit" back to exactly
    /// that is not an edit; without this, the assignment `load` makes to `text`
    /// arrives at the view's `onChange` as a change and arms a debounce that
    /// writes the file's own bytes back to it on every pane open.
    @ObservationIgnored private var savedText: String?

    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private let clock: any Clock<Duration>

    private struct PendingSave: Sendable {
        let noteID: UUID
        let worktreeID: UUID
        let text: String
    }

    private struct NoteRef: Sendable, Equatable {
        let noteID: UUID
        let worktreeID: UUID
    }

    /// - Parameter debounceInterval: quiet window before typing is persisted.
    /// - Parameter clock: last parameter, existential, defaulted — the shared
    ///   seam contract (`Tests/CLAUDE.md`, "Clock and date seams"). Existential
    ///   rather than generic so the view holding this type does not have to
    ///   become generic.
    nonisolated init(debounceInterval: Duration = .milliseconds(500),
                     clock: any Clock<Duration> = ContinuousClock()) {
        self.debounceInterval = debounceInterval
        self.clock = clock
    }

    /// Show `noteID`, reading its text off disk.
    ///
    /// Called from the view's `.task(id: noteID)`, so it runs both on first
    /// appearance and on every swap of the pane's note.
    ///
    /// **Flush first, read second.** The flush is not tidying-up: a read that
    /// overtakes a pending write to the same file observes text that has
    /// already been superseded, and the editor then holds a base nobody wrote.
    func load(noteID: UUID, worktreeID: UUID, appState: AppState) async {
        await flushPendingSave(appState: appState)

        // Reset all three, because the pane is REUSED when its slot is swapped
        // from one note to another: leaving `text` alone would show the
        // previous note's words under the new note's title for as long as the
        // load takes, or forever if it fails.
        loaded = false
        text = ""
        savedText = nil
        current = NoteRef(noteID: noteID, worktreeID: worktreeID)

        guard let content = await appState.noteContent(
            noteID: noteID, worktreeID: worktreeID
        ) else {
            // `nil` is "did not load", never "empty" — leaving `loaded` false
            // is what stops the next keystroke from saving emptiness over a
            // file whose bytes could not be read.
            return
        }
        // This task may no longer be the authoritative one. `.task(id:)`
        // cancels the outgoing task when `noteID` changes, but cancellation is
        // cooperative and the read above does not throw — so a slow load
        // started for the PREVIOUS note keeps running and would otherwise
        // assign its text here, over a note that has already loaded, and set
        // `loaded` on it. `loaded` cannot catch this: the stale task is what
        // sets it.
        guard !Task.isCancelled else { return }
        text = content
        savedText = content
        loaded = true
    }

    /// Record a keystroke and (re)arm the debounce.
    ///
    /// Cancelling the previous arm is safe here in a way it was not before the
    /// text moved into `pendingSave`: the newer arm replaces the pending text
    /// rather than discarding it.
    func textEdited(_ newValue: String, appState: AppState) {
        guard loaded, let current else { return }
        // Not an edit: this is `load`'s own assignment coming back through the
        // view's `onChange`. Skipping it only when nothing is pending matters —
        // typing and then undoing back to the saved text inside one window must
        // still resolve the armed save rather than leave it holding the
        // intermediate value.
        if newValue == savedText, pendingSave == nil { return }

        pendingSave = PendingSave(
            noteID: current.noteID, worktreeID: current.worktreeID, text: newValue)
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [clock, debounceInterval] in
            // Cancellation while still asleep surfaces as a thrown error — the
            // "a newer keystroke, or a flush, superseded me" path. Either way
            // the text survives in `pendingSave`.
            guard (try? await clock.sleep(for: debounceInterval)) != nil else { return }
            guard !Task.isCancelled else { return }
            await self.writePendingSave(appState: appState)
        }
    }

    /// Persist unsaved text now, and do not return until it has landed.
    ///
    /// Awaiting the cancelled task is what makes this a flush rather than a
    /// cancel: if the debounce was already past its cancellation check and
    /// inside the write, that write completes before this returns. Without it,
    /// `load` could still start reading a file with a write in flight — the
    /// same fault one step further in.
    func flushPendingSave(appState: AppState) async {
        let task = pendingSaveTask
        pendingSaveTask = nil
        task?.cancel()
        await task?.value
        await writePendingSave(appState: appState)
    }

    /// The pane went away (tab switch, window close). `onDisappear` cannot
    /// await, so the flush is spawned — the same shape the view has always
    /// used. The task is returned so a test can await the write; the view
    /// discards it.
    @discardableResult
    func paneDisappeared(appState: AppState) -> Task<Void, Never> {
        Task { @MainActor in
            await self.flushPendingSave(appState: appState)
        }
    }

    /// Takes the pending text and writes it. Whoever gets here first takes it:
    /// `pendingSave` is cleared **before** the `await`, so a flush racing the
    /// debounce cannot write the same text twice.
    ///
    /// An emptying write goes through `appState.saveNoteContent` like any
    /// other, which hands it to the daemon so the content file and the legacy
    /// DB column clear together.
    private func writePendingSave(appState: AppState) async {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        await appState.saveNoteContent(
            noteID: pending.noteID, worktreeID: pending.worktreeID, content: pending.text)
        if current?.noteID == pending.noteID {
            savedText = pending.text
        }
    }
}

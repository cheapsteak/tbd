import Clocks
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. The note pane's load/save sequence, driven directly.
///
/// `NotePaneView` is REUSED across notes — `navigateHistory` swaps its `noteID`
/// while the view keeps its SwiftUI identity — so the pane's riskiest behaviour
/// is a *sequence* across a note switch, and no `onDisappear` runs in between.
/// That sequence lives in `NotePaneModel` precisely so it can be asserted here;
/// the view contributes only the `$model.text` binding, the `onChange`, the
/// `.task(id:)` and the `onDisappear` that call into it.
///
/// Everything is virtual or injected: the debounce runs on a `TestClock`, and
/// content files go to a per-test temp directory through
/// `noteContentPathResolver` rather than a `TBD_HOME`-derived path —
/// `TBD_HOME` is process-global and concurrently running daemon suites
/// `setenv` it (`Tests/CLAUDE.md`). `AppState` is built against a throwaway
/// `UserDefaults` suite: `UserDefaults.standard` on this unbundled executable
/// is the developer's real `TBDApp.plist`.
@MainActor
@Suite("Note pane load/save lifecycle", .clockDriven, .serialized)
struct NotePaneModelTests {
    private static let debounce = Duration.milliseconds(500)

    /// A release gate the test opens explicitly.
    ///
    /// Used to hold a note load parked mid-read while the pane moves on to
    /// another note. It is `MainActor`-isolated rather than a
    /// `DispatchSemaphore` so nothing blocks a cooperative-pool thread
    /// (`Tests/CLAUDE.md`, "Thread-blocking gates"), and it deliberately does
    /// NOT unpark on cancellation — the point is to keep the stale load parked
    /// until the test says otherwise, cancelled or not.
    @MainActor
    private final class ReleaseGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }

    @MainActor
    private final class Harness {
        let suiteName: String
        let defaults: UserDefaults
        let dir: URL
        let state: AppState
        let clock = TestClock()
        let model: NotePaneModel
        let worktreeID = UUID()

        init() {
            suiteName = "TBDAppTests.NotePaneModel.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            let contentDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-note-pane-\(UUID().uuidString)")
            dir = contentDir
            state = AppState(userDefaults: defaults)
            state.noteContentPathResolver = { worktreeID, noteID in
                contentDir.appendingPathComponent(worktreeID.uuidString)
                    .appendingPathComponent("\(noteID.uuidString).md").path
            }
            model = NotePaneModel(debounceInterval: NotePaneModelTests.debounce, clock: clock)
        }

        /// Registers a note summary, and writes its content file when `content`
        /// is non-nil. `hasLegacyContent` drives whether a *missing* file falls
        /// back to `noteLegacyContentFetcher`.
        func seedNote(content: String?, hasLegacyContent: Bool = false) -> UUID {
            let note = NoteSummary(worktreeID: worktreeID, title: "Notes",
                                   hasLegacyContent: hasLegacyContent)
            state.notes[worktreeID, default: []].append(note)
            if let content {
                let path = path(of: note.id)
                try? FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
            return note.id
        }

        func path(of noteID: UUID) -> String {
            state.noteContentPathResolver(worktreeID, noteID)
        }

        /// The note's text as it actually sits on disk, or nil if there is no
        /// file — the distinction the whole feature turns on.
        func onDisk(_ noteID: UUID) -> String? {
            try? String(contentsOfFile: path(of: noteID), encoding: .utf8)
        }

        /// What the view's two-way binding plus `onChange` do for one keystroke.
        func type(_ newText: String) {
            model.text = newText
            model.textEdited(newText, appState: state)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func withHarness(_ body: (Harness) async -> Void) async {
        let harness = Harness()
        await body(harness)
        harness.tearDown()
    }

    /// THE regression this suite exists for.
    ///
    /// Edit A, navigate A → B → A inside the debounce window, type again. If
    /// the pending write to A is left armed rather than flushed, the second
    /// load of A reads A's file *before* that write lands and the editor comes
    /// back holding pre-edit text — so the first edit is lost, and the second
    /// save writes stale-base-plus-new-keystrokes over it.
    @Test("a history round trip inside the debounce window keeps the edit")
    func historyRoundTripDuringDebounceKeepsTheEdit() async {
        await withHarness { h in
            let noteA = h.seedNote(content: "base A")
            let noteB = h.seedNote(content: "base B")

            await h.model.load(noteID: noteA, worktreeID: h.worktreeID, appState: h.state)
            #expect(h.model.text == "base A")

            // Edit A. The clock is never advanced, so this debounce would not
            // have fired on its own.
            h.type("base A + first edit")

            // A → B → A, the pane keeping its identity the whole way.
            await h.model.load(noteID: noteB, worktreeID: h.worktreeID, appState: h.state)
            #expect(h.model.text == "base B")
            await h.model.load(noteID: noteA, worktreeID: h.worktreeID, appState: h.state)

            #expect(h.model.text == "base A + first edit",
                    "the read must not have overtaken A's pending write")
            #expect(h.onDisk(noteA) == "base A + first edit")

            // Now type on top of whatever came back — as real typing does —
            // and let the debounce fire. This is what makes the stale base
            // destructive rather than merely late: the next save is composed
            // from the text the editor is holding.
            h.type(h.model.text + " + second edit")
            await h.clock.advanceWhenSuspended(by: Self.debounce)
            await h.model.pendingSaveTask?.value

            #expect(h.onDisk(noteA) == "base A + first edit + second edit",
                    "the second save must build on the first edit, not on a stale base")
            #expect(h.onDisk(noteB) == "base B")
        }
    }

    @Test("switching notes flushes the pending save to the original note")
    func switchingNotesFlushesThePendingSaveToTheOriginalNote() async {
        await withHarness { h in
            let noteA = h.seedNote(content: "base A")
            let noteB = h.seedNote(content: "base B")

            await h.model.load(noteID: noteA, worktreeID: h.worktreeID, appState: h.state)
            h.type("edited A")

            await h.model.load(noteID: noteB, worktreeID: h.worktreeID, appState: h.state)

            #expect(h.onDisk(noteA) == "edited A",
                    "A's unsaved text must land in A's file, not follow the pane to B")
            #expect(h.onDisk(noteB) == "base B", "B must not receive A's text")
            #expect(h.model.text == "base B")
        }
    }

    /// A load that could not establish the text leaves `loaded` false, and an
    /// edit made in that state is not recorded — so neither the debounce nor a
    /// flush can write emptiness over a file whose bytes are still there.
    @Test("a failed load never saves")
    func aFailedLoadNeverSaves() async {
        await withHarness { h in
            struct Boom: Error {}
            let readable = h.seedNote(content: "words belonging to another note")
            // Missing file + a legacy column that still holds content: the
            // fallback is the only route to the text, and it fails.
            let noteA = h.seedNote(content: nil, hasLegacyContent: true)
            h.state.noteLegacyContentFetcher = { _ in throw Boom() }

            // Reach the failing note the way the pane does — by switching to
            // it, with another note's text already on screen.
            await h.model.load(noteID: readable, worktreeID: h.worktreeID, appState: h.state)
            await h.model.load(noteID: noteA, worktreeID: h.worktreeID, appState: h.state)
            #expect(!h.model.loaded)
            #expect(h.model.text == "",
                    "a note switch must clear the outgoing note's words, load or no load")

            h.type("typed into a pane that never loaded")
            #expect(h.model.pendingSaveTask == nil, "a failed load must not arm a save")

            // An emptying save would route through the daemon rather than the
            // filesystem, so watch that door too.
            var emptied = false
            h.state.noteEmptier = { _ in
                emptied = true
                return Note(worktreeID: h.worktreeID, title: "Notes", content: "")
            }
            // Both of the paths that persist: an explicit flush (note switch)
            // and the pane going away (tab switch).
            await h.model.flushPendingSave(appState: h.state)
            await h.model.paneDisappeared(appState: h.state).value

            #expect(h.onDisk(noteA) == nil, "nothing may be written for a pane that never loaded")
            #expect(!emptied, "an unloaded pane must not empty the note either")
            #expect(h.onDisk(readable) == "words belonging to another note",
                    "and nothing may reach the note the pane was showing before")
        }
    }

    /// `.task(id:)` cancels the outgoing load, but cancellation is cooperative
    /// and the read does not throw — so a slow load for the PREVIOUS note keeps
    /// running and must not assign its text over the note that has since
    /// loaded. Without the post-`await` cancellation guard the pane would end
    /// up showing A's text under B's title, with `loaded` true, and the next
    /// keystroke would write A's words into B's file.
    @Test("a stale load does not overwrite a newer note")
    func aStaleLoadDoesNotOverwriteANewerNote() async {
        await withHarness { h in
            let gate = ReleaseGate()
            let noteA = h.seedNote(content: nil, hasLegacyContent: true)
            let noteB = h.seedNote(content: "base B")
            let clock = h.clock
            h.state.noteLegacyContentFetcher = { _ in
                // Park twice: the clock sleep is what lets the test prove the
                // fetch was entered (`advanceWhenSuspended` waits for it), the
                // gate is what holds it there until the test is ready.
                try? await clock.sleep(for: .seconds(1))
                await gate.wait()
                return "stale A"
            }

            let staleLoad = Task { @MainActor in
                await h.model.load(noteID: noteA, worktreeID: h.worktreeID, appState: h.state)
            }
            await h.clock.advanceWhenSuspended(by: .seconds(1))

            // What `.task(id:)` does when the pane's note is swapped.
            staleLoad.cancel()
            await h.model.load(noteID: noteB, worktreeID: h.worktreeID, appState: h.state)
            #expect(h.model.text == "base B")

            gate.release()
            await staleLoad.value

            #expect(h.model.text == "base B", "the stale load must not assign over B")
            #expect(h.model.loaded, "B is loaded and must stay loaded")
            #expect(h.onDisk(noteB) == "base B")
        }
    }
}

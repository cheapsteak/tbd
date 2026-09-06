import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The menu as a state machine: what is showing, what is highlighted, and what
/// Enter would do.
///
/// The preselection rule is the delicate one. At the start of the input a genuine
/// prefix match is preselected, so `/comp` + Enter runs compact exactly as it
/// does in the terminal. Mid-sentence nothing is preselected, so Enter sends the
/// message and the menu engages only on Down, Tab or a click.
@MainActor
@Suite("CompletionController")
struct CompletionControllerTests {

    private func makeController(suiteName: String) -> CompletionController {
        let controller = CompletionController(
            frecency: FrecencyStore(defaults: UserDefaults(suiteName: suiteName)!))
        controller.adopt(inventory: TerminalCompletionsResult(
            commands: [
                CompletionCommand(name: "compact", description: "Compact"),
                CompletionCommand(name: "config", description: "Settings"),
                CompletionCommand(name: "clear", description: "Clear"),
            ],
            agents: [CompletionAgent(name: "Explore", description: "Search")],
            freshness: .fresh, source: .probe))
        return controller
    }

    private func run(_ body: (CompletionController) -> Void) {
        let suiteName = "CompletionControllerTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        body(makeController(suiteName: suiteName))
    }

    @Test func typingASlashOpensIt() {
        run { c in
            c.update(text: "/", selectionLocation: 1, hasMarkedText: false)
            #expect(c.isOpen)
            #expect(c.presentation == .rows)
            #expect(!c.rows.isEmpty)
        }
    }

    @Test func typingFiltersSynchronously() {
        run { c in
            c.update(text: "/comp", selectionLocation: 5, hasMarkedText: false)
            #expect(c.rows.map(\.id) == ["compact"])
        }
    }

    /// At the start of the input, a genuine prefix match is preselected, so
    /// `/comp` + Enter runs compact as it does in the terminal.
    @Test func aPrefixMatchAtTheStartIsPreselected() {
        run { c in
            c.update(text: "/comp", selectionLocation: 5, hasMarkedText: false)
            #expect(c.selectedIndex == 0)
            #expect(c.acceptTarget?.id == "compact")
        }
    }

    /// `/xyz` + Enter must SEND, not accept a row that merely fuzzy-matched.
    @Test func aNonPrefixQueryPreselectsNothing() {
        run { c in
            c.update(text: "/xyz", selectionLocation: 4, hasMarkedText: false)
            #expect(c.selectedIndex == nil)
        }
    }

    /// **Mid-sentence nothing is preselected**, so Enter sends the message.
    @Test func aMidSentenceTokenPreselectsNothing() {
        run { c in
            c.update(text: "please /comp", selectionLocation: 12, hasMarkedText: false)
            #expect(c.isOpen)
            #expect(c.selectedIndex == nil)
            // Tab still accepts the first row — that is the accept gesture.
            #expect(c.acceptTarget?.id == "compact")
        }
    }

    @Test func arrowsMoveAndWrap() {
        run { c in
            c.update(text: "/c", selectionLocation: 2, hasMarkedText: false)
            let count = c.rows.count
            #expect(count >= 3)
            c.moveDown()
            #expect(c.selectedIndex == 1)
            for _ in 0..<count { c.moveDown() }
            #expect(c.selectedIndex == 1, "moving down \(count) times must wrap back around")
            c.moveUp()
            #expect(c.selectedIndex == 0)
            c.moveUp()
            #expect(c.selectedIndex == count - 1, "up from the top wraps to the bottom")
        }
    }

    /// **Escape closes it and keeps it closed for that token until the token
    /// changes.** Without the second half, the menu reopens on the next keystroke
    /// and Escape means nothing.
    @Test func escapeSuppressesUntilTheTokenChanges() {
        run { c in
            c.update(text: "/comp", selectionLocation: 5, hasMarkedText: false)
            c.close(suppressingCurrentToken: true)
            #expect(!c.isOpen)

            // Same token, re-evaluated: still closed.
            c.update(text: "/comp", selectionLocation: 5, hasMarkedText: false)
            #expect(!c.isOpen)

            // The token changed: it reopens.
            c.update(text: "/compa", selectionLocation: 6, hasMarkedText: false)
            #expect(c.isOpen)
        }
    }

    /// No menu opens or updates while an input method has marked text.
    @Test func compositionKeepsItClosed() {
        run { c in
            c.update(text: "/comp", selectionLocation: 5, hasMarkedText: true)
            #expect(!c.isOpen)
        }
    }

    /// Before the inventory lands, a single dim row — and NOTHING preselected, so
    /// Enter cannot accept a row that appeared under the finger.
    @Test func withNoInventoryItShowsLoadingAndPreselectsNothing() {
        let suiteName = "CompletionControllerTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let c = CompletionController(
            frecency: FrecencyStore(defaults: UserDefaults(suiteName: suiteName)!))
        c.update(text: "/comp", selectionLocation: 5, hasMarkedText: false)
        #expect(c.presentation == .loading)
        #expect(c.selectedIndex == nil)
        #expect(c.acceptTarget == nil)
    }

    /// "No commands match" only once the query is longer than one character —
    /// a single letter that matches nothing is almost always mid-typing.
    @Test func noMatchAppearsOnlyPastOneCharacter() {
        run { c in
            c.update(text: "/z", selectionLocation: 2, hasMarkedText: false)
            #expect(c.presentation != .noMatch)
            c.update(text: "/zqq", selectionLocation: 4, hasMarkedText: false)
            #expect(c.presentation == .noMatch)
        }
    }

    /// The at-sign offers subagents, and only subagents in this version.
    @Test func theAtSignOffersAgents() {
        run { c in
            c.update(text: "@Exp", selectionLocation: 4, hasMarkedText: false)
            #expect(c.rows.map(\.id) == ["Explore"])
        }
    }
}

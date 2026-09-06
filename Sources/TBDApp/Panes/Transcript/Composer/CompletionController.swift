import Foundation
import Observation
import TBDShared

/// The completion menu's state: what is showing, what is highlighted, and what
/// an accept would take.
///
/// Shaped like `JumpMenuViewModel` — query in, rows out, a selection that moves —
/// and pure in the same sense: it owns no view, touches no daemon, and every test
/// drives it by calling `update`.
///
/// **Filtering is synchronous on every keystroke, with no debounce.** The list is
/// at most a few hundred items and the rows are memoized by query, so the work is
/// a sort; a debounce would only make the menu lag behind the typing it is
/// describing.
@Observable
@MainActor
final class CompletionController {

    enum Presentation: Equatable {
        case closed
        /// The inventory has not arrived. One dim row, nothing preselected.
        case loading
        case rows
        case noMatch
    }

    /// Eight rows visible, in a list with a fixed maximum height and a scroller,
    /// so a change in row count never shifts the layout under the caret.
    static let visibleRowCount = 8

    private(set) var match: CompletionTrigger.Match?
    private(set) var rows: [CommandRanker.Row] = []
    private(set) var selectedIndex: Int?
    private(set) var presentation: Presentation = .closed

    private let frecency: FrecencyStore
    private var commands: [CompletionCommand] = []
    private var agents: [CompletionAgent] = []
    private var hasInventory = false
    /// The token Escape closed the menu for. Cleared as soon as the token
    /// changes, which is what makes Escape mean something without making it a
    /// mode.
    private var suppressedToken: String?
    /// Memoized rows, keyed by the kind and query that produced them.
    private var memoKey: String?
    private var memoRows: [CommandRanker.Row] = []

    init(frecency: FrecencyStore) {
        self.frecency = frecency
    }

    var isOpen: Bool {
        switch presentation {
        case .closed: return false
        case .loading, .rows, .noMatch: return true
        }
    }

    func adopt(inventory: TerminalCompletionsResult?) {
        guard let inventory else { return }
        commands = inventory.commands
        agents = inventory.agents
        hasInventory = true
        memoKey = nil
        // Re-evaluate against the text that is already there, so a menu showing
        // its loading row swaps in real rows the moment the cache lands.
        if let match {
            apply(match: match)
        }
    }

    /// The one entry point the text view calls after every edit and every
    /// selection change.
    func update(text: String, selectionLocation: Int, hasMarkedText: Bool) {
        // No menu opens or updates during composition: the candidate window owns
        // those keystrokes, and a list appearing under it would fight for them.
        guard !hasMarkedText else { return dismiss() }
        guard let found = CompletionTrigger.detect(
            text: text, selectionLocation: selectionLocation) else { return dismiss() }
        let currentToken = token(for: found)
        if let suppressedToken, suppressedToken == currentToken {
            match = found
            presentation = .closed
            return
        }
        suppressedToken = nil
        apply(match: found)
    }

    /// The identity of a query: its sigil kind and the text after it. Used both
    /// as the memoization key and as the token Escape suppresses, so the two can
    /// never drift apart.
    private func token(for found: CompletionTrigger.Match) -> String {
        "\(found.kind)\u{1}\(found.query)"
    }

    private func apply(match found: CompletionTrigger.Match) {
        match = found
        guard hasInventory else {
            rows = []
            selectedIndex = nil
            presentation = .loading
            return
        }
        let key = token(for: found)
        if memoKey != key {
            memoKey = key
            memoRows = CommandRanker.rank(
                commands: found.kind == .command
                    ? commands
                    : agents.map {
                        CompletionCommand(name: $0.name, description: $0.description)
                    },
                query: found.query,
                frecency: { [frecency] name in frecency.score(name) })
        }
        rows = memoRows

        if rows.isEmpty {
            // One character that matches nothing is almost always mid-typing;
            // saying "no commands match" there is noise.
            presentation = found.query.count > 1 ? .noMatch : .rows
            selectedIndex = nil
            return
        }
        presentation = .rows
        selectedIndex = preselectedIndex(for: found)
    }

    /// At the start of the input, preselect the first row on a GENUINE prefix
    /// match of the name, an alias, or a segment — so `/comp` + Enter runs
    /// compact as it does in the terminal, and `/xyz` + Enter sends a message.
    ///
    /// Mid-sentence nothing is preselected: a slash token there is text to Claude
    /// Code, which expands a command only at the start of a message, so Enter
    /// must send and the menu engages only on Down, Tab or a click.
    private func preselectedIndex(for found: CompletionTrigger.Match) -> Int? {
        guard found.sigilLocation == 0, !found.query.isEmpty, let first = rows.first
        else { return nil }
        let needle = found.query.lowercased()
        let name = first.command.name.lowercased()
        let prefixes = name.hasPrefix(needle)
            || first.command.aliases.contains { $0.lowercased().hasPrefix(needle) }
            || CommandRanker.segments(name).contains { $0.hasPrefix(needle) }
        return prefixes ? 0 : nil
    }

    func moveDown() {
        guard !rows.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? -1) + 1) % rows.count
    }

    func moveUp() {
        guard !rows.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? 0) - 1 + rows.count) % rows.count
    }

    /// A click, or a hover the view chose to promote. Bounds-checked rather than
    /// clamped: a stale index from a list that has already re-ranked would
    /// otherwise highlight whatever now sits at that position.
    func moveTo(index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// What Tab or Return would take: the highlighted row, or the first when none
    /// is highlighted. Tab is the accept gesture the composer surfaces in any
    /// hint it shows.
    var acceptTarget: CommandRanker.Row? {
        guard case .rows = presentation else { return nil }
        if let selectedIndex, rows.indices.contains(selectedIndex) { return rows[selectedIndex] }
        return rows.first
    }

    /// Escape, or the caret leaving the token. `suppressingCurrentToken` is what
    /// makes Escape stick: without it the menu reopens on the next keystroke and
    /// Escape means nothing.
    func close(suppressingCurrentToken: Bool) {
        if suppressingCurrentToken, let match {
            suppressedToken = token(for: match)
        }
        presentation = .closed
        selectedIndex = nil
    }

    func recordAcceptance(_ row: CommandRanker.Row) {
        frecency.record(row.command.name)
        dismiss()
    }

    private func dismiss() {
        match = nil
        rows = []
        selectedIndex = nil
        presentation = .closed
    }
}

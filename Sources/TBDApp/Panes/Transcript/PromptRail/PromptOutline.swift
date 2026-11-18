import Foundation
import TBDShared

/// One navigable entry of the transcript prompt rail: a typed prompt or a
/// peer message, located by its index in the node array it was built from.
struct PromptOutlineEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case prompt
        case peer(sender: String)
    }

    /// The render node's id.
    let id: String
    /// Index of the node in the array the entry was built from.
    let rowIndex: Int
    let kind: Kind
    let firstLine: String
    let timestamp: Date?
}

/// Pure projection of render nodes into rail entries. Reads node data only;
/// nothing here builds or measures a cell.
enum PromptOutline {
    /// What one node contributes to the outline apart from where it sits:
    /// everything in its entry but the row index. A node's projection
    /// depends on its content alone, so `PromptOutlineCache` keeps it by
    /// `(id, contentVersion)` across rebuilds.
    struct Projection: Equatable {
        let id: String
        let kind: PromptOutlineEntry.Kind
        let firstLine: String
        let timestamp: Date?

        func entry(rowIndex: Int) -> PromptOutlineEntry {
            PromptOutlineEntry(id: id, rowIndex: rowIndex, kind: kind, firstLine: firstLine, timestamp: timestamp)
        }
    }

    static func entries(from nodes: [TranscriptRenderNode]) -> [PromptOutlineEntry] {
        var result: [PromptOutlineEntry] = []
        for (index, node) in nodes.enumerated() where isCandidate(node) {
            if let projection = projection(of: node) { result.append(projection.entry(rowIndex: index)) }
        }
        return result
    }

    /// Whether `node` is a prompt or a peer message bubble, the only nodes
    /// `projection(of:)` can turn into an entry. A kind check; reads no text.
    static func isCandidate(_ node: TranscriptRenderNode) -> Bool {
        guard case .chatBubble(let item) = node.kind else { return false }
        switch item {
        case .userPrompt, .peerMessage:
            return true
        default:
            return false
        }
    }

    /// The entry `node` makes, less its row index; nil for a node that makes
    /// none: anything but a prompt or a peer message, and a prompt nobody
    /// typed (`UserMessageClassifier.isUntypedPromptMarker`).
    static func projection(of node: TranscriptRenderNode) -> Projection? {
        guard case .chatBubble(let item) = node.kind else { return nil }
        switch item {
        case .userPrompt(let id, let text, let timestamp):
            if UserMessageClassifier.isUntypedPromptMarker(text) { return nil }
            return projection(id: id, kind: .prompt, text: text, timestamp: timestamp)
        case .peerMessage(let id, let sender, let text, _, let timestamp):
            return projection(
                id: id, kind: .peer(sender: PeerHeaderChrome.displayName(for: sender)),
                text: text, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func projection(
        id: String, kind: PromptOutlineEntry.Kind, text: String, timestamp: Date?
    ) -> Projection {
        Projection(id: id, kind: kind, firstLine: firstLine(of: text), timestamp: timestamp)
    }

    /// First line with non-whitespace content of the unwrapped text, whitespace
    /// runs collapsed to one space and trimmed.
    static func firstLine(of text: String) -> String {
        firstLine(ofUnwrapped: TranscriptPastedContent.unwrap(text))
    }

    /// `firstLine(of:)` for text already unwrapped. Reads only as far as the
    /// end of the first line with content: that line is the one holding the
    /// first non-whitespace character, so nothing after it is split or read.
    private static func firstLine(ofUnwrapped text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return "" }
        let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        return text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Work

    /// The work each entry's turn did, parallel to `entries`, which must have
    /// been built from `nodes`. A turn runs from its entry's row up to the next
    /// entry's row, or to the end of `nodes`; each row in it adds
    /// `work(of:)`. An integer pass over node kinds: no text is read, and
    /// nothing here builds or measures a cell.
    static func workCounts(for entries: [PromptOutlineEntry], in nodes: [TranscriptRenderNode]) -> [Int] {
        var counts: [Int] = []
        counts.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let start = min(entry.rowIndex + 1, nodes.count)
            let next = index + 1 < entries.count ? entries[index + 1].rowIndex : nodes.count
            let end = max(start, min(next, nodes.count))
            var total = 0
            for row in start..<end { total += work(of: nodes[row]) }
            counts.append(total)
        }
        return counts
    }

    /// The work one row stands for: one for a tool call, a subagent launch
    /// included, and for a collapsed activity group its tool calls. An
    /// expanded group stands for nothing itself: its members follow it as rows
    /// of their own and count there. Every other row is no work; a subagent's
    /// own steps live in its transcript file, which the pane does not read.
    static func work(of node: TranscriptRenderNode) -> Int {
        switch node.kind {
        case .toolCall:
            return 1
        case .activityGroupSummary(let summary):
            return summary.isExpanded ? 0 : summary.toolCallCount
        case .chatBubble, .systemReminder, .skillBody, .subagentSummary, .thinking:
            return 0
        }
    }

    /// "1 tool call", "40 tool calls": a turn's work as the rail's
    /// accessibility labels say it.
    static func workLabel(_ count: Int) -> String {
        count == 1 ? "1 tool call" : "\(count) tool calls"
    }

    /// The lens rows' time column for entries with `timestamps`, in order.
    /// Today's entries each show their time (`timeLabel`). An earlier day's
    /// entries are listed in order, so only its first shows the date and the
    /// rest of that day show nothing. An entry without a timestamp shows
    /// nothing and starts no day: the next one with a timestamp is compared
    /// with the last that had one.
    static func timeColumn(_ timestamps: [Date?], now: Date, calendar: Calendar, locale: Locale) -> [String] {
        var labels: [String] = []
        labels.reserveCapacity(timestamps.count)
        var lastDated: Date?
        for timestamp in timestamps {
            guard let date = timestamp else {
                labels.append("")
                continue
            }
            let today = calendar.isDate(date, inSameDayAs: now)
            let sameDay = lastDated.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
            labels.append((today || !sameDay) ? timeLabel(date, now: now, calendar: calendar, locale: locale) : "")
            lastDated = date
        }
        return labels
    }

    /// Today: short local time. Earlier: abbreviated month and day.
    static func timeLabel(_ date: Date?, now: Date, calendar: Calendar, locale: Locale) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale,
                calendar: calendar, timeZone: calendar.timeZone))
        }
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day())
    }
}

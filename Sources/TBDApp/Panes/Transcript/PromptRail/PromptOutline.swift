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
    /// Unwrapped body, first `PromptOutline.tooltipLimit` characters.
    let tooltip: String
    let timestamp: Date?
}

/// Pure projection of render nodes into rail entries. Reads node data only;
/// nothing here builds or measures a cell.
enum PromptOutline {
    static let tooltipLimit = 500

    static func entries(from nodes: [TranscriptRenderNode]) -> [PromptOutlineEntry] {
        var result: [PromptOutlineEntry] = []
        for (index, node) in nodes.enumerated() {
            guard case .chatBubble(let item) = node.kind else { continue }
            switch item {
            case .userPrompt(let id, let text, let timestamp):
                if UserMessageClassifier.isUntypedPromptMarker(text) { continue }
                result.append(entry(id: id, rowIndex: index, kind: .prompt, text: text, timestamp: timestamp))
            case .peerMessage(let id, let sender, let text, _, let timestamp):
                result.append(entry(
                    id: id, rowIndex: index,
                    kind: .peer(sender: PeerHeaderChrome.displayName(for: sender)),
                    text: text, timestamp: timestamp))
            default:
                continue
            }
        }
        return result
    }

    private static func entry(
        id: String, rowIndex: Int, kind: PromptOutlineEntry.Kind, text: String, timestamp: Date?
    ) -> PromptOutlineEntry {
        PromptOutlineEntry(
            id: id,
            rowIndex: rowIndex,
            kind: kind,
            firstLine: firstLine(of: text),
            tooltip: String(TranscriptPastedContent.unwrap(text).prefix(tooltipLimit)),
            timestamp: timestamp)
    }

    /// First line with non-whitespace content of the unwrapped text, whitespace
    /// runs collapsed to one space and trimmed.
    static func firstLine(of text: String) -> String {
        let unwrapped = TranscriptPastedContent.unwrap(text)
        for line in unwrapped.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            if !words.isEmpty { return words.joined(separator: " ") }
        }
        return ""
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

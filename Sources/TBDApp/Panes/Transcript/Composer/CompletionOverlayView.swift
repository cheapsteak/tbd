import SwiftUI

/// The completion list: a SwiftUI overlay **inside the pane**, never a separate
/// window.
///
/// The text view keeps first responder, so the caret keeps blinking and the IME
/// candidate panel keeps working while the list has logical focus. The transcript
/// pane already renders a SwiftUI overlay above its AppKit table, so this is a
/// shape it is known to support. A non-key child window is the fallback if
/// clipping ever bites — and it is the fallback rather than the default because
/// the floating-panel code documents that adding a child window to the split-view
/// window raises an exception.
///
/// It opens **upward** from the composer, and its height is fixed at eight rows
/// with a scroller, so a change in row count never shifts the text field under
/// the caret.
struct CompletionOverlayView: View {
    let controller: CompletionController
    let onAccept: (CommandRanker.Row) -> Void
    let onHighlight: (Int) -> Void

    /// The row the pointer is over. Deliberately SEPARATE from the controller's
    /// `selectedIndex`: hover previews a row without moving the keyboard cursor,
    /// so a pointer resting over the list cannot change what Return would take.
    @State private var hoveredIndex: Int?

    static let rowHeight: CGFloat = 44
    static let maxHeight: CGFloat = rowHeight * CGFloat(CompletionController.visibleRowCount)

    var body: some View {
        // `.closed` renders nothing at all — no chrome, no zero-height frame —
        // rather than falling through to the background/stroke/shadow modifiers
        // below, which would otherwise paint a hairline and shadow around an
        // empty layout.
        if case .closed = controller.presentation {
            EmptyView()
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VisualEffectView(material: .menu, blendingMode: .withinWindow))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 8, y: 2)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.presentation {
        case .closed:
            EmptyView()
        case .loading:
            message("Loading commands")
        case .noMatch:
            message("No commands match")
        case .rows:
            // Defensive. The controller reaches `.rows` only with rows to show:
            // a query that matches nothing goes to `.noMatch`, or closes
            // outright at one character, where "no commands match" would be
            // noise on a keystroke somebody is still typing. `rows` is published
            // separately from `presentation`, though, so the empty case is
            // rendered as that same sentence rather than as an empty scroll
            // view — a branch that should never run, and says something if it
            // does.
            if controller.rows.isEmpty {
                message("No commands match")
            } else {
                list
            }
        }
    }

    /// A single dim row while the inventory is in flight, with nothing
    /// preselected — so Enter cannot accept a row that appeared under the finger.
    @ViewBuilder
    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                        CompletionRowView(
                            row: row,
                            isSelected: index == controller.selectedIndex,
                            isHovered: index == hoveredIndex)
                        .id(row.id)
                        .contentShape(Rectangle())
                        // Hover PREVIEWS: it emphasizes the row and moves
                        // nothing, so what Return would take does not change
                        // under a resting pointer.
                        .onHover { inside in
                            if inside {
                                hoveredIndex = index
                            } else if hoveredIndex == index {
                                hoveredIndex = nil
                            }
                        }
                        // A click HIGHLIGHTS rather than runs. Mouse mis-clicks
                        // on a list are common and these rows are much larger
                        // targets than a terminal's, so a click that ran a
                        // command would be a command nobody chose.
                        .onTapGesture { onHighlight(index) }
                    }
                }
            }
            .frame(maxHeight: Self.maxHeight)
            .onChange(of: controller.selectedIndex) { _, index in
                guard let index, controller.rows.indices.contains(index) else { return }
                proxy.scrollTo(controller.rows[index].id, anchor: .center)
            }
        }
    }
}

/// One row: the name with a matched alias in parentheses, the one-line
/// description, and the argument hint. Matched characters highlighted.
private struct CompletionRowView: View {
    let row: CommandRanker.Row
    let isSelected: Bool
    /// The pointer is over this row. A weaker emphasis than selection, and it
    /// carries no accessibility trait — nothing has moved.
    let isHovered: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    highlightedName
                    if let alias = row.matchedAlias {
                        Text("(\(alias))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let hint = row.command.argumentHint, !hint.isEmpty {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !row.command.description.isEmpty {
                    Text(row.command.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: CompletionOverlayView.rowHeight)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        // Every row carries a label, and the highlighted one is announced as the
        // selection moves — the list has logical focus while the text view holds
        // first responder, so VoiceOver has no other way to follow it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var parts = [row.command.name]
        if let alias = row.matchedAlias { parts.append("alias \(alias)") }
        if !row.command.description.isEmpty { parts.append(row.command.description) }
        if let hint = row.command.argumentHint, !hint.isEmpty { parts.append("takes \(hint)") }
        return parts.joined(separator: ", ")
    }

    /// Matched characters bolded. Built from the ranker's UTF-16 ranges, so the
    /// highlight and the match cannot disagree.
    private var highlightedName: some View {
        let name = row.command.name as NSString
        var runs: [Text] = []
        var cursor = 0
        for range in row.matchedRanges {
            if range.location > cursor {
                runs.append(Text(
                    name.substring(with: NSRange(
                        location: cursor, length: range.location - cursor))))
            }
            runs.append(Text(name.substring(with: range)).bold())
            cursor = range.location + range.length
        }
        if cursor < name.length {
            runs.append(Text(name.substring(from: cursor)))
        }
        return runs.reduce(Text(""), +).font(.callout)
    }
}

import AppKit
import SwiftUI
import TBDShared

// MARK: - Panel anchor (manages FloatingPanel lifecycle from SwiftUI)

struct EmojiPanelAnchor: NSViewRepresentable {
    let isPresented: Bool
    let query: String
    @Binding var selectedIndex: Int
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        if isPresented {
            let content = EmojiPickerView(
                query: query,
                selectedIndex: $selectedIndex,
                onSelect: onSelect
            )
            .background(.ultraThickMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let panel = coordinator.panel {
                panel.updateContent(content)
                panel.show(relativeTo: nsView)
            } else {
                let panel = FloatingPanel(content: content)
                coordinator.panel = panel
                panel.show(relativeTo: nsView)
            }
        } else {
            coordinator.panel?.dismiss()
            coordinator.panel = nil
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.panel?.dismiss()
        coordinator.panel = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var anchor: NSView?
        var panel: FloatingPanel?
    }
}

// MARK: - Emoji picker grid

struct EmojiPickerView: View {
    let query: String
    @Binding var selectedIndex: Int
    let onSelect: (String) -> Void

    @State private var frecency = EmojiFrecency.load()

    private static let columns = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7)

    private var results: [EmojiData.Entry] {
        if query.isEmpty {
            return frecency.defaults()
        }
        return frecency.search(query, limit: 21)
    }

    var body: some View {
        let items = results
        if items.isEmpty {
            Text("No emoji found")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                LazyVGrid(columns: Self.columns, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.name) { index, entry in
                        Text(entry.emoji)
                            .font(.title3)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(index == clampedIndex(items.count) ? Color.accentColor.opacity(0.3) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(entry.emoji)
                            }
                            .help(entry.name.replacingOccurrences(of: "_", with: " "))
                    }
                }
            }
            .padding(6)
            .frame(width: 240, height: gridHeight(for: items.count), alignment: .topLeading)
        }
    }

    private func gridHeight(for count: Int) -> CGFloat {
        let rows = ceil(Double(count) / 7.0)
        let cellHeight: CGFloat = 32
        let spacing: CGFloat = 2
        return rows * cellHeight + max(0, rows - 1) * spacing + 12 // 12 = padding
    }

    private func clampedIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(selectedIndex, count - 1)
    }

    private func select(_ emoji: String) {
        onSelect(emoji)
    }
}

// MARK: - Frecency tracking

/// Tracks frequently/recently used emoji via UserDefaults.
struct EmojiFrecency: Sendable {
    private static let key = "emojiPicker.frecency"
    private static let maxEntries = 21

    /// Gitmoji — curated for git worktree naming context.
    /// These get a baseline frecency boost so they surface in search results.
    static let gitmoji: [String] = [
        "✨", "🐛", "🚀", "🔥", "♻️", "🎨", "📝",
        "✅", "🚧", "⚡️", "💄", "🎉", "🔒️", "🩹",
        "⬆️", "🏗️", "🧪", "💥", "🗑️", "👽️", "🔧",
    ]

    private var usage: [String: UsageRecord]

    struct UsageRecord: Codable, Sendable {
        var count: Int
        var lastUsed: Date
    }

    static func load() -> EmojiFrecency {
        guard let data = UserDefaults.standard.data(forKey: key),
              let usage = try? JSONDecoder().decode([String: UsageRecord].self, from: data) else {
            return EmojiFrecency(usage: [:])
        }
        return EmojiFrecency(usage: usage)
    }

    mutating func record(_ emoji: String) {
        var record = usage[emoji] ?? UsageRecord(count: 0, lastUsed: .distantPast)
        record.count += 1
        record.lastUsed = Date()
        usage[emoji] = record
        save()
    }

    /// Returns frequently used emoji as EmojiData entries, falling back to gitmoji defaults.
    func defaults() -> [EmojiData.Entry] {
        let sorted = usage
            .sorted { a, b in frecencyScore(a.value) > frecencyScore(b.value) }
            .prefix(Self.maxEntries)
            .compactMap { pair in EmojiData.all.first(where: { $0.emoji == pair.key }) }

        if sorted.count >= 7 {
            return Array(sorted)
        }

        // Pad with gitmoji defaults (skip any already in frequent list)
        let frequentEmoji = Set(sorted.map(\.emoji))
        let fallbacks = Self.gitmoji
            .filter { !frequentEmoji.contains($0) }
            .compactMap { emoji in EmojiData.all.first(where: { $0.emoji == emoji }) }
        return Array((sorted + fallbacks).prefix(Self.maxEntries))
    }

    /// Search with frecency boost — frequently used and gitmoji matches sort first.
    func search(_ query: String, limit: Int = 21) -> [EmojiData.Entry] {
        let matches = EmojiData.search(query, limit: limit * 2) // overfetch to re-rank
        guard !matches.isEmpty else { return [] }
        let gitmojiSet = Set(Self.gitmoji)
        let sorted = matches.sorted { a, b in
            let scoreA = scoreFor(a.emoji, gitmojiSet: gitmojiSet)
            let scoreB = scoreFor(b.emoji, gitmojiSet: gitmojiSet)
            if scoreA != scoreB { return scoreA > scoreB }
            return false
        }
        return Array(sorted.prefix(limit))
    }

    private func scoreFor(_ emoji: String, gitmojiSet: Set<String>) -> Double {
        if let record = usage[emoji] {
            return frecencyScore(record)
        }
        // Gitmoji get a baseline score of 1 so they float above unknowns
        return gitmojiSet.contains(emoji) ? 1.0 : 0.0
    }

    private func frecencyScore(_ record: UsageRecord) -> Double {
        let recency = Date().timeIntervalSince(record.lastUsed)
        let hoursSinceUse = recency / 3600
        // Decay: halve relevance every 48 hours
        let decay = pow(0.5, hoursSinceUse / 48)
        return Double(record.count) * decay
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

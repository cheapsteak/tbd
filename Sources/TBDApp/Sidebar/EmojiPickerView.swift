import SwiftUI
import TBDShared

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
            .frame(width: 240)
        }
    }

    private func clampedIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(selectedIndex, count - 1)
    }

    func selectedEmoji() -> String? {
        let items = results
        guard !items.isEmpty else { return nil }
        return items[clampedIndex(items.count)].emoji
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

    /// Gitmoji defaults — curated for git worktree naming context.
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

    /// Search with frecency boost — frequently used matches sort first.
    func search(_ query: String, limit: Int = 21) -> [EmojiData.Entry] {
        let matches = EmojiData.search(query, limit: limit * 2) // overfetch to re-rank
        guard !matches.isEmpty else { return [] }
        let sorted = matches.sorted { a, b in
            let scoreA = usage[a.emoji].map { frecencyScore($0) } ?? 0
            let scoreB = usage[b.emoji].map { frecencyScore($0) } ?? 0
            if scoreA != scoreB { return scoreA > scoreB }
            // Tie-break: preserve original search relevance order
            return false
        }
        return Array(sorted.prefix(limit))
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

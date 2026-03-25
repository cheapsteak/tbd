import SwiftUI
import TBDShared

struct EmojiPickerView: View {
    let query: String
    @Binding var selectedIndex: Int
    let onSelect: (String) -> Void

    private var matches: [EmojiData.Entry] {
        EmojiData.search(query)
    }

    var body: some View {
        let results = matches
        if results.isEmpty {
            Text("No emoji found")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.name) { index, entry in
                    HStack(spacing: 8) {
                        Text(entry.emoji)
                            .font(.body)
                        Text(entry.name.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.primary)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == clampedIndex(results.count) ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(entry.emoji) }
                }
            }
            .padding(4)
            .frame(width: 200)
        }
    }

    private func clampedIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(selectedIndex, count - 1)
    }

    /// Returns the emoji for the currently selected index, if any matches exist.
    func selectedEmoji() -> String? {
        let results = matches
        guard !results.isEmpty else { return nil }
        return results[clampedIndex(results.count)].emoji
    }
}

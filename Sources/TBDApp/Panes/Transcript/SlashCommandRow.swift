import SwiftUI
import TBDShared

struct SlashCommandRow: View {
    let id: String
    let name: String
    let args: String?
    let timestamp: Date?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "command")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("/\(name)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let a = args, !a.isEmpty {
                Text(a)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let ts = timestamp {
                Text(ts.absoluteShort).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }
}

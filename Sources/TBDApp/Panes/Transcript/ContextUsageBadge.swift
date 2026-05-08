import SwiftUI

/// Diminutive subscript line shown beneath the latest top-level assistant
/// item in the transcript viewer. Displays the total prompt size
/// (input + cache_creation + cache_read tokens) of that turn's API call
/// as `Nk tokens` in muted gray, prefixed by a small colored dot whose
/// color signals the band:
///
/// - `<190k`  → `.secondary`
/// - `>=190k` → yellow
/// - `>=260k` → orange
/// - `>=300k` → red
///
/// See `docs/transcript-context-usage.md` for the underlying mechanism.
struct ContextUsageBadge: View {
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(Self.color(for: total))
            Text(Self.formatted(total))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9))
        .fontWeight(.regular)
        .opacity(0.7)
    }

    /// Whole-thousands abbreviation, e.g. 124_300 -> "124k tokens".
    static func formatted(_ total: Int) -> String {
        "\(total / 1000)k tokens"
    }

    static func color(for total: Int) -> Color {
        switch total {
        case ..<190_000:  return .secondary
        case ..<260_000:  return .yellow
        case ..<300_000:  return .orange
        default:          return .red
        }
    }
}

// MARK: - Preview

/// Exercises the four threshold bands. Uses `PreviewProvider` (not the
/// `#Preview` macro) so the file still compiles under bare `swift build`
/// — the SPM toolchain doesn't ship the `PreviewsMacros` plugin that
/// Xcode injects.
struct ContextUsageBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 4) {
            ContextUsageBadge(total: 12_345)      // muted
            ContextUsageBadge(total: 200_000)     // yellow
            ContextUsageBadge(total: 270_000)     // orange
            ContextUsageBadge(total: 350_000)     // red
        }
        .padding()
        .previewDisplayName("ContextUsageBadge — bands")
    }
}

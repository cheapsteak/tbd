import SwiftUI

/// Diminutive subscript line shown beneath the latest top-level assistant
/// item in the transcript viewer. Displays the total prompt size
/// (input + cache_creation + cache_read tokens) of that turn's API call
/// as `Nk tokens` in muted gray.
///
/// See `docs/transcript-context-usage.md` for the underlying mechanism.
struct ContextUsageBadge: View {
    let total: Int

    var body: some View {
        Text(Self.formatted(total))
            .foregroundStyle(.secondary)
            .font(.system(size: 9))
            .fontWeight(.regular)
            .opacity(0.7)
    }

    /// Whole-thousands abbreviation, e.g. 124_300 -> "124k tokens".
    nonisolated static func formatted(_ total: Int) -> String {
        "\(total / 1000)k tokens"
    }
}

// MARK: - Preview

/// Uses `PreviewProvider` (not the `#Preview` macro) so the file still
/// compiles under bare `swift build` — the SPM toolchain doesn't ship the
/// `PreviewsMacros` plugin that Xcode injects.
struct ContextUsageBadge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 4) {
            ContextUsageBadge(total: 12_345)
            ContextUsageBadge(total: 200_000)
            ContextUsageBadge(total: 270_000)
            ContextUsageBadge(total: 350_000)
        }
        .padding()
        .previewDisplayName("ContextUsageBadge")
    }
}

import Foundation

/// The truncate-with-ellipsis rule shared by every place in this directory
/// that quotes raw vendor output into a bounded diagnostic message. Callers
/// own their own pre-processing — trimming, ANSI stripping, or neither — this
/// is only the cut: reserve the last character of `limit` for the ellipsis,
/// so the quoted text plus its ellipsis never exceeds `limit` characters.
enum ClaudeCloudTextBounding {
    static func truncated(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

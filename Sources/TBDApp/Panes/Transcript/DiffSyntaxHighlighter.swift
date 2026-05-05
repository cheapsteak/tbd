import Foundation
import AppKit
import Highlightr

/// Shared `Highlightr` instance themed to match the GitHub palette used
/// elsewhere in the transcript view. Construction is lazy + once-per-app.
enum DiffSyntaxHighlighter {

    nonisolated(unsafe) private static let shared: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "github")
        return h
    }()

    /// Map file extensions → highlight.js language identifiers. Ported
    /// verbatim from gh-review (cheapsteak/gh-review). Covers the 30 most
    /// common languages we expect to see in worktrees.
    static func languageForFilename(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "swift": "swift", "ts": "typescript", "tsx": "typescript", "js": "javascript",
            "jsx": "javascript", "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
            "java": "java", "kt": "kotlin", "cpp": "cpp", "c": "c", "h": "c", "hpp": "cpp",
            "cs": "csharp", "css": "css", "scss": "scss", "html": "xml", "xml": "xml",
            "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini", "sql": "sql",
            "sh": "bash", "bash": "bash", "zsh": "bash", "md": "markdown", "tf": "hcl",
            "graphql": "graphql", "gql": "graphql", "proto": "protobuf",
        ]
        return map[ext]
    }

    /// Highlight a multi-line code block. Returns one `NSAttributedString`
    /// per input line (split by '\n' from the highlighted block so multi-line
    /// constructs like strings and comments are colorized correctly).
    /// Returns plain monospace lines if the highlighter is unavailable, the
    /// language is unknown, or highlight.js fails on the snippet.
    static func highlightLines(_ code: String, language: String?) -> [NSAttributedString] {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let plainLines: () -> [NSAttributedString] = {
            code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                NSAttributedString(string: String(line), attributes: [
                    .font: monoFont,
                    .foregroundColor: NSColor.labelColor,
                ])
            }
        }

        guard let highlightr = shared, let language else { return plainLines() }
        guard let highlighted = highlightr.highlight(code, as: language) else {
            return plainLines()
        }

        // Override font and clamp pale colors against light backgrounds.
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: monoFont, range: fullRange)
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, attrRange, _ in
            if let color = value as? NSColor, colorIsTooPale(color) {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: attrRange)
            }
        }

        // Split by '\n' into per-line attributed substrings. The original
        // `code` and the highlighted string have identical character content,
        // so we can use the original string's '\n' offsets directly.
        let nsCode = mutable.string as NSString
        var result: [NSAttributedString] = []
        var lineStart = 0
        for i in 0..<nsCode.length {
            if nsCode.character(at: i) == 0x0A { // '\n'
                let range = NSRange(location: lineStart, length: i - lineStart)
                result.append(mutable.attributedSubstring(from: range))
                lineStart = i + 1
            }
        }
        // Trailing line (no terminating '\n' — matches `split(omittingEmptySubsequences: false)`).
        let tailRange = NSRange(location: lineStart, length: nsCode.length - lineStart)
        result.append(mutable.attributedSubstring(from: tailRange))
        return result
    }

    /// WCAG relative luminance — returns true for colors so pale they'd
    /// vanish against a light system background. Threshold matches gh-review.
    private static func colorIsTooPale(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6
    }
}

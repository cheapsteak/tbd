import Foundation
import AppKit
import Highlightr

/// Shared `Highlightr` instances themed to match the GitHub palette
/// elsewhere in the transcript view. Two cached instances (light + dark)
/// so we can pick at call time based on the current appearance without
/// rebuilding on every render.
enum DiffSyntaxHighlighter {

    /// Light-mode highlighter. `Highlightr` is not declared `Sendable`,
    /// but `highlight(_:as:)` is internally serialized (NSRegularExpression
    /// + a single JSCore VM). All current callers run on the main actor
    /// (SwiftUI view bodies). Keep call sites main-actor-only.
    nonisolated(unsafe) private static let lightShared: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "github")
        return h
    }()

    /// Dark-mode highlighter. Uses `github-dark` (Highlightr ships it as a
    /// theme; if missing, fall back to `atom-one-dark` at runtime).
    nonisolated(unsafe) private static let darkShared: Highlightr? = {
        let h = Highlightr()
        if h?.setTheme(to: "github-dark") != true {
            _ = h?.setTheme(to: "atom-one-dark")
        }
        return h
    }()

    /// Cache of highlight results keyed by (isDark, language, content).
    /// Reads from SwiftUI view bodies (main actor) only; the
    /// `nonisolated(unsafe)` pattern is consistent with the highlighter
    /// statics above and the cache mutations are likewise main-actor-only.
    nonisolated(unsafe) private static var resultCache: [String: [NSAttributedString]] = [:]
    private static let resultCacheCap = 500
    nonisolated(unsafe) private static var resultCacheOrder: [String] = []

    /// Map file extensions → highlight.js language identifiers. Ported
    /// verbatim from gh-review (cheapsteak/gh-review).
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
    /// per input line. Picks a theme based on the current appearance.
    /// Main-actor-only because it reads `NSApp.effectiveAppearance`; all
    /// current callers are SwiftUI view bodies.
    @MainActor
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

        let isDark = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]
        )?.rawValue.contains("Dark") == true

        // Cache key: appearance + language + content. Different appearance
        // means a different theme means different attributed colors.
        let cacheKey = "\(isDark ? "D" : "L")|\(language ?? "")|\(code)"
        if let cached = resultCache[cacheKey] {
            return cached
        }

        guard let highlightr = isDark ? darkShared : lightShared, let language else {
            return plainLines()
        }
        guard let highlighted = highlightr.highlight(code, as: language) else {
            return plainLines()
        }

        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: monoFont, range: fullRange)
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, attrRange, _ in
            if let color = value as? NSColor, colorIsHardToRead(color, onDarkBackground: isDark) {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: attrRange)
            }
        }

        let nsCode = mutable.string as NSString
        var result: [NSAttributedString] = []
        var lineStart = 0
        for i in 0..<nsCode.length {
            if nsCode.character(at: i) == 0x0A {
                let range = NSRange(location: lineStart, length: i - lineStart)
                result.append(mutable.attributedSubstring(from: range))
                lineStart = i + 1
            }
        }
        let tailRange = NSRange(location: lineStart, length: nsCode.length - lineStart)
        result.append(mutable.attributedSubstring(from: tailRange))

        // Touch / cap.
        if let existingIdx = resultCacheOrder.firstIndex(of: cacheKey) {
            resultCacheOrder.remove(at: existingIdx)
        }
        resultCacheOrder.append(cacheKey)
        resultCache[cacheKey] = result
        while resultCacheOrder.count > resultCacheCap {
            let evict = resultCacheOrder.removeFirst()
            resultCache.removeValue(forKey: evict)
        }
        return result
    }

    /// Symmetric WCAG luminance clamp. In light mode, replace overly-pale
    /// colors that vanish against white. In dark mode, replace overly-dark
    /// colors that vanish against black.
    private static func colorIsHardToRead(_ color: NSColor, onDarkBackground: Bool) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return onDarkBackground ? luminance < 0.15 : luminance > 0.6
    }
}

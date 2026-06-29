import AppKit
import Highlightr
import os

/// One foreground-color run produced by syntax highlighting. Ranges are LOCAL to
/// the code string the run was computed from (the caller offsets them into the
/// surrounding attributed string).
struct HighlightColorRun {
    let range: NSRange
    let color: NSColor
}

/// Off-main syntax highlighter for fenced code blocks. (#129 freeze fix.)
///
/// `Highlightr` wraps highlight.js inside a JavaScriptCore VM. Creating that VM —
/// and running highlight.js — is expensive, and under memory pressure the lazy
/// `JSVirtualMachine` init can stall the calling thread for tens of seconds. The
/// transcript open path used to do this synchronously on the MAIN thread (height
/// precompute + first paint), producing a hard force-quit-level freeze.
///
/// This service moves all JavaScriptCore work onto a DEDICATED serial queue and
/// NEVER touches `Highlightr`/`JSContext` from any other thread (JSContext is
/// thread-confined). Code blocks render as plain monospaced text synchronously;
/// the colors computed here are applied later, over the SAME fixed monospaced font,
/// so they change only `.foregroundColor` and never the layout/height.
final class CodeHighlightService {
    /// Process singleton. `nonisolated(unsafe)` because the type's only mutable
    /// state (the lazy `Highlightr`) is confined to `queue`, so access is
    /// serialized at runtime rather than checked by the compiler — the same pattern
    /// the sibling `DiffSyntaxHighlighter` uses for its shared `Highlightr`s.
    nonisolated(unsafe) static let shared = CodeHighlightService()

    /// Dedicated serial queue. The lazily-created `Highlightr` and EVERY call into
    /// it happen only here — JSContext is thread-confined, so confining all access
    /// to one serial queue is the thread-safety guarantee.
    private let queue = DispatchQueue(label: "com.tbd.code-highlight", qos: .userInitiated)
    private let log = Logger(subsystem: "com.tbd.app", category: "code-highlight")

    /// Skip highlighting inputs larger than this — highlight.js is pathologically
    /// slow on huge blobs (history transcripts contain big file/tool-output dumps).
    private let maxUTF16Count = 30_000
    private let maxLineCount = 2_000

    /// The single `Highlightr`, created lazily ON `queue` and only ever touched
    /// there. Plain stored properties guarded solely by `queue` serialization.
    private var highlightr: Highlightr?
    private var didCreateHighlightr = false

    private init() {}

    /// Lazily create the `Highlightr` (MUST run on `queue`).
    private func makeHighlightrIfNeeded() -> Highlightr? {
        if !didCreateHighlightr {
            didCreateHighlightr = true
            let h = Highlightr()
            h?.setTheme(to: "xcode")
            highlightr = h
        }
        return highlightr
    }

    /// Best-effort warm: create the `Highlightr` (and thus the JSCore VM) off-main,
    /// ahead of first use, so the first real highlight doesn't pay the VM-init cost.
    func warm() {
        queue.async { [self] in
            _ = makeHighlightrIfNeeded()
        }
    }

    /// Highlight `code` as `language` off the main thread and deliver the resulting
    /// foreground-color runs (local to `code`) back on the main thread.
    ///
    /// Skips (returns `[]`) for inputs over the size cap. If highlighting fails or
    /// produces nothing, also returns `[]`. The completion always runs on the main
    /// thread (it is `@MainActor`).
    func highlight(
        code: String,
        language: String,
        completion: @escaping @MainActor ([HighlightColorRun]) -> Void
    ) {
        let utf16Count = code.utf16.count
        if utf16Count > maxUTF16Count {
            log.debug(
                "code-highlight skip: utf16=\(utf16Count, privacy: .public) > cap=\(self.maxUTF16Count, privacy: .public) lang=\(language, privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
            return
        }
        // Cheap line-count guard (count newlines without splitting the whole string).
        let lineCount = code.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        if lineCount > maxLineCount {
            log.debug(
                "code-highlight skip: lines=\(lineCount, privacy: .public) > cap=\(self.maxLineCount, privacy: .public) lang=\(language, privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
            return
        }

        queue.async { [self] in
            guard let highlightr = makeHighlightrIfNeeded(),
                  let highlighted = highlightr.highlight(code, as: language) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
                return
            }
            let runs = Self.colorRuns(from: highlighted)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(runs) } }
        }
    }

    /// Enumerate `.foregroundColor` over `highlighted` and collect the non-nil
    /// color runs. Runs WITHOUT a foreground color (highlight.js's default text)
    /// are skipped — the plain render already carries the theme body color there.
    /// Ranges are local to the highlighted string (== the input `code`).
    ///
    /// Pure string/attribute work — no JSContext access — but it still runs on
    /// `queue` so we never read the `NSAttributedString` `highlight` returned from
    /// the main thread concurrently.
    private static func colorRuns(from highlighted: NSAttributedString) -> [HighlightColorRun] {
        var runs: [HighlightColorRun] = []
        let full = NSRange(location: 0, length: highlighted.length)
        highlighted.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            runs.append(HighlightColorRun(range: range, color: color))
        }
        return runs
    }
}

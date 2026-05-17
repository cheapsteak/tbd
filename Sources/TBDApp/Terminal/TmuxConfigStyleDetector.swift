import Foundation

/// Detects whether the user's tmux configuration sets one of the cell-painting
/// style options (`window-style`, `window-active-style`, `pane-style`,
/// `default-style`) that would override TBD's chosen color scheme.
///
/// Split out from `AppearanceSettings` so the pure regex logic is unit-testable
/// without touching the file system. The previous in-place implementation had
/// three regression-prone bugs across review rounds (bare `set`, `-gu` unset
/// form, unusual flag ordering); centralizing the pattern here lets us cover
/// each with a string-literal test in `TmuxConfigStyleDetectorTests`.
enum TmuxConfigStyleDetector {
    /// Anchored to line start. Between the command and the option name we
    /// allow ONLY whitespace and flag tokens (`-xyz`) — not arbitrary
    /// content. Otherwise an option name appearing inside a quoted value
    /// (e.g. `set -g status-left 'window-style is great'`) would match.
    ///
    /// We scan the matched substring for any `-…u…` flag rather than trying
    /// to capture the flag group with `*`, which only retains the last
    /// iteration and silently misses unset markers in unusual orderings like
    /// `set -u -g window-style`.
    private static let stylePattern = try? NSRegularExpression(
        pattern: #"(?m)^\s*(set|setw|set-option|set-window-option)(\s+-[a-zA-Z]+)*\s+(window-style|window-active-style|pane-style|default-style)\b"#
    )

    /// Matches an unset flag token (`-u`, `-gu`, `-ug`, etc) anywhere inside
    /// the line. Compiled once at file-scope to avoid recompiling per outer
    /// match in `declaresStyleOverride(in:)`.
    private static let unsetFlagPattern = try? NSRegularExpression(
        pattern: #"\s-[a-zA-Z]*u[a-zA-Z]*\b"#
    )

    /// Pure function: returns true if the given tmux config text appears to set
    /// any of the cell-painting style options (window-style, window-active-style,
    /// pane-style, default-style). Best-effort regex — does not resolve
    /// `source-file`, `if-shell`, or `%if`/`%endif` conditionals, and does not
    /// track last-write-wins across the file. We detect *presence* of override
    /// directives, not *effective* state. An override followed by an unset
    /// later in the file will still report true (acceptable false positive for
    /// an unusual case).
    static func declaresStyleOverride(in content: String) -> Bool {
        guard let stylePattern, let unsetFlagPattern else { return false }
        let nsContent = content as NSString
        var found = false
        stylePattern.enumerateMatches(in: content, range: NSRange(location: 0, length: nsContent.length)) { result, _, stop in
            guard let result else { return }
            let matchedRange = result.range
            // Skip unset directives. A flag token containing `u` (alone, like
            // `-u`, or grouped with other letters like `-gu` / `-ug`) means
            // unset — exactly what our own tooltip recommends as a fix.
            if unsetFlagPattern.firstMatch(in: content, range: matchedRange) != nil {
                return
            }
            found = true
            stop.pointee = true
        }
        return found
    }

    /// I/O wrapper: reads candidate tmux.conf paths and calls
    /// `declaresStyleOverride(in:)` on each. Honors `$XDG_CONFIG_HOME` if set,
    /// falling back to `~/.config` per the XDG Base Directory spec.
    static func detectFromUserConfig() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The XDG Base Directory spec says an empty `$XDG_CONFIG_HOME` should
        // be treated as unset, falling back to `~/.config`. `??` alone only
        // handles the absent-key case.
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        let candidatePaths = [
            "\(home)/.tmux.conf",
            "\(xdg)/tmux/tmux.conf",
        ]
        for path in candidatePaths {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if declaresStyleOverride(in: contents) {
                return true
            }
        }
        return false
    }
}

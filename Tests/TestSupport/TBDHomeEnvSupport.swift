import Foundation

/// Points the process-global `TBD_HOME` at `path` and returns the value that
/// was there before, for a paired `restoreTBDHome(_:)` in the test's `defer`.
///
/// **Restore, never `unsetenv`.** Unsetting does not go back to "whatever the
/// harness wanted" — it goes back to the developer's real `~/tbd`, for the
/// whole process, for every suite running concurrently. `scripts/test.sh`
/// fences the entire run behind a scratch `TBD_HOME`, so a teardown that
/// unsets punches a hole straight through that fence and hands every sibling
/// suite the real config dir until the next suite happens to set it again.
///
/// Only suites nested under `TBDHomeSerialized` (in `TBDDaemonTests`) may
/// mutate `TBD_HOME` at all — see the rule in `CLAUDE.md` and the doc comment
/// on that suite. Everywhere else, use an injection seam:
/// `TBDConstants.*(environment:)`, `ThemeStore(themesDirectory:)`,
/// `ClaudeProfileConfigDirManager(baseDirectory:hostBaseDirectory:)`.
@discardableResult
public func setTBDHome(_ path: String) -> String? {
    // `getenv`, not `ProcessInfo.processInfo.environment`: the pointer it
    // returns can be invalidated by the `setenv` below, so the copy has to
    // happen first — `String(cString:)` copies eagerly.
    let previous = getenv("TBD_HOME").map { String(cString: $0) }
    setenv("TBD_HOME", path, 1)
    return previous
}

/// Puts `TBD_HOME` back to the value `setTBDHome(_:)` returned. A `nil`
/// previous value means it genuinely was unset, and only then is `unsetenv`
/// the correct restore.
public func restoreTBDHome(_ previous: String?) {
    if let previous {
        setenv("TBD_HOME", previous, 1)
    } else {
        unsetenv("TBD_HOME")
    }
}

/// The same save/restore pair for `TBD_CLAUDE_HOST_HOME`, which fences
/// `~/.claude` exactly as `TBD_HOME` fences `~/tbd`: a default-constructed
/// `ClaudeProfileConfigDirManager` uses it as the host store it creates
/// directories in, moves whole subtrees within, and writes symlinks into.
///
/// `scripts/test.sh` exports it for the whole run, so the `unsetenv` trap is
/// identical — unsetting hands every concurrently running suite the
/// developer's real `~/.claude` until something happens to set it again. Pair
/// these two calls; never `unsetenv` in a teardown.
@discardableResult
public func setClaudeHostHome(_ path: String) -> String? {
    let previous = getenv("TBD_CLAUDE_HOST_HOME").map { String(cString: $0) }
    setenv("TBD_CLAUDE_HOST_HOME", path, 1)
    return previous
}

/// Puts `TBD_CLAUDE_HOST_HOME` back to the value `setClaudeHostHome(_:)`
/// returned. `nil` means it genuinely was unset, and only then is `unsetenv`
/// the correct restore.
public func restoreClaudeHostHome(_ previous: String?) {
    if let previous {
        setenv("TBD_CLAUDE_HOST_HOME", previous, 1)
    } else {
        unsetenv("TBD_CLAUDE_HOST_HOME")
    }
}

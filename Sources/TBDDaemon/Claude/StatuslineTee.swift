import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "statusline-tee")

/// The statusline tee: one shared shell script that publishes a session's
/// statusline stdin JSON where the daemon can read it, then runs whatever
/// statusline the operator configured.
///
/// **Why a tee at all.** A session's *effective* context window is a session
/// fact, not a model fact — Claude Code resolves it per session from the model
/// id, a long-context suffix, a beta header, environment overrides and a remote
/// flag. The one surface on which Claude Code tells a third party the value it
/// resolved is the statusline command's stdin JSON, whose `context_window`
/// object carries `context_window_size` alongside the used/remaining figures.
/// Reading it is the only honest way to get a denominator; every out-of-band
/// source reports *capability* instead, and capability errs in the dangerous
/// direction.
///
/// **Why desk sessions only.** The denominator exists to serve a desk's own
/// context-recycling thresholds, which are fractions of the session's effective
/// window. Fleet agents do not need it: auto-compaction bears their survival.
/// And TBD's per-session `--settings` file outranks the operator's own
/// `statusLine` in every file scope they can write — project-local, project,
/// and user — so installing the tee fleet-wide would silently take over a
/// display slot the operator owns in every session they open and type into. A
/// desk is a session TBD configures end to end, so the same mechanism there
/// costs nobody anything.
///
/// The consequence is carried honestly rather than papered over: for every
/// non-desk session the context-window denominator is unknown and is reported
/// as unknown — raw token counts with no percentage. See `ContextLoadReader`.
///
/// One script serves the whole fleet. It takes the capture path and the
/// operator's statusline command as arguments, so nothing session-specific is
/// baked into the file and there is no per-session script to prune.
enum StatuslineTee {
    /// Path of the shared script. Derived from `TBDConstants` so `TBD_HOME` is
    /// honored — never hand-built from `$HOME`.
    static var scriptPath: String { TBDConstants.statuslineTeeScriptPath }

    /// Where one session's captured payload lands.
    static func capturePath(sessionKey: String) -> String {
        TBDConstants.statuslineCapturePath(sessionKey: sessionKey)
    }

    /// The `statusLine.command` string TBD installs in a desk session's
    /// overlay: the tee script, its capture path, and the operator's own
    /// statusline command (empty when they have none).
    ///
    /// All three are shell-escaped. The delegate arrives as a single argument
    /// and is re-run by the script through `sh -c "$2"`, which is exactly how
    /// Claude Code would have run it.
    static func statusLineCommand(capturePath: String, delegateCommand: String?) -> String {
        let script = SystemPromptBuilder.shellEscape(scriptPath)
        let capture = SystemPromptBuilder.shellEscape(capturePath)
        let delegate = SystemPromptBuilder.shellEscape(delegateCommand ?? "")
        return "sh \(script) \(capture) \(delegate)"
    }

    /// Remove one session's capture file. Best-effort, like
    /// `ClaudeHookOverlay.removePerSessionOverlay`, which calls this.
    static func removeCapture(sessionKey: String) {
        try? FileManager.default.removeItem(atPath: capturePath(sessionKey: sessionKey))
    }

    /// Startup sweep: delete every `statusline-capture-*.json` whose sanitized
    /// session key is not in `liveSessionKeys`. Same reclaim contract as the
    /// per-session overlay prune it runs beside — captures orphaned by a crash
    /// or by a teardown path that never called `removeCapture` still go away,
    /// so cleanup cannot drift as new teardown paths are added.
    ///
    /// This is also the only collector of the script's publish temp, which is
    /// named `<capture>.<pid>.tmp.json` precisely so it matches the
    /// prefix-and-suffix test here. A tee killed between its `cat` and its
    /// `mv` — the session torn down, the machine asleep — leaves that file
    /// behind, and `removeCapture` deletes only the exact capture path. Its
    /// extracted "key" (`<key>.json.<pid>.tmp`) is never a live session key,
    /// since `sanitizedSessionKey` maps `.` away, so a stray temp is always
    /// collected and a live capture never is.
    static func pruneOrphanedCaptures(liveSessionKeys: [String]) {
        let fm = FileManager.default
        let dir = TBDConstants.runtimeDir
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let live = Set(liveSessionKeys.map { TBDConstants.sanitizedSessionKey($0) })
        let prefix = TBDConstants.statuslineCapturePrefix
        let suffix = TBDConstants.statuslineCaptureSuffix
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let key = String(entry.dropFirst(prefix.count).dropLast(suffix.count))
            if live.contains(key) { continue }
            try? fm.removeItem(atPath: dir.appendingPathComponent(entry).path)
            logger.info("Pruned orphaned statusline capture \(entry, privacy: .public)")
        }
    }

    /// Write the shared script to disk, executable (0o755), creating the
    /// runtime directory if needed. Called at daemon startup beside the hook
    /// overlay write; idempotent. Returns true on success.
    @discardableResult
    static func writeScript() -> Bool {
        let path = scriptPath
        do {
            try FileManager.default.createDirectory(
                at: TBDConstants.runtimeDir,
                withIntermediateDirectories: true
            )
            try Data(scriptBody.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            logger.info("Wrote statusline tee at \(path, privacy: .private)")
            return true
        } catch {
            // Both halves at the same privacy, deliberately: a Foundation file
            // error routinely embeds the very filename and containing folder
            // that `path` is marked `.private` for, so a `.public` error would
            // print in the clear exactly what the interpolation beside it
            // redacts.
            logger.error(
                "Failed to write statusline tee at \(path, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    /// The script. POSIX `sh`, no bashisms.
    ///
    /// Every branch is quiet and non-fatal, and that is load-bearing rather
    /// than tidy: Claude Code blanks the status line when the command exits
    /// non-zero or prints nothing, so a tee that failed loudly would take the
    /// operator's status line down with it.
    static let scriptBody: String = #"""
    #!/bin/sh
    # TBD statusline tee — generated by the daemon; edits are overwritten on restart.
    #
    # usage: statusline-tee.sh <capture-path> <delegate-command>
    #
    # Claude Code hands a statusline command the session's status JSON on stdin.
    # That JSON is the one surface on which Claude Code reports the context
    # window it RESOLVED for this session, so TBD publishes it verbatim and then
    # gets out of the way: the statusline the operator configured runs next, on
    # the same payload, with its stdout and its exit status passed through
    # untouched.
    #
    # Quiet in every branch, deliberately. A non-zero exit or empty stdout
    # blanks the status line, so:
    #   - with no delegate we exit 0 having printed nothing (there was no status
    #     line to blank, and inventing one would claim a slot we were not given);
    #   - with a delegate we propagate ITS status instead of swallowing it, so a
    #     broken operator statusline fails exactly the way it would have without
    #     us in the path;
    #   - a missing capture directory, an unwritable capture file, or no place
    #     to buffer at all changes neither of those. The tee observes; it is
    #     never a gate on the operator's statusline.
    #
    # The payload is data throughout. It moves only through file descriptors and
    # files — never into a shell word or a here-document, where a `$`, a
    # backtick or a quote in a repo path would be expanded.

    umask 077

    CAPTURE=$1
    DELEGATE=$2

    run_delegate() {
        # stdin is whatever the caller redirected. exec, so the delegate's exit
        # status is this script's with no extra shell left in the way.
        if [ -n "$DELEGATE" ]; then
            exec sh -c "$DELEGATE"
        fi
        exit 0
    }

    BUF=$(mktemp "${TMPDIR:-/tmp}/tbd-statusline-XXXXXX" 2>/dev/null) || BUF=
    if [ -z "$BUF" ]; then
        # Nowhere to buffer the payload. Capturing is the expendable half, so
        # hand our own untouched stdin to the delegate and capture nothing.
        run_delegate
    fi

    # Three descriptors on one inode: one to write the payload, two to read it
    # back, because each open carries its own offset and POSIX sh cannot seek.
    # Unlinking straight away means the buffer cannot outlive this process —
    # not even across the final exec, which replaces the shell and would skip
    # any EXIT trap. Reclaim is the unlink's job, never a trap's; the one trap
    # below is armed across two lines and does something else entirely.
    #
    # mktemp just created the file, so these opens should not fail — but "should
    # not" is not "cannot", and this is the one branch that could speak up. A
    # failed redirection on `exec` is reported by the shell itself and ends the
    # script, which blanks the operator's status line: exactly the outcome every
    # other branch here is written to avoid.
    #
    # An `if !` around it is NOT enough to make that claim true. `exec` is a
    # POSIX special built-in, and a redirection error on a special built-in is
    # fatal to a non-interactive shell no matter what encloses it — dash exits 2
    # on the spot, so neither the `if` nor the `2>/dev/null` ever runs. bash and
    # zsh outside POSIX mode are laxer and report it instead, so a guard tested
    # only under those two would read as handled while being nothing of the
    # kind; the header above promises POSIX sh, so the guard has to hold under
    # one.
    #
    # So the opens are PROBED first, in a subshell, where the same fatal error
    # costs only the subshell and the enclosing group silences its message.
    # Silenced and handled like the no-buffer case above, which it is — our own
    # stdin is still the untouched payload, so the delegate loses nothing.
    if ! ( exec 3>"$BUF" 4<"$BUF" 5<"$BUF" ) 2>/dev/null; then
        rm -f "$BUF" 2>/dev/null
        run_delegate
    fi

    # The probe NARROWS that window; it cannot close it. It proves the path was
    # openable a moment ago, and the buffer lives in $TMPDIR — a per-user
    # directory a cleaner or a sibling process can empty between the two opens.
    # When the real open fails there, the shell is already dying and no `if`,
    # `!` or `2>/dev/null` around it will ever run.
    #
    # An EXIT trap is the one handler that still gets control on that exit, so
    # the fallback is armed here and disarmed the moment the opens land. It sits
    # AFTER the probe rather than around it because the probe subshell exiting
    # must not fire it — verified alongside the fatal-exit behavior itself in
    # dash, macOS /bin/sh and zsh, all three of which run this trap on the
    # failed open and none of which runs it for the subshell above.
    trap 'rm -f "$BUF" 2>/dev/null; run_delegate' EXIT
    # The real opens, on a path the probe just proved openable. The `if` is the
    # arm for a lax shell (bash and zsh outside POSIX mode report the failure
    # instead of dying on it); the trap is the arm for a strict one.
    if ! { exec 3>"$BUF" 4<"$BUF" 5<"$BUF"; } 2>/dev/null; then
        trap - EXIT
        rm -f "$BUF" 2>/dev/null
        run_delegate
    fi
    trap - EXIT
    rm -f "$BUF" 2>/dev/null
    cat >&3 2>/dev/null
    exec 3>&-

    # Publish atomically: a reader must never see a half-written payload, so
    # write a sibling temp file and rename it over the capture path.
    #
    # The `.json` on the end is load-bearing, not decoration. This script can be
    # killed between the `cat` and the `mv` — the session torn down, the machine
    # asleep — and the temp then has no owner: nothing else knows its name, and
    # the daemon's per-session cleanup deletes only the exact capture path. The
    # daemon's startup sweep collects `statusline-capture-*.json`, so a temp
    # named for both ends of that test is reclaimed, while a sibling in the same
    # directory keeps the rename atomic. Widening the sweep instead would have
    # worked equally well for reclaim and told a reader less about why the name
    # has the shape it does.
    TMP="$CAPTURE.$$.tmp.json"
    mkdir -p "$(dirname "$CAPTURE")" 2>/dev/null
    # The braces matter: a failing `>"$TMP"` redirection is reported by the
    # shell itself, so the silencer has to wrap the whole compound command.
    if { cat <&4 >"$TMP"; } 2>/dev/null; then
        mv -f "$TMP" "$CAPTURE" 2>/dev/null || rm -f "$TMP" 2>/dev/null
    else
        rm -f "$TMP" 2>/dev/null
    fi
    exec 4<&-

    # Replay the buffered payload on the delegate's own stdin.
    exec 0<&5 5<&-
    run_delegate

    """#
}

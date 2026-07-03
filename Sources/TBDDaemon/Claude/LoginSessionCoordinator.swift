import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "loginSession")

/// Coordinates the daemon side of a profile *login session* (Settings →
/// "Open login session"): a Claude pane pinned to an OAuth profile where the
/// user completes `/login` into the profile's isolated `CLAUDE_CONFIG_DIR`.
///
/// Two responsibilities, both keyed off `handleTerminalCreate`'s
/// `loginSession` branch:
///
/// 1. **Auto-typing `/login`** — a terminal registers as "pending auto-login"
///    at spawn. The send fires from whichever trigger comes first:
///    - the Claude SessionStart hook event (`terminal.sessionEvent` RPC),
///      delayed by `delays.afterSessionStart` so Claude's TUI input loop is up;
///    - a spawn-time fallback after `delays.spawnFallback`, covering sessions
///      whose hook never fires (missing overlay, old Claude build).
///    `consumePendingAutoLogin` is consume-once, so double-sends are
///    structurally impossible no matter how the triggers race.
///
/// 2. **Login-completion watching** — `watchLoginIdentity` polls the
///    profile's isolated `.claude.json` for an `oauthAccount` and invokes
///    `onLogin` (the caller broadcasts `.modelProfilesChanged`) when it
///    appears, so the Settings badge flips to "Logged in as …" live.
///
///    Design choice — bounded polling over FSEvents/DispatchSource: Claude
///    writes `.claude.json` via atomic rename, which breaks per-file vnode
///    watchers (the watched inode is replaced); a correct watcher must
///    monitor the directory and re-arm, and a daemon-lifetime watcher per
///    profile is standing complexity for an event that happens at most once
///    per profile. A 2s poll scoped to an active login attempt (started on
///    login-session spawn, single-flighted per profile, capped at 30 min) is
///    simpler, self-terminating, and robust against atomic replaces. If the
///    user completes `/login` after the watcher expires, the badge catches up
///    on the next `modelProfile.list` (app relaunch or any profile mutation).
public actor LoginSessionCoordinator {
    /// Trigger timings. Injectable so handler-level tests can zero them out.
    public struct Delays: Sendable {
        /// Wait after the SessionStart hook event before typing `/login` —
        /// the hook fires early in Claude startup, slightly before the TUI
        /// input loop reliably consumes pty input.
        public var afterSessionStart: Duration
        /// Fallback wait after spawn for sessions whose SessionStart hook
        /// never reaches the daemon.
        public var spawnFallback: Duration
        /// Poll cadence for the login-identity watcher.
        public var identityPollInterval: Duration
        /// Watcher lifetime cap — after this, the badge catches up on the
        /// next `modelProfile.list` instead.
        public var identityPollTimeout: Duration
        public init(
            afterSessionStart: Duration = .milliseconds(1500),
            spawnFallback: Duration = .seconds(8),
            identityPollInterval: Duration = .seconds(2),
            identityPollTimeout: Duration = .seconds(1800)
        ) {
            self.afterSessionStart = afterSessionStart
            self.spawnFallback = spawnFallback
            self.identityPollInterval = identityPollInterval
            self.identityPollTimeout = identityPollTimeout
        }
    }

    public let delays: Delays
    private var pendingAutoLogin: Set<UUID> = []
    private var watchedProfiles: Set<UUID> = []

    public init(delays: Delays = Delays()) {
        self.delays = delays
    }

    // MARK: - Auto-login pending set

    /// Mark a freshly spawned login-session terminal as awaiting its one
    /// auto-typed `/login`.
    public func registerPendingAutoLogin(terminalID: UUID) {
        pendingAutoLogin.insert(terminalID)
    }

    /// Consume-once claim on the auto-login send. Returns true exactly once
    /// per registered terminal — the SessionStart trigger and the spawn
    /// fallback both call this, and only the winner sends.
    public func consumePendingAutoLogin(terminalID: UUID) -> Bool {
        pendingAutoLogin.remove(terminalID) != nil
    }

    /// Drop a pending auto-login without sending (terminal deleted).
    public func cancelPendingAutoLogin(terminalID: UUID) {
        pendingAutoLogin.remove(terminalID)
    }

    // MARK: - Login-identity watcher

    /// Poll `identity()` every `interval` until it returns non-nil (login
    /// completed → fire `onLogin` once and stop) or `timeout` elapses.
    /// Single-flighted per profile: while a watcher is active, further
    /// `watchLoginIdentity` calls for the same profile are no-ops, so five
    /// clicks on "Open login session" cost one poll loop.
    public func watchLoginIdentity(
        profileID: UUID,
        interval: Duration = .seconds(2),
        timeout: Duration = .seconds(1800),
        identity: @escaping @Sendable () -> String?,
        onLogin: @escaping @Sendable () -> Void
    ) {
        guard !watchedProfiles.contains(profileID) else { return }
        watchedProfiles.insert(profileID)
        Task {
            defer { unwatch(profileID: profileID) }
            var elapsed: Duration = .zero
            while elapsed < timeout {
                if let email = identity() {
                    logger.info("login detected for profile \(profileID, privacy: .public) (\(email, privacy: .private)); broadcasting profile refresh")
                    onLogin()
                    return
                }
                try? await Task.sleep(for: interval)
                elapsed += interval
            }
            logger.debug("login watcher for profile \(profileID, privacy: .public) timed out without a login")
        }
    }

    private func unwatch(profileID: UUID) {
        watchedProfiles.remove(profileID)
    }
}

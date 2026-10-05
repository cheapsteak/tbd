import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "loginSession")

/// Coordinates the daemon side of a profile *login session* (Settings →
/// "Open login session"): a Claude pane pinned to an OAuth profile where the
/// person completes `/login` into the profile's isolated `CLAUDE_CONFIG_DIR`.
///
/// The daemon never types into a login tab. Claude renders its own
/// "Not logged in · Run /login" footer hint on every transport, and the person
/// runs `/login` from there. Driving the TUI would mean judging its rendered
/// screen, which the "No TUI screen-scraping" rule forbids.
///
/// What the coordinator does is **login-completion watching**:
/// `watchLoginIdentity` polls the profile's isolated `.claude.json` for an
/// `oauthAccount` and invokes `onLogin` (the caller broadcasts
/// `.modelProfilesChanged`) when it appears, so the Settings badge flips to
/// "Logged in as …" live.
///
/// Design choice — bounded polling over FSEvents/DispatchSource: Claude writes
/// `.claude.json` via atomic rename, which breaks per-file vnode watchers (the
/// watched inode is replaced); a correct watcher must monitor the directory and
/// re-arm, and a daemon-lifetime watcher per profile is standing complexity for
/// an event that happens at most once per profile. A 2s poll scoped to an
/// active login attempt (started on login-session spawn, single-flighted per
/// profile, capped at 30 min) is simpler, self-terminating, and robust against
/// atomic replaces. If the person completes `/login` after the watcher expires,
/// the badge catches up on the next `modelProfile.list` (app relaunch or any
/// profile mutation).
public actor LoginSessionCoordinator {
    /// Watcher timings. Injectable so tests can shrink them.
    public struct Delays: Sendable {
        /// Poll cadence for the login-identity watcher.
        public var identityPollInterval: Duration
        /// Watcher lifetime cap — after this, the badge catches up on the
        /// next `modelProfile.list` instead.
        public var identityPollTimeout: Duration
        public init(
            identityPollInterval: Duration = .seconds(2),
            identityPollTimeout: Duration = .seconds(1800)
        ) {
            self.identityPollInterval = identityPollInterval
            self.identityPollTimeout = identityPollTimeout
        }
    }

    public let delays: Delays
    private var watchedProfiles: Set<UUID> = []
    /// The identity watcher's poll waits go through here, so a test drives the
    /// coordinator on virtual time instead of on the wall.
    private let clock: any Clock<Duration>

    public init(delays: Delays = Delays(), clock: any Clock<Duration> = ContinuousClock()) {
        self.delays = delays
        self.clock = clock
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
                try? await clock.sleep(for: interval)
                elapsed += interval
            }
            logger.debug("login watcher for profile \(profileID, privacy: .public) timed out without a login")
        }
    }

    private func unwatch(profileID: UUID) {
        watchedProfiles.remove(profileID)
    }
}

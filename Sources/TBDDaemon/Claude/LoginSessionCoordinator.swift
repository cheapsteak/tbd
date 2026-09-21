import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "loginSession")

/// Coordinates the daemon side of a profile *login session* (Settings →
/// "Open login session"): a Claude pane pinned to an OAuth profile where the
/// user completes `/login` into the profile's isolated `CLAUDE_CONFIG_DIR`.
///
/// Two responsibilities, both armed by `handleTerminalCreate`'s
/// `loginSession` branch:
///
/// 1. **Auto-typing `/login`** via a *verified pump* (`startAutoLoginPump`):
///    poll the session's screen until Claude's TUI is interactive, type
///    `/login` + Enter, then VERIFY the login dialog actually appeared before
///    declaring success — re-sending (capped) if the input was swallowed.
///    Fixed-delay sends were tried first and failed in practice: the
///    SessionStart hook fires before the TUI's input loop reliably consumes
///    pty input, and a send that lands in that window vanishes without a
///    trace.
///
///    **Both transports feed the same pump.** A tmux-backed login tab reads a
///    captured pane; a holder-backed one reads the daemon's own retained
///    emulator through the typed screen. The holder half is evidence only when
///    the daemon rendered it live AND its emulator watched the child from the
///    start, so with a viewer attached — or over a child the daemon
///    re-adopted — the pump has nothing it may judge and simply waits, bounded
///    by `pumpTimeout`, rather than typing blind at a screen that may be
///    showing a caret the session does not have. `paneReading(from:)` states
///    that policy; `classifyPane` remains the one classifier either transport's
///    text goes through.
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
    /// Pump/watcher timings. Injectable so tests can shrink them.
    public struct Delays: Sendable {
        /// Minimum wait after spawn before the pump first reads the pane.
        public var pumpInitialDelay: Duration
        /// Poll cadence while the pane is not ready / dialog not visible.
        public var pumpPollInterval: Duration
        /// Wait after typing `/login` before verifying the dialog appeared.
        public var pumpPostSendDelay: Duration
        /// Pump lifetime cap — after this the user types `/login` themselves
        /// (the pane footer already hints "Not logged in · Run /login").
        public var pumpTimeout: Duration
        /// Poll cadence for the login-identity watcher.
        public var identityPollInterval: Duration
        /// Watcher lifetime cap — after this, the badge catches up on the
        /// next `modelProfile.list` instead.
        public var identityPollTimeout: Duration
        public init(
            pumpInitialDelay: Duration = .seconds(2),
            pumpPollInterval: Duration = .seconds(1),
            pumpPostSendDelay: Duration = .seconds(2),
            pumpTimeout: Duration = .seconds(45),
            identityPollInterval: Duration = .seconds(2),
            identityPollTimeout: Duration = .seconds(1800)
        ) {
            self.pumpInitialDelay = pumpInitialDelay
            self.pumpPollInterval = pumpPollInterval
            self.pumpPostSendDelay = pumpPostSendDelay
            self.pumpTimeout = pumpTimeout
            self.identityPollInterval = identityPollInterval
            self.identityPollTimeout = identityPollTimeout
        }
    }

    public let delays: Delays
    private var pendingAutoLogin: Set<UUID> = []
    private var activePumps: Set<UUID> = []
    private var watchedProfiles: Set<UUID> = []
    /// Every wait this actor takes — the pump's initial settle, its poll
    /// cadence, its post-send verify pause, and the identity watcher's poll —
    /// goes through here, so a test drives the whole coordinator on virtual
    /// time instead of on the wall.
    private let clock: any Clock<Duration>

    public init(delays: Delays = Delays(), clock: any Clock<Duration> = ContinuousClock()) {
        self.delays = delays
        self.clock = clock
    }

    // MARK: - Pane classification

    /// What the login-session pane currently shows, derived from its text.
    public enum PaneLoginState: Sendable, Equatable {
        /// Claude still booting (or pane text unavailable) — don't type yet.
        case notReady
        /// The TUI is interactive (input prompt / logged-out footer hint
        /// visible) but no login dialog yet — safe to type `/login`.
        case promptReady
        /// The `/login` method picker is on screen — the send took; done.
        case loginDialogVisible
    }

    /// Pure classifier for pump decisions (unit-testable without tmux).
    public static func classifyPane(_ text: String) -> PaneLoginState {
        // The /login picker's distinctive copy.
        if text.contains("Select login method") { return .loginDialogVisible }
        // Interactive markers: the input caret and/or the logged-out footer
        // hint Claude renders once the TUI accepts input.
        if text.contains("Run /login") || text.contains("❯") { return .promptReady }
        return .notReady
    }

    /// What one read of the login pane produced.
    public enum PaneReading: Sendable, Equatable {
        /// Screen text rendered by a store that has watched this child paint —
        /// evidence `classifyPane` may judge.
        case text(String)
        /// A screen that is not evidence, with the reason for the log: nobody
        /// is reading the pty for the daemon, the daemon's emulator is frozen
        /// behind a viewer's attach, or it was built over an already-running
        /// child.
        case notEvidence(String)
    }

    /// The login pump's reading of a holder session's typed screen. Evidence
    /// only when the daemon rendered it live AND its emulator watched the child
    /// from the start — the same two facts the hibernation pending-input rail
    /// refuses on (`HibernationCoordinator.holderRefusal`), for the same
    /// reason: a frozen or half-painted grid can show a caret the session does
    /// not have.
    ///
    /// Restated here rather than borrowed. The rail's refusals name hibernation
    /// actions a person can take, and a pump that never blocks anything has
    /// nothing to offer them; what it needs is a line for the log saying why it
    /// is still waiting.
    public static func paneReading(from screen: TerminalScreen?) -> PaneReading {
        guard let screen else { return .notEvidence("no live holder reader") }
        switch screen.source {
        case .staleDaemon, .viewer:
            return .notEvidence(
                "a viewer holds the pty; the daemon's screen is frozen at its attach")
        case .daemon:
            guard screen.contentObserved else {
                return .notEvidence(
                    "the daemon's emulator was built over a running child and has not seen "
                        + "the whole screen")
            }
            // `output` is the screen's own joined lines — the type carries no
            // second copy of the text, and joining here would make one.
            return .text(screen.output)
        }
    }

    // MARK: - Auto-login pump

    /// Mark a freshly spawned login-session terminal as awaiting its
    /// auto-typed `/login`. The pump only runs for registered terminals.
    public func registerPendingAutoLogin(terminalID: UUID) {
        pendingAutoLogin.insert(terminalID)
    }

    /// Stop auto-login for a terminal (deleted / no longer relevant). An
    /// active pump observes this on its next iteration and exits.
    public func cancelPendingAutoLogin(terminalID: UUID) {
        pendingAutoLogin.remove(terminalID)
    }

    /// True while the terminal still awaits its auto-typed `/login`.
    public func isPendingAutoLogin(terminalID: UUID) -> Bool {
        pendingAutoLogin.contains(terminalID)
    }

    /// Run the verified auto-`/login` pump for a registered terminal.
    ///
    /// Loop (bounded by `delays.pumpTimeout`):
    ///  - reading `notEvidence` → wait `pumpPollInterval`, re-read;
    ///  - pane `notReady` → wait `pumpPollInterval`, re-read;
    ///  - pane `promptReady` → `typeLogin()` (at most `maxSends` times, so a
    ///    pathological pane can't get its input stuffed), wait
    ///    `pumpPostSendDelay`, re-read to VERIFY;
    ///  - pane `loginDialogVisible` → success, stop.
    ///
    /// `paneText` answers with a `PaneReading` rather than a bare string so the
    /// pump can tell "the screen says nothing yet" from "this screen is not
    /// something anyone may judge" — the holder transport's frozen and
    /// half-painted grids, which read as perfectly ordinary text.
    ///
    /// Single-flighted per terminal; exits early when the registration is
    /// cancelled (terminal deleted).
    public func startAutoLoginPump(
        terminalID: UUID,
        maxSends: Int = 3,
        paneText: @escaping @Sendable () async -> PaneReading,
        typeLogin: @escaping @Sendable () async -> Void
    ) {
        guard pendingAutoLogin.contains(terminalID) else { return }
        guard !activePumps.contains(terminalID) else { return }
        activePumps.insert(terminalID)
        Task {
            defer {
                activePumps.remove(terminalID)
                pendingAutoLogin.remove(terminalID)
            }
            try? await clock.sleep(for: delays.pumpInitialDelay)
            var elapsed: Duration = .zero
            var sends = 0
            while elapsed < delays.pumpTimeout {
                guard pendingAutoLogin.contains(terminalID) else { return }
                let state: PaneLoginState
                switch await paneText() {
                case .notEvidence(let reason):
                    logger.debug("auto-login: terminal \(terminalID, privacy: .public) screen is not evidence (\(reason, privacy: .public)); waiting")
                    state = .notReady
                case .text(let text):
                    state = Self.classifyPane(text)
                }
                switch state {
                case .loginDialogVisible:
                    logger.info("auto-login: login dialog visible in terminal \(terminalID, privacy: .public) after \(sends, privacy: .public) send(s)")
                    return
                case .promptReady where sends < maxSends:
                    sends += 1
                    logger.info("auto-login: typing /login into terminal \(terminalID, privacy: .public) (attempt \(sends, privacy: .public))")
                    await typeLogin()
                    try? await clock.sleep(for: delays.pumpPostSendDelay)
                    elapsed += delays.pumpPostSendDelay
                case .promptReady, .notReady:
                    try? await clock.sleep(for: delays.pumpPollInterval)
                    elapsed += delays.pumpPollInterval
                }
            }
            logger.debug("auto-login: pump for terminal \(terminalID, privacy: .public) timed out (sends=\(sends, privacy: .public))")
        }
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

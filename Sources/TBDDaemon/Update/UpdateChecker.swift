import Foundation
import os
import TBDShared

private let updateLogger = Logger(subsystem: "com.tbd.daemon", category: "update")

/// Periodically compares the running build against the head of `main` on the
/// remote, and — in `auto` mode only — launches `scripts/update.sh --auto`.
///
/// The whole actor is one fact and one act. The fact is `UpdateStatus`, held in
/// memory and republished on every `daemon.status`; nothing persists it,
/// because a restarted daemon genuinely has not checked yet and saying so is
/// more honest than replaying a stale observation. The act is a detached script
/// launch, gated on `update_mode == .auto` and on the commit being one this
/// process has not already attempted.
///
/// Every external effect is an injected closure, so the mode table, the
/// relation table and the launch decision are all testable without a network,
/// a git remote, or a subprocess.
public actor UpdateChecker {
    /// The ref that means "latest". TBD has no tags and no release workflow, so
    /// latest is the head of `main` on the upstream remote.
    public static let mainRef = "refs/heads/main"

    /// How often a running checker ticks, absent an override. One hour: the
    /// check is a single ref advertisement, and an operator who wants to know
    /// sooner has `tbd version --check`.
    public static let defaultInterval: Duration = .seconds(3600)

    /// Environment variable overriding the interval, in seconds. An operator
    /// knob rather than a setting, deliberately: it exists to make a soak
    /// observable in minutes instead of hours, and a value that only matters
    /// while someone is watching does not belong in the database.
    public static let intervalEnvKey = "TBD_UPDATE_CHECK_INTERVAL"

    /// Resolve the tick interval from an environment dictionary. A missing,
    /// empty, unparseable or non-positive value falls back to the default —
    /// a zero interval would spin.
    public static func interval(from environment: [String: String]) -> Duration {
        guard let raw = environment[intervalEnvKey]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, let seconds = Double(raw), seconds > 0
        else { return defaultInterval }
        return .seconds(seconds)
    }

    // MARK: - Injected collaborators

    /// Reads `update_mode` fresh. Called on every tick, so `tbd config set
    /// update-mode` takes effect without a daemon restart.
    public typealias ModeReader = @Sendable () async -> UpdateMode
    /// Worktree path to the URL its `upstream` (else `origin`) remote names.
    public typealias RemoteResolver = @Sendable (String) async -> String?
    /// `(remote URL, worktree)` to the commit `refs/heads/main` points at.
    public typealias RemoteHeadReader = @Sendable (String, String) async -> String?
    /// `(ours, latest, worktree)` to whether `latest` contains `ours`. Nil when
    /// the objects are not present locally and ancestry cannot be decided.
    public typealias AncestryProbe = @Sendable (String, String, String) async -> Bool?
    /// `(ours, latest, worktree)` to how many commits separate them, or nil.
    public typealias BehindCounter = @Sendable (String, String, String) async -> Int?
    /// Launches the update for a build rooted at the given worktree. Returns
    /// whether the child actually started.
    public typealias Launcher = @Sendable (String) async -> Bool

    private let ourCommit: String?
    private let sourceWorktree: String?
    private let readMode: ModeReader
    private let resolveRemote: RemoteResolver
    private let remoteHead: RemoteHeadReader
    private let isAncestor: AncestryProbe
    private let behindCount: BehindCounter
    private let launch: Launcher
    private let tickInterval: Duration
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date

    // MARK: - State

    private var status: UpdateStatus = .unobserved
    private var hasObserved = false
    /// Remote URL, resolved once and reused. Re-resolving per tick would spawn
    /// a git process an hour for an answer that changes when somebody edits
    /// `.git/config` — and a checker whose remote moved is one restart away
    /// from noticing.
    private var resolvedRemoteURL: String?
    /// Commits `auto` has already launched an update for. In memory only: a
    /// failed attempt must not be retried until `main` moves, and a daemon that
    /// restarted has a new build identity to compare anyway.
    private var attemptedCommits: Set<String> = []
    /// Whether the "no usable remote" complaint has been logged. Logged once,
    /// not once an hour.
    private var loggedUnusableRemote = false
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        ourCommit: String?,
        sourceWorktree: String?,
        readMode: @escaping ModeReader,
        resolveRemote: @escaping RemoteResolver,
        remoteHead: @escaping RemoteHeadReader,
        isAncestor: @escaping AncestryProbe,
        behindCount: @escaping BehindCounter,
        launch: @escaping Launcher,
        interval: Duration = UpdateChecker.defaultInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.ourCommit = ourCommit
        self.sourceWorktree = sourceWorktree
        self.readMode = readMode
        self.resolveRemote = resolveRemote
        self.remoteHead = remoteHead
        self.isAncestor = isAncestor
        self.behindCount = behindCount
        self.launch = launch
        self.tickInterval = interval
        self.now = now
        self.clock = clock
    }

    // MARK: - Public API

    /// The last observation, or nil when none has been made. Nil is what
    /// `daemon.status` carries for a daemon in `off` mode or one that has not
    /// finished its first tick.
    public func currentStatus() -> UpdateStatus? {
        hasObserved ? status : nil
    }

    /// Run one check now and answer with the result, whatever `update_mode`
    /// says. The explicit-gesture path: `tbd version --check` and the app's
    /// "Check for Updates…". Launching still obeys the mode — asking what the
    /// remote is at is not asking for an install.
    public func checkNow() async -> UpdateStatus {
        let mode = await readMode()
        await performCheck(mayLaunch: mode.launchesUpdates)
        return status
    }

    /// One tick of the timer. Reads the mode fresh, so a mode change is honored
    /// here rather than at the next daemon start.
    public func runOnce() async {
        let mode = await readMode()
        guard mode.runsChecks else { return }
        await performCheck(mayLaunch: mode.launchesUpdates)
    }

    /// Start the periodic loop. Idempotent — a second call while running is a
    /// no-op rather than a second loop.
    ///
    /// The loop ticks immediately and then every `interval`. An immediate tick
    /// costs one ref advertisement and means `tbd version` has something to say
    /// right after a restart instead of an hour later. In `auto` that also
    /// means a daemon which boots behind starts an update at once, which is the
    /// point of the mode; the script's own lock file is what keeps a restart
    /// loop from stacking two of them.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the loop. Idempotent. Does not cancel an update already launched —
    /// that child is detached by design and outlives this daemon.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Internals

    private func runLoop() async {
        if !Task.isCancelled {
            await runOnce()
        }
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: tickInterval)
            } catch {
                // Any throw from the clock ends the loop; for the clocks in use
                // (ContinuousClock, TestClock) the only throw is cancellation.
                return
            }
            // A sleep that resumed just before cancellation landed must not
            // fall through into a tick.
            if Task.isCancelled { return }
            await runOnce()
        }
    }

    /// Observe the remote, recompute the relation, and — when permitted —
    /// launch the update once for a commit not yet attempted.
    private func performCheck(mayLaunch: Bool) async {
        guard let worktree = sourceWorktree, !worktree.isEmpty else {
            logUnusableRemoteOnce("this build names no source worktree")
            return
        }
        let url: String
        if let cached = resolvedRemoteURL {
            url = cached
        } else if let resolved = await resolveRemote(worktree) {
            resolvedRemoteURL = resolved
            url = resolved
        } else {
            logUnusableRemoteOnce("no upstream or origin remote in \(worktree)")
            return
        }

        guard let latest = await remoteHead(url, worktree) else {
            // A remote that did not answer is a transient fact about the
            // network, not a new fact about this build: keep the last
            // observation rather than replacing it with `unknown`.
            updateLogger.debug(
                "update: ls-remote gave no head for \(Self.mainRef, privacy: .public) at \(url, privacy: .public)")
            return
        }

        let ancestry: Bool?
        if let ours = ourCommit, ours != latest {
            ancestry = await isAncestor(ours, latest, worktree)
        } else {
            ancestry = nil
        }
        let relation = UpdateRelation.compute(
            ours: ourCommit, latest: latest, oursIsAncestorOfLatest: ancestry)
        var count: Int?
        if relation == .behind, let ours = ourCommit {
            count = await behindCount(ours, latest, worktree)
        }
        status = UpdateStatus(
            latestCommit: latest,
            observedAt: now(),
            relation: relation,
            behindBy: count,
            remote: url)
        hasObserved = true

        guard mayLaunch, relation == .behind else { return }
        guard !attemptedCommits.contains(latest) else { return }
        // Recorded BEFORE the launch, so a launch that fails is not retried
        // until `main` moves. A manual `tbd update` is unaffected — it never
        // consults this set.
        attemptedCommits.insert(latest)
        let started = await launch(worktree)
        if started {
            updateLogger.notice(
                "update: auto mode launched an update to \(latest, privacy: .public)")
        } else {
            updateLogger.error(
                "update: auto mode could not launch an update to \(latest, privacy: .public); not retrying until main moves")
        }
    }

    private func logUnusableRemoteOnce(_ reason: String) {
        guard !loggedUnusableRemote else { return }
        loggedUnusableRemote = true
        updateLogger.error(
            "update: cannot check for updates — \(reason, privacy: .public). The checker will idle until the daemon restarts.")
    }
}

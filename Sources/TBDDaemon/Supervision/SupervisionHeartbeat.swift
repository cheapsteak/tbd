import Foundation
import os
import TBDShared

private let heartbeatLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.heartbeat")

/// The out-of-band heartbeat (design §14, requirement P3-1): a small
/// `status.json` under `~/tbd/supervision/`, rewritten atomically with the
/// brake, each project's mark and active mode, and each project's last sweep
/// contact.
///
/// **The file is published at every brake edge; the periodic timer runs only
/// while the brake is released.** So the fleet brake is the one switch that
/// starts and stops this, and a braked daemon runs no background loop at all —
/// no second flag hides behind the brake, and nothing here acts before an
/// operator has released it.
///
/// That costs the watchdog nothing, which is the part worth spelling out. Its
/// rule is *if any project claims to be **effectively on** and this file has
/// not changed in about ten minutes, raise a notification*, and effectively on
/// means a standing mark **and** a released brake. A file that says `engaged`
/// therefore claims nothing is effectively on, and cannot trip the rule however
/// stale it grows — the freshness requirement only bites while the brake is
/// released, which is exactly when the timer runs. Publishing at the edges is
/// what keeps that true across the transition itself: the moment the brake
/// moves, the file says so, before the timer starts or stops.
///
/// The watchdog reads a file rather than the socket or the DB, so a dead daemon
/// cannot make it unavailable. That is also why the writer is deliberately dumb:
/// it composes nothing and judges nothing, it asks for a snapshot and writes it.
///
/// Known and accepted: while the brake is engaged, marks and modes an operator
/// changes are not reflected here until the next edge, because nothing is
/// ticking. The file's consumer is the watchdog, which is indifferent to both
/// while braked; `tbd supervise status` is the live surface for a human.
public actor SupervisionHeartbeat {
    /// How often the file is rewritten.
    ///
    /// One minute, against a watchdog rule of about ten. The cadence has to sit
    /// far enough below the alarm that ordinary jitter cannot trip it — a
    /// scheduler delay, a slow repo read, a machine that napped — and a factor
    /// of ten means ten consecutive ticks would have to be lost before a
    /// healthy daemon looked dead. It also bounds how stale an operator's or a
    /// watchdog's picture of the fleet can be at one minute, which is the same
    /// order as the human gestures it reports. The cost is one small atomic
    /// rewrite a minute, well under the daemon's existing ten-second git poll.
    public static let defaultInterval: Duration = .seconds(60)

    private let path: String
    private let snapshot: @Sendable () async throws -> SupervisionStatusFile
    private let interval: Duration
    private let clock: any Clock<Duration>

    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - path: where the heartbeat is written. Injected rather than resolved
    ///     from `TBDConstants` inside, so a test cannot be made to write into
    ///     the developer's real `~/tbd`.
    ///   - snapshot: the facts to publish. A throw skips this tick's write
    ///     rather than publishing a half-truth — an empty project list would be
    ///     a claim, not an absence — and **the thrown error is logged**, so the
    ///     file going stale is never the only trace of what went wrong. The
    ///     residual throwing case is a `supervision.json` an operator edited
    ///     into a state that cannot be resolved at all, where the daemon
    ///     genuinely cannot state coverage; staleness is then the honest signal,
    ///     and the log says which file and why.
    ///
    ///     **Throwing is the only way to say "no snapshot", deliberately.** An
    ///     `Optional` return would add a second, reasonless way to say the same
    ///     thing, and every caller would then have to handle two flavours of one
    ///     outcome with the compiler no longer able to tell them apart. There is
    ///     no legitimately-absent case to model: a fleet with no projects
    ///     publishes an empty list, which is a true statement about an empty
    ///     fleet, so the only reason a snapshot does not exist is that composing
    ///     it failed — and a failure that cannot say why is the thing finding 3
    ///     of the review was about.
    ///   - clock: the delay seam. `Duration` is behavior; the timestamps in the
    ///     file are data and come from the snapshot's own date seam.
    public init(
        path: String,
        snapshot: @Sendable @escaping () async throws -> SupervisionStatusFile,
        interval: Duration = SupervisionHeartbeat.defaultInterval,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.path = path
        self.snapshot = snapshot
        self.interval = interval
        self.clock = clock
    }

    /// Publish the file now, and match the timer to the brake.
    ///
    /// The single entry point, used both at boot and on every brake gesture, so
    /// there is no way to arm the timer without also publishing the edge that
    /// justifies it. Idempotent in both directions: calling it twice with the
    /// same value republishes and leaves the timer as it was.
    ///
    /// The edge write happens **first and unconditionally**, including when the
    /// brake is engaging. That write is what makes gating the timer safe: it
    /// leaves behind a file that says `engaged`, which the watchdog reads as
    /// "nothing is effectively on" and therefore never alarms about, no matter
    /// how long it then sits untouched.
    /// Two overlapping edges must not leave the timer disagreeing with the
    /// brake. The edge write is an `await`, so an actor releases itself across
    /// it and a second edge can run entirely inside the first's suspension —
    /// after which the first would resume and arm a timer the second had just
    /// disarmed. Recording the intent before the write and reconciling against
    /// the **latest** intent afterwards means whichever edge landed last is the
    /// one the timer ends up matching, whichever order they resume in.
    private var brakeReleased = false

    public func applyBrake(released: Bool) async {
        brakeReleased = released
        await tick()
        if brakeReleased {
            startTimer()
        } else {
            await cancelTimer()
        }
    }

    /// Whether the periodic timer is currently armed.
    ///
    /// Internal, and a deliberate test seam rather than an accident of access
    /// control: the timer's *presence* can be observed by waiting on the clock,
    /// but its **absence** cannot — a clock advance with no sleeper registered
    /// simply moves time, so "no tick arrived" is equally consistent with a
    /// disarmed timer and with one that had not yet reached its sleep. Every
    /// assertion here that matters is an absence, so it needs to be read rather
    /// than waited for.
    var isTimerArmed: Bool { loop != nil }

    private func startTimer() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    private func cancelTimer() async {
        guard let loop else { return }
        loop.cancel()
        self.loop = nil
        await loop.value
    }

    /// Stop ticking, and return only once the loop has actually finished. The
    /// file is left exactly as the last tick wrote it — a stopped heartbeat
    /// says nothing, and its staleness is the fact the watchdog reads.
    ///
    /// Awaiting the task rather than firing `cancel()` and walking away is what
    /// makes "stopped" an observable state instead of a request: a shutdown
    /// that returned with a tick still in flight could leave a write racing the
    /// process teardown. Awaiting from inside the actor is safe — this
    /// suspension releases the actor, which is exactly what the loop needs to
    /// unwind.
    public func stop() async {
        await cancelTimer()
    }

    private func run() async {
        // No opening tick: `applyBrake` published the edge that armed this loop,
        // so a tick here would rewrite the same facts a moment later.
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                // The only throw from the clocks in use is cancellation.
                return
            }
            if Task.isCancelled { return }
            await tick()
        }
    }

    /// Compose and publish one heartbeat. Internal so tests can drive a single
    /// write without arming the loop.
    func tick() async {
        let file: SupervisionStatusFile
        do {
            file = try await snapshot()
        } catch {
            let reason = String(describing: error)
            heartbeatLogger.error(
                """
                Skipped a supervision heartbeat: \(reason, privacy: .public). \
                \(self.path, privacy: .public) keeps its previous contents and will read \
                as stale, so a watchdog may report this daemon as down.
                """)
            return
        }
        do {
            try write(file)
        } catch {
            heartbeatLogger.error(
                """
                Could not write the supervision heartbeat to \(self.path, privacy: .public): \
                \((error as NSError).localizedDescription, privacy: .public)
                """)
        }
    }

    /// Atomically: a fresh temp in the **same directory**, then `rename(2)`.
    /// The reader is an outside process on its own schedule, so it must never
    /// be able to see a half-written file — and a temp elsewhere could land on
    /// another volume, where the rename degrades into a tearable copy.
    private func write(_ file: SupervisionStatusFile) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }
}

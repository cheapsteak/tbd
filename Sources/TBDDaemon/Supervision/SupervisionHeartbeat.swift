import Foundation
import os
import TBDShared

private let heartbeatLogger = Logger(subsystem: "com.tbd.daemon", category: "supervision.heartbeat")

/// The out-of-band heartbeat (design §14, requirement P3-1): a small
/// `status.json` under `~/tbd/supervision/`, rewritten atomically on a fixed
/// cadence with the brake, each project's mark and active mode, and each
/// project's last sweep contact.
///
/// **It writes regardless of the brake.** Observability is never withheld, and
/// the watchdog's rule — *if any project claims to be effectively on and this
/// file has not changed in about ten minutes, raise a notification* — needs the
/// file fresh enough to read `engaged`. A heartbeat that fell silent under the
/// brake would make a paused fleet indistinguishable from a dead daemon, which
/// is the one distinction this file exists to draw.
///
/// The watchdog reads a file rather than the socket or the DB, so a dead daemon
/// cannot make it unavailable. That is also why the writer is deliberately dumb:
/// it composes nothing and judges nothing, it asks for a snapshot and writes it.
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
    private let snapshot: @Sendable () async -> SupervisionStatusFile?
    private let interval: Duration
    private let clock: any Clock<Duration>

    private var loop: Task<Void, Never>?

    /// - Parameters:
    ///   - path: where the heartbeat is written. Injected rather than resolved
    ///     from `TBDConstants` inside, so a test cannot be made to write into
    ///     the developer's real `~/tbd`.
    ///   - snapshot: the facts to publish, or nil when they could not be read
    ///     this tick — a malformed `supervision.json`, say. A nil skips the
    ///     write rather than publishing a half-truth, and the file's mtime
    ///     going stale is precisely the signal the watchdog is built to notice.
    ///   - clock: the delay seam. `Duration` is behavior; the timestamps in the
    ///     file are data and come from the snapshot's own date seam.
    public init(
        path: String,
        snapshot: @Sendable @escaping () async -> SupervisionStatusFile?,
        interval: Duration = SupervisionHeartbeat.defaultInterval,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.path = path
        self.snapshot = snapshot
        self.interval = interval
        self.clock = clock
    }

    /// Start ticking. Idempotent: a second call while running does nothing.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.run()
        }
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
        guard let loop else { return }
        loop.cancel()
        self.loop = nil
        await loop.value
    }

    private func run() async {
        // Write once immediately: a daemon that just started should publish
        // fresh facts rather than leave a whole interval in which the file
        // still describes the previous run.
        if !Task.isCancelled { await tick() }
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
        guard let file = await snapshot() else {
            heartbeatLogger.warning(
                """
                Skipped a supervision heartbeat: the current state could not be read. \
                \(self.path, privacy: .public) keeps its previous contents and will read \
                as stale.
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

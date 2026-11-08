import Foundation
import os
import TBDShared

/// Keeps one remote session's transcript cache fresh while a phone has the
/// transcript open, as an open laptop pane's `RemoteTranscriptSyncDriver`
/// does: the bridge counts as a viewer (spec section 6, "Remote-provider
/// sessions").
///
/// - **`sync()`** runs `remote.transcriptSync` once and returns where the
///   cache is and what it holds. The path in the result is the only path the
///   feed reads; it never comes from the phone.
/// - **`loadEarlier()`** runs `remote.transcriptLoadEarlier` once, which
///   prepends a page of earlier history to the cache.
/// - **`ticks()`** syncs once per `interval` on the injected clock, for as
///   long as its stream is consumed. A sync that reports `caughtUp == false`
///   is followed by the next one at once, so a long first load lands page by
///   page. A failed sync always waits the interval, so a refusing daemon is
///   not hammered, and sends nothing: the phone keeps what it has, and the
///   next sync that succeeds brings it up to date. Ending the stream's
///   consumer, or cancelling its task, ends the syncing.
///
/// Both calls go through `PhoneSessionActions`. The daemon orders a session's
/// syncs and loads, so a load that runs while a tick's sync is in flight is
/// safe.
actor RemoteTranscriptFollower {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

    let provider: String
    let sessionID: String
    private let actions: any PhoneSessionActions
    private let interval: Duration
    private let clock: any Clock<Duration>
    /// Whether the last sync caught up. A tick after one that did not runs
    /// at once.
    private var caughtUp = true
    /// Whether the last tick's sync failed, so a run of failures logs once.
    private var failing = false

    init(provider: String, sessionID: String, actions: any PhoneSessionActions,
         interval: Duration = PhoneAppConstants.remoteSyncInterval, clock: any Clock<Duration> = ContinuousClock()) {
        self.provider = provider
        self.sessionID = sessionID
        self.actions = actions
        self.interval = interval
        self.clock = clock
    }

    /// One `remote.transcriptSync`. A refusal is `refused`, only in words TBD
    /// wrote (`PhoneAppService.tbdRemoteTranscriptRefusals`): a failed read's
    /// error is the provider's, which can quote a secret, so the phone gets
    /// `remoteRefusedReason` for it. A result that does not decode is
    /// `internal`.
    func sync() async throws -> RemoteTranscriptSyncResult {
        try Task.checkCancellation()
        let response = try await actions.phoneRemoteTranscriptSync(
            RemoteTranscriptSyncParams(provider: provider, sessionID: sessionID))
        let result = try PhoneAppService.remoteSucceeded(
            RemoteTranscriptSyncResult.self, from: response, method: "remote.transcriptSync",
            tbdRefusals: PhoneAppService.tbdRemoteTranscriptRefusals)
        caughtUp = result.caughtUp
        return result
    }

    /// One `remote.transcriptLoadEarlier`. A refusal is `refused`, only in
    /// words TBD wrote, as `sync()` reads it. A result that does not decode is
    /// `internal`.
    func loadEarlier() async throws -> RemoteTranscriptLoadEarlierResult {
        try Task.checkCancellation()
        let response = try await actions.phoneRemoteTranscriptLoadEarlier(
            RemoteTranscriptLoadEarlierParams(provider: provider, sessionID: sessionID))
        return try PhoneAppService.remoteSucceeded(
            RemoteTranscriptLoadEarlierResult.self, from: response, method: "remote.transcriptLoadEarlier",
            tbdRefusals: PhoneAppService.tbdRemoteTranscriptRefusals)
    }

    /// One sync per `interval`, each result as it lands, until the stream's
    /// consumer goes away or its task is cancelled. Only the newest result
    /// waits for a consumer that falls behind; the feed compares each with
    /// what it holds, so a skipped one loses nothing.
    func ticks() -> AsyncStream<RemoteTranscriptSyncResult> {
        let (stream, continuation) = AsyncStream<RemoteTranscriptSyncResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            await self.run(continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    private func run(_ continuation: AsyncStream<RemoteTranscriptSyncResult>.Continuation) async {
        while !Task.isCancelled {
            if caughtUp {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
            }
            do {
                let result = try await sync()
                if failing {
                    failing = false
                    Self.logger.notice("Phone transcript: a remote sync succeeded again")
                }
                continuation.yield(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A failed sync waits out the interval before the next.
                caughtUp = true
                if !failing {
                    failing = true
                    Self.logger.error(
                        "Phone transcript: a remote sync failed: \(PhoneAppService.errorType(error), privacy: .public): \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}

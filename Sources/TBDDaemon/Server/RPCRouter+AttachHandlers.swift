import Darwin
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

extension RPCRouter {
    /// Handle `attach.request`: gate → resolve worktree → allocate pipe →
    /// vend fd → schedule the ready-timeout cancel → return status.
    ///
    /// Ordering is the spec's non-negotiable attach handshake: the fd must
    /// reach the app before any bytes are written, and writes stay gated
    /// until the app's `attach.ready` ack — otherwise the first burst can
    /// land in a pipe nobody reads.
    func handleAttachRequest(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachRequestParams.self, from: paramsData)
        // Gate evaluated per attach (env || persisted flag): a Settings
        // toggle affects the next attach without a daemon restart.
        guard let bridge = controlMode, await bridge.gateEnabled() else {
            return try RPCResponse(result: AttachRequestResult(status: "unavailable"))
        }
        guard let worktree = try? await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }
        let server = worktree.tmuxServer
        let paneID = params.paneID
        do {
            // An attach means a pane on this server is about to render via
            // control mode — make sure the `tmux -CC` connection (the event
            // producer feeding the fanout) exists. `enableIfGated` only fires
            // on worktree/terminal CREATION paths, so panes that already
            // existed before the daemon started would otherwise get a sink
            // with no producer: a permanently blank pane. Idempotent.
            await bridge.supervisor.ensureConnection(serverName: server)
            // Establish this WINDOW as daemon-sized before the pane renders:
            // `window-size manual` hands sizing authority to our `resize-window`
            // commands (addendum §4). Set per-window, NEVER server-wide — the
            // same server hosts grouped-session viewers for other windows.
            // `params.windowID` (#317 put it on the wire) becomes load-bearing
            // here. A failed option set degrades to Phase-2 behavior and never
            // blocks the attach, so it's tolerated + logged-and-continued.
            // Deferred (addendum §4 open question): whether detach restores
            // `window-size latest` so a grouped viewer regains sizing control —
            // decide when the fallback interplay (§5) is testable; not done here.
            //
            // Fire-and-forget via `sendList`, NOT the awaited `send`: `send`
            // suspends until a REPLY block arrives (or the connection closes), so
            // a tmux that accepts the connection but stops replying (wedged-but-
            // alive stream) would hang the whole attach RPC forever — fd never
            // vends, the app's openAttach never returns, no fallback. `sendList`
            // returns after the STREAM WRITE and never waits for the reply, so the
            // attach handshake stays hang-proof against a mute-but-alive tmux.
            // Enqueue order through the client actor still guarantees this command
            // precedes any later `resize-window` from `pane.resize`.
            if let client = await bridge.supervisor.command(server: server) {
                let windowID = params.windowID
                await client.sendList([
                    TmuxCommand(
                        text: "set-window-option -t \(windowID) window-size manual",
                        tolerateErrors: true
                    ) { [logger] result in
                        // A failed option set is tolerated: degrade to Phase-2
                        // sizing, never block the attach.
                        if case .failure(let error) = result {
                            logger.debug("""
                                window-size manual set failed for \(server, privacy: .public)/\
                                \(windowID, privacy: .public) (window race): \
                                \(String(describing: error), privacy: .public)
                                """)
                        }
                    }
                ])
            }
            // Encode the vend header BEFORE the attach: it needs only `params`,
            // and hoisting it out keeps every throw AFTER `attach` succeeds
            // inside the inner do/catch that owns the undo (close readFD,
            // unregister, detach). Encoding here previously sat between the
            // attach and that do/catch, so an encode throw leaked the fd, the
            // orphan pipe, and the input-router registration.
            let header = try JSONEncoder().encode(
                FDVendHeader(worktreeID: params.worktreeID, paneID: paneID, attachID: params.attachID))
            let (readFD, generation) = try await bridge.supervisor.attach(server: server, paneID: paneID)
            // Route this pane's future input frames to `server`. Registered now
            // (before the vend) so the vend-failure path can undo it alongside
            // the fanout detach. The ready-timeout expiry deliberately does NOT
            // unregister — it has no hook here, and it's harmless: input to a
            // timed-out pane still resolves to the live tmux pane, and a
            // re-attach overwrites this entry. The attach generation rides the
            // route (R6-M7) so input-health deltas are stamped with it — a
            // stale attach's failure cannot flag a fresh attach app-side.
            bridge.inputRouter.register(
                worktreeID: params.worktreeID, paneID: paneID, server: server,
                generation: generation)
            do {
                try await bridge.fdVending.send(fd: readFD, header: header)
            } catch {
                // Vend failed — undo the attach so no orphan pipe lingers.
                // Generation-checked: if a concurrent re-attach already
                // replaced this sink, the undo must not EOF the successor's
                // pipe — and must leave its input route (same key, same
                // values) in place, so the unregister is scoped to a
                // successful detach.
                Darwin.close(readFD)
                if await bridge.supervisor.detachIfGeneration(
                    server: server, paneID: paneID, generation: generation) {
                    bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: paneID)
                }
                throw error
            }
            // The kernel duplicated the fd into the app's table; drop ours.
            Darwin.close(readFD)

            // Spec (pane lifecycle): "App fails to send attach.ready within
            // timeout (e.g. 5 s) → daemon cancels attach" — otherwise an app
            // that died mid-attach leaks the pipe and a permanently-gated sink.
            // Generation-scoped so a timer outliving a superseded attach can't
            // kill the fresh attach that replaced it.
            let timeout = bridge.readyTimeout
            Task { [supervisor = bridge.supervisor] in
                try? await Task.sleep(for: timeout)
                await supervisor.detachIfNotReady(server: server, paneID: paneID, generation: generation)
            }
            // The generation rides the result so the app can echo it back in
            // `pane.detach` — a closing view's detach can race a new view's
            // attach for the same pane, and only a generation-checked detach
            // keeps the stale one from killing the fresh sink.
            return try RPCResponse(result: AttachRequestResult(status: "pending", generation: generation))
        } catch {
            logger.error("""
                attach.request failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(error: "attach failed: \(error.localizedDescription)")
        }
    }

    /// Handle `attach.ready`: the app's reader is draining the vended fd —
    /// run the replay sequence (M4.3, addendum §3): pause → capture → replay
    /// → gate → unpause. The write gate opens only AFTER the replay bytes are
    /// in the pipe, so live output lands strictly behind the replay.
    ///
    /// Error surface:
    /// - `.superseded` (a newer attach owns the pane) is a benign race — RPC
    ///   SUCCESS; the stale viewer is gone, no fallback wanted.
    /// - Everything else (no sink, no command client, capture `%error`,
    ///   malformed capture, replay write failure/deadline) is an attach
    ///   failure: detach + unregister the input route and return an RPC
    ///   ERROR, which the app's catch in `startControlModeClient` turns into
    ///   the grouped-sessions fallback. The cleanup is GENERATION-CHECKED: a
    ///   stale sequence's failure can surface after a re-attach for the same
    ///   pane has already completed, and an unconditional detach here would
    ///   EOF the healthy successor's pipe (and drop its input route).
    func handleAttachReady(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachReadyParams.self, from: paramsData)
        guard let bridge = controlMode else {
            return RPCResponse(error: "control mode not configured")
        }
        guard let worktree = try? await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }
        let server = worktree.tmuxServer
        let paneID = params.paneID
        let orchestrator = AttachReplayOrchestrator(
            supervisor: bridge.supervisor, commandProvider: bridge.commandProvider)
        do {
            // Both outcomes are RPC success: `.ready` is the happy path;
            // `.superseded` means a newer attach owns the pane and runs its
            // own sequence — the stale caller just goes away quietly. The
            // echoed generation (when the app sent one) makes that detection
            // possible BEFORE anything is sent on the shared correlator.
            _ = try await orchestrator.performAttachReady(
                server: server, paneID: paneID, expectedGeneration: params.generation)
            return .ok()
        } catch let failure as AttachReplayFailure {
            logger.error("""
                attach.ready replay failed for \(server, privacy: .public)/\(paneID, privacy: .public) \
                gen=\(failure.generation): \(String(describing: failure.underlying), privacy: .public)
                """)
            // Detach ONLY the attach whose sequence failed. If a newer attach
            // owns the sink by now (fast tab-switch re-attach completed while
            // this sequence's delayed reply was in flight), the stale failure
            // must not EOF the successor's healthy pipe — nor unregister the
            // input route the successor relies on (same key, same values), so
            // the unregister is scoped to a successful detach.
            if await bridge.supervisor.detachIfGeneration(
                server: server, paneID: paneID, generation: failure.generation) {
                bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: paneID)
            }
            return RPCResponse(error: "attach replay failed: \(failure.underlying)")
        } catch {
            // Failure BEFORE the sequence acquired a generation
            // (`AttachReplayError.notAttached`: no sink at acknowledge time).
            // Nothing to clean up: the sink either doesn't exist or belongs
            // to a different attach, so detaching blindly here could kill it.
            // The input route likewise stays — a re-attach overwrites it, and
            // a route without a sink is harmless (same reasoning as the
            // ready-timeout path in `handleAttachRequest`).
            logger.error("""
                attach.ready replay failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return RPCResponse(error: "attach replay failed: \(error)")
        }
    }

    /// Handle `pane.detach`: close the pipe write end so the app's reader
    /// sees EOF. Best-effort — an unknown worktree or unconfigured bridge is
    /// a no-op, not an error (detach is fired on every view teardown).
    ///
    /// When the params carry the attach `generation` (echoed from
    /// `AttachRequestResult`), the detach is generation-checked: a closing
    /// view's detach can arrive AFTER a new view's attach for the same pane,
    /// and the stale detach must not kill the fresh sink (or its input
    /// route). Absent generation (older app) → unconditional, as before.
    func handlePaneDetach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneDetachParams.self, from: paramsData)
        if let bridge = controlMode,
           let worktree = try? await db.worktrees.get(id: params.worktreeID) {
            let server = worktree.tmuxServer
            if let generation = params.generation {
                if await bridge.supervisor.detachIfGeneration(
                    server: server, paneID: params.paneID, generation: generation) {
                    bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: params.paneID)
                }
            } else {
                bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: params.paneID)
                await bridge.supervisor.detach(server: server, paneID: params.paneID)
            }
        }
        return .ok()
    }

    /// Handle `pane.resize`: the app's debounced desired size for one window.
    /// Best-effort and tolerant like `handlePaneDetach` — this fires on every
    /// window-drag tail, so an unknown worktree or unconfigured bridge is an
    /// ok-noop, not an error. The coordinator arbitrates the actual
    /// `resize-window` + echo fence (addendum §4).
    func handlePaneResize(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneResizeParams.self, from: paramsData)
        if let bridge = controlMode,
           let worktree = try? await db.worktrees.get(id: params.worktreeID) {
            await bridge.resizeCoordinator.resize(
                server: worktree.tmuxServer,
                windowID: params.windowID,
                cols: params.cols,
                rows: params.rows)
        }
        return .ok()
    }

}

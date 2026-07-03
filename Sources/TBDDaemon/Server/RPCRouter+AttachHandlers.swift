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
        guard let bridge = controlMode,
              ControlModeGate.shouldEnable(
                  environment: bridge.environment, tmuxVersion: bridge.tmuxVersion) else {
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
            // re-attach overwrites this entry.
            bridge.inputRouter.register(worktreeID: params.worktreeID, paneID: paneID, server: server)
            do {
                try await bridge.fdVending.send(fd: readFD, header: header)
            } catch {
                // Vend failed — undo the attach so no orphan pipe lingers.
                Darwin.close(readFD)
                bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: paneID)
                await bridge.supervisor.detach(server: server, paneID: paneID)
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
            return try RPCResponse(result: AttachRequestResult(status: "pending"))
        } catch {
            logger.error("""
                attach.request failed for \(server, privacy: .public)/\(paneID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(error: "attach failed: \(error.localizedDescription)")
        }
    }

    /// Handle `attach.ready`: the app's reader is draining the vended fd —
    /// open the write gate.
    func handleAttachReady(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachReadyParams.self, from: paramsData)
        guard let bridge = controlMode else {
            return RPCResponse(error: "control mode not configured")
        }
        guard let worktree = try? await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }
        await bridge.supervisor.markReady(server: worktree.tmuxServer, paneID: params.paneID)
        return .ok()
    }

    /// Handle `pane.detach`: close the pipe write end so the app's reader
    /// sees EOF. Best-effort — an unknown worktree or unconfigured bridge is
    /// a no-op, not an error (detach is fired on every view teardown).
    func handlePaneDetach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneDetachParams.self, from: paramsData)
        if let bridge = controlMode,
           let worktree = try? await db.worktrees.get(id: params.worktreeID) {
            bridge.inputRouter.unregister(worktreeID: params.worktreeID, paneID: params.paneID)
            await bridge.supervisor.detach(server: worktree.tmuxServer, paneID: params.paneID)
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

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
            let (readFD, generation) = try await bridge.supervisor.attach(server: server, paneID: paneID)
            let header = try JSONEncoder().encode(
                FDVendHeader(worktreeID: params.worktreeID, paneID: paneID, attachID: params.attachID))
            do {
                try await bridge.fdVending.send(fd: readFD, header: header)
            } catch {
                // Vend failed — undo the attach so no orphan pipe lingers.
                Darwin.close(readFD)
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
            await bridge.supervisor.detach(server: worktree.tmuxServer, paneID: params.paneID)
        }
        return .ok()
    }
}

import Darwin
import Foundation
import TBDShared
import TBDKernel
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

extension RPCRouter {
    /// Handle `attach.request`: resolve the row, then hand a holder-backed
    /// session to `handleHolderAttachRequest`.
    ///
    /// Only a holder-backed terminal can be attached. A request that names no
    /// terminal, or a row on another transport, is answered "unavailable": a
    /// tmux-backed tab is viewed through its own `tmux attach` client and never
    /// asks for a descriptor.
    ///
    /// A read that throws is answered as an error, not as "unavailable": the
    /// app takes "unavailable" as permanent — no retry, no Retry button — for
    /// what is usually a moment of `SQLITE_BUSY` under a write. An error is
    /// what the app retries.
    func handleAttachRequest(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachRequestParams.self, from: paramsData)
        guard let terminalID = params.terminalID else {
            return try RPCResponse(result: AttachRequestResult(status: "unavailable"))
        }
        let terminal: TBDShared.Terminal?
        do {
            terminal = try await db.terminals.get(id: terminalID)
        } catch {
            logger.error("""
                attach.request could not read terminal \
                \(terminalID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(
                error: "attach failed: the terminal could not be read: "
                    + error.localizedDescription)
        }
        guard let terminal, terminal.transport == .holder else {
            return try RPCResponse(result: AttachRequestResult(status: "unavailable"))
        }
        return try await handleHolderAttachRequest(params: params, terminal: terminal)
    }

    /// The holder half of `attach.request`: quiesce, snapshot, vend a `dup` of
    /// the session's pty master.
    ///
    /// The choreography is a three-step handshake — request, an fd over
    /// `SCM_RIGHTS`, then `attach.ready` carrying the generation back. What is
    /// vended is the pty itself, and the vend is an ownership edge: the daemon
    /// stops reading here, and `HolderRegistry.beginAttach` records why.
    ///
    /// Failure is reported to the caller rather than degraded into a fallback:
    /// there is no second way to render a holder-backed session, so an attach
    /// that could not happen must say so.
    ///
    /// **A session the registry is not reading is adopted first, on demand.**
    /// Startup adoption can leave a live session unadopted — a holder busy or
    /// silent past its budget, a row deferred past the startup budget and not
    /// yet reached, a take-back whose hand-over failed — and nothing else
    /// would adopt it until somebody asked. An attach is that ask. The
    /// registry rules out what it can see (`HolderRegistry.adoptForAttach`),
    /// `mayAdoptForAttach` refuses early what only the row and the hibernation
    /// coordinator can, and the wait is bounded, so the request cannot hang
    /// on a holder that will not answer.
    private func handleHolderAttachRequest(
        params: AttachRequestParams, terminal: Terminal
    ) async throws -> RPCResponse {
        guard let registry = holderRegistry else {
            return try RPCResponse(result: AttachRequestResult(status: "unavailable"))
        }
        // The fd sidecar is the vend channel. It is listening whenever the
        // daemon is.
        guard let sidecar = attachSidecar else {
            return RPCResponse(error: "the fd sidecar is not configured in this daemon")
        }

        let vend: HolderAttachVend
        let header: Data
        do {
            // Encoded before the attach, so a throw from it cannot leave a
            // vended descriptor and a suspended drain behind.
            header = try JSONEncoder().encode(
                FDVendHeader(
                    worktreeID: params.worktreeID, paneID: params.paneID,
                    attachID: params.attachID))
            // One hop for a session already adopted, the common case: the
            // registry answers that synchronously and asks the row-level gate
            // only when an adoption could follow. When the adoption cannot
            // happen, `beginAttach` below is what reports it: `noLiveReader`,
            // read as "ended" when the holder is gone.
            try await registry.adoptForAttach(
                terminal: terminal,
                holderIsLive: holderProcessIsLive,
                rowPermits: { await self.mayAdoptForAttach(terminal) })
            // The app's number for this request rides onto the pending attach
            // and the claim it becomes, which is what lets a claim sweep order
            // the app's statement of what it holds against this attach. The
            // viewer's grid is what the snapshot is written at; an app that
            // sends none gets the session at the size it had.
            var viewerGrid: (columns: Int, rows: Int)?
            if let cols = params.cols, let rows = params.rows {
                viewerGrid = (columns: cols, rows: rows)
            }
            vend = try await registry.beginAttach(
                terminalID: terminal.id, attachSeq: params.attachSeq, viewerGrid: viewerGrid)
        } catch let error as HolderRegistry.Error
            where attachRefusalMeansSessionEnded(error, terminal: terminal) {
            // Refused, and the holder the row records is not running: the
            // session is over, not merely unattachable. Answered as a status
            // rather than an error so the app neither retries it nor tells the
            // user the session "keeps running" and to retry the attach.
            logger.warning("""
                holder attach.request for terminal \(terminal.id.uuidString, privacy: .public): \
                its holder (pid \(terminal.holderPID ?? 0, privacy: .public)) is no longer \
                running; reporting the session as ended
                """)
            return try RPCResponse(
                result: AttachRequestResult(status: AttachRequestResult.holderSessionEndedStatus))
        } catch {
            logger.error("""
                holder attach.request failed for terminal \
                \(terminal.id.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(error: "attach failed: \(error.localizedDescription)")
        }

        let recipient: ProcessIdentity?
        do {
            recipient = try await sidecar.fdVending.sendReportingRecipient(fd: vend.ptyFD, header: header)
        } catch {
            Darwin.close(vend.ptyFD)
            await registry.cancelPendingAttach(
                terminalID: terminal.id, generation: vend.generation,
                reason: Self.cancelReason(forVendFailure: error))
            logger.error("""
                could not vend the pty for terminal \(terminal.id.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(error: "attach failed: \(error.localizedDescription)")
        }
        // The kernel duplicated the fd into the app's table; drop ours.
        Darwin.close(vend.ptyFD)
        // Whose table, recorded against the attach before the response that
        // lets the app acknowledge it: the claim this attach becomes is then
        // owned by that app, and only that app's confirmed death takes it back.
        // The identity is the one the send itself read for the connection it
        // wrote on — see `sendReportingRecipient` for why no earlier lookup
        // would do. Only the record is awaited: a delivery to an app already
        // confirmed gone is taken back in a task the registry starts and owns,
        // so this reply never waits on a holder.
        await registry.recordAttachRecipient(
            recipient, terminalID: terminal.id, generation: vend.generation)

        // The ready-timeout, pointed at this registry's own cancel: an app
        // that died mid-attach would otherwise leave the session suspended
        // behind a descriptor nobody reads. It is generation-scoped, so a timer
        // outliving the attach it was started for is a no-op — and note what it
        // does NOT do: an attach that timed out is not resumed, because the app
        // has the descriptor and a lost ack cannot be told from a lost app.
        //
        // `try?` swallows a cancellation and falls through to the cancel. That
        // is harmless only because the cancel is generation-scoped and a no-op
        // once the attach is acknowledged; nothing retains this task, so
        // nothing cancels it today.
        let timeout = sidecar.readyTimeout
        let clock = sidecar.clock
        let terminalID = terminal.id
        let generation = vend.generation
        Task {
            try? await clock.sleep(for: timeout)
            await registry.cancelPendingAttach(
                terminalID: terminalID, generation: generation, reason: .unacknowledged)
        }

        return try RPCResponse(
            result: AttachRequestResult(
                status: "pending",
                generation: vend.generation,
                snapshotPreamble: vend.snapshotPreamble))
    }

    /// Whether an attach may adopt this session itself when the registry is
    /// not reading it: the row, as the attach read it, is awake, and no park,
    /// wake or in-place profile swap holds it right now.
    ///
    /// **A best-effort early refusal, not an exclusion.** It runs outside the
    /// registry, on a row read at the top of the request, and takes no claim,
    /// so a park, wake or swap that claims the row after it answers does not
    /// stop the adoption that follows. Nothing locks across the two actors to
    /// close that, because nothing needs to: the registry's own gates — a
    /// reader being released, a holder it told to let go, an ended job, a
    /// shutdown — are re-asked in the stretch that adopts, and a transition
    /// that claims late meets an adopted session like any other. A park (and
    /// so a swap, which starts with one) ends the job behind the reader it
    /// finds, and refuses when there is none yet. A wake reaches the holder
    /// only through the registry, which joins an adoption in flight and
    /// refuses to spawn over an occupied slot, so it never stacks a second
    /// reader beside this one.
    ///
    /// What the early refusal buys is not opening a hand-over at all for a
    /// row that reads parked — its job was ended by its park — or while a
    /// transition already owns the session's holder.
    func mayAdoptForAttach(_ terminal: Terminal) async -> Bool {
        guard !terminal.isParked else { return false }
        let moving = await hibernationCoordinator.transitionInFlight(terminalID: terminal.id)
        return !moving
    }

    /// Whether `beginAttach` refusing with `error` means the session has
    /// ended rather than that this attach cannot happen right now. "Ended" is
    /// `HolderChildDisposition.sessionHasEnded` — the park's own answer — so a
    /// tab whose job still runs is never told its session is over.
    ///
    /// Three refusals can stand in front of a dead holder, because the registry
    /// checks its own bookkeeping before it ever reaches the pty: no reader at
    /// all, a viewer claim, and an attach still pending. Each of them is the
    /// ended answer when the holder is gone — a claim or a pending attach on a
    /// session nothing serves any more is bookkeeping, not a session. Every
    /// other refusal is about the request, not the session, and stays an error.
    func attachRefusalMeansSessionEnded(
        _ error: HolderRegistry.Error, terminal: Terminal
    ) -> Bool {
        switch error {
        case .noLiveReader, .attachedToViewer, .attachAlreadyPending:
            return HolderChildDisposition.sessionHasEnded(
                terminal, holderIsLive: holderProcessIsLive, signaller: holderChildSignaller)
        default:
            return false
        }
    }

    /// Handle `attach.ready`: the app has the vended descriptor, so the
    /// holder-backed session becomes the viewer's. A request that names no
    /// holder-backed terminal is an error: nothing was vended for it to
    /// acknowledge.
    func handleAttachReady(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachReadyParams.self, from: paramsData)
        guard let terminalID = params.terminalID,
              let terminal = try? await db.terminals.get(id: terminalID),
              terminal.transport == .holder
        else {
            return RPCResponse(error: "attach.ready names no holder-backed terminal")
        }
        return await handleHolderAttachReady(params: params, terminal: terminal)
    }

    /// What a failed vend proves about where the descriptor is, which is the
    /// only question that decides whether the daemon may read the pty again.
    ///
    /// **A thrown send is not by itself evidence that nothing was delivered.**
    /// `FDChannel.sendFD` sends the frame and the `SCM_RIGHTS` block in one
    /// `sendmsg`, and a short send is POSIX-legal: the descriptor rides the
    /// prefix that landed and the remainder goes out separately, so a failure
    /// there leaves the app holding a live `dup` of the pty. That case is named
    /// on the wire type (`descriptorSentFrameIncomplete`) precisely so this
    /// decision can rest on daemon-side evidence rather than on the app's
    /// closing of orphaned descriptors when its scanner desyncs — which is real
    /// mitigation, but it is the peer's behaviour, not proof available here.
    ///
    /// Everything else means the `sendmsg` itself never succeeded — no
    /// connection at all (`FDVendingServerError.notConnected`, the common
    /// case), or an errno from the syscall — so this process still holds the
    /// only copy of the descriptor that was ever made, and resuming the drain
    /// cannot produce a second reader. Leaving that out would strand a session
    /// unread for a failure that says nothing whatever about the app.
    static func cancelReason(
        forVendFailure error: any Swift.Error
    ) -> HolderRegistry.AttachCancelReason {
        if case FDChannelError.descriptorSentFrameIncomplete = error {
            return .unacknowledged
        }
        return .descriptorNeverDelivered
    }

    /// The holder half of `attach.ready`: the viewer is on the pty, so the pty
    /// becomes the viewer's and the daemon's reader stays suspended and
    /// retained — it is the session's screen and its mode oracle for as long as
    /// the viewer holds the descriptor.
    ///
    /// There is nothing to replay here — the screen went out with the
    /// request, as the snapshot preamble — so this is only the ownership edge,
    /// plus the jiggle `confirmAttach` performs while it still holds the
    /// descriptor.
    ///
    /// A refused ack is an RPC error rather than a silent success, and the app
    /// is expected to detach on it: a viewer whose ack was refused is reading a
    /// descriptor the daemon has not accounted for, which is the state this
    /// whole path exists to keep bounded.
    private func handleHolderAttachReady(
        params: AttachReadyParams, terminal: Terminal
    ) async -> RPCResponse {
        guard let registry = holderRegistry else {
            return RPCResponse(error: "holder transport is not wired in this daemon")
        }
        guard let generation = params.generation else {
            // Older app, or a caller that dropped the generation. There is
            // nothing to check the ack against, and confirming the wrong attach
            // would release a reader a live attach depends on.
            return RPCResponse(error: "a holder attach.ready must carry its attach generation")
        }
        do {
            try await registry.confirmAttach(terminalID: terminal.id, generation: generation)
            return .ok()
        } catch {
            logger.error("""
                holder attach.ready refused for terminal \
                \(terminal.id.uuidString, privacy: .public) generation \
                \(generation, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return RPCResponse(error: "attach.ready refused: \(error.localizedDescription)")
        }
    }

    /// Handle `pane.detach`: a viewer has let go of a holder-backed session.
    /// Best-effort — a request that names no holder-backed terminal is a
    /// no-op, not an error, because a detach is fired on every view teardown.
    func handlePaneDetach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneDetachParams.self, from: paramsData)
        if let terminalID = params.terminalID,
           let terminal = try? await db.terminals.get(id: terminalID),
           terminal.transport == .holder {
            return await handleHolderPaneDetach(params: params, terminal: terminal)
        }
        return .ok()
    }

    /// The holder half of `pane.detach`: the viewer has closed its descriptor,
    /// so the daemon takes the session back and puts a drain on it again.
    ///
    /// Ordering is the app's to keep and is stated where it is kept
    /// (`Coordinator.detachHolderSession`): the descriptor is closed *before*
    /// this is sent. Nothing here can verify it — a detach carries no evidence
    /// about another process's file table — which is why the app-side test
    /// asserts the close has already happened at the instant this call is made.
    ///
    /// **Every outcome is RPC success**, and the reason is stronger than "best
    /// effort": a detach fires on every view
    /// teardown, the app has already released everything it held by the time it
    /// sends one, and there is no recovery it could run on a refusal. So a
    /// refusal is logged, not returned — and the log line means one of two
    /// things, which is why it names the error.
    ///
    /// - The handback was **stale**: a closing viewer racing its successor's
    ///   attach. The successor is the truth and owns the pty.
    /// - The take-back itself **failed**: the rendezvous socket is gone, the
    ///   holder stayed busy past its retry budget, `pipe()` would not open.
    ///   There is **no** successor. `takeBackFromViewer` drops the claim on its
    ///   way out, so the session is left with no reader at all until something
    ///   adopts it again, and the next attach is what recovers it.
    ///
    /// So `holder pane.detach refused` is not by itself evidence that somebody
    /// else holds this pty — on the second branch nobody does.
    private func handleHolderPaneDetach(
        params: PaneDetachParams, terminal: Terminal
    ) async -> RPCResponse {
        guard let registry = holderRegistry else { return .ok() }
        guard let generation = params.generation else {
            // Nothing to check the handback against. Clearing a claim by name
            // alone would let a stale detach take the pty from the attach that
            // superseded it, which is the failure the generation exists for.
            logger.error("""
                a holder pane.detach for terminal \(terminal.id.uuidString, privacy: .public) \
                carried no attach generation, so the session was left with its viewer claim
                """)
            return .ok()
        }
        do {
            try await registry.acceptHandback(
                terminal: terminal, generation: generation,
                preamble: params.snapshotPreamble ?? Data())
        } catch {
            logger.error("""
                holder pane.detach refused for terminal \
                \(terminal.id.uuidString, privacy: .public) generation \
                \(generation, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
        return .ok()
    }

    /// Handle `holder.reconcileClaims`: the app's statement, sent on every poll
    /// tick, of which holder sessions it holds a descriptor for or has an
    /// attach in flight for. While `holder_claim_reconcile_enabled` is on, the
    /// registry takes back that app's claims on every other session
    /// (`HolderRegistry.reconcileClaims`); while it is off, it only names them
    /// (`HolderRegistry.reportClaims`). Design:
    /// docs/specs/2026-10-25-holder-claim-reconcile-design.md.
    ///
    /// **The registry's cheap gate runs first.** In the steady state every
    /// live panel's session is in `held`, so the gate answers false and the
    /// sweep costs one actor hop: no database read, no `ps`.
    ///
    /// **The flag is read next, before the pid is resolved, and while it is
    /// off the pid is never resolved.** Resolving it spawns `ps` twice and
    /// blocks. With the flag off a candidate is never taken back, so after
    /// one truly lost handback it would pass the gate on every 2 s tick until
    /// the app quits, and each tick would pay for the resolve. The report
    /// matches by pid alone instead, as the gate does; that can name a claim
    /// whose owner merely reused the app's pid, and naming it changes
    /// nothing. With the flag on, the pid is resolved and its start time
    /// tells the app apart from a reused pid, and every candidate the sweep
    /// selects is taken back, or dropped by a failed take-back, so it stops
    /// passing the gate.
    ///
    /// **Nothing here is an error.** A daemon with no holder transport, a pid
    /// that does not resolve, and a sweep with nothing to take back all answer
    /// an empty result: the app ignores a failed sweep and sends the next one
    /// a tick later, so an error would carry nothing it could act on. A flag
    /// that cannot be read is taken at its shipped default, as an unset one is.
    func handleHolderReconcileClaims(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(HolderReconcileClaimsParams.self, from: paramsData)
        let held = Set(params.held)
        guard let registry = holderRegistry,
              await registry.hasCandidates(
                ownedByPID: params.appPID, held: held, throughSeq: params.throughSeq)
        else {
            return try RPCResponse(result: HolderReconcileClaimsResult())
        }
        let act: Bool
        do {
            act = try await db.config.get().holderClaimReconcileEnabled
        } catch {
            logger.error("""
                holder.reconcileClaims could not read holder_claim_reconcile_enabled, so the \
                sweep takes the shipped default: \(error.localizedDescription, privacy: .public)
                """)
            act = Config.holderClaimReconcileEnabledDefault
        }
        guard act else {
            let report = await registry.reportClaims(
                ownedByPID: params.appPID, held: held, throughSeq: params.throughSeq)
            return try RPCResponse(
                result: HolderReconcileClaimsResult(
                    takenBack: report.takenBack, wouldTakeBack: report.wouldTakeBack))
        }
        guard let app = appIdentityResolver(params.appPID) else {
            logger.info("""
                holder.reconcileClaims from pid \(params.appPID, privacy: .public) swept \
                nothing: that pid could not be resolved to a process identity
                """)
            return try RPCResponse(result: HolderReconcileClaimsResult())
        }
        let sweep = await registry.reconcileClaims(
            heldBy: app, held: held, throughSeq: params.throughSeq)
        return try RPCResponse(
            result: HolderReconcileClaimsResult(
                takenBack: sweep.takenBack, wouldTakeBack: sweep.wouldTakeBack))
    }

    /// Handle `pane.resize`: the app's debounced desired size for a
    /// holder-backed session. Best-effort and tolerant like
    /// `handlePaneDetach` — this fires on every window-drag tail, so a request
    /// that names no terminal is an ok-noop, not an error. The registry
    /// decides which half of the resize is still the daemon's.
    func handlePaneResize(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneResizeParams.self, from: paramsData)
        if let terminalID = params.terminalID {
            await holderRegistry?.applyViewerResize(
                terminalID: terminalID, columns: params.cols, rows: params.rows)
        }
        return .ok()
    }
}

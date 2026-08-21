import AppKit
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Worktrees")

/// The arguments `createWorktree` hands to `worktree.create`. A struct rather
/// than a twelve-parameter closure signature, so the injection seam behind
/// `AppState.worktreeCreator` stays readable and tests can assert what was sent.
struct WorktreeCreateRequest: Sendable {
    let repoID: UUID
    let branch: String?
    let displayName: String?
    let cols: Int?
    let rows: Int?
    let parentWorktreeID: UUID?
    let useExistingBranch: Bool
    let profileID: UUID?
    let model: String?
    let primaryAgentPreference: PrimaryAgentPreference?
    let prNumber: Int?
    let checkoutPRHead: Bool?
}

extension AppState {
    // MARK: - Worktree Actions

    /// Create a new worktree in a repo.
    /// Shows an optimistic placeholder immediately, then replaces it with the
    /// real worktree once the daemon responds.
    /// When `parentWorktreeID` is non-nil, the new worktree is created as a
    /// nested child of that worktree (must be in the same repo).
    /// When `existingBranch` is non-nil, the daemon checks out that branch
    /// into a new worktree (no auto-generated `tbd/*` branch); the optimistic
    /// placeholder uses the branch's local name so the row looks right
    /// immediately.
    /// `profileID` is an optional explicit model-profile override chosen at
    /// creation time (sidebar `+` profile picker). nil resolves the profile via
    /// the daemon's normal repo/scratch/global precedence chain (today's behavior).
    /// `model` is an optional per-spawn Claude model override (picker model
    /// buttons); it applies to the initial spawn only — later respawns fall
    /// back to the profile default.
    func createWorktree(repoID: UUID, parentWorktreeID: UUID? = nil, existingBranch: BranchInfo? = nil, profileID: UUID? = nil, model: String? = nil, primaryAgentPreference: PrimaryAgentPreference? = nil, prNumber: Int? = nil, checkoutPRHead: Bool? = nil, displayName: String? = nil) {
        // Optimistic placeholder so the row appears instantly. When picking an
        // existing branch we use its local name so the placeholder name
        // doesn't briefly show a fake `tbd/*` value.
        let placeholderName: String
        let placeholderBranch: String
        if let existingBranch {
            placeholderName = existingBranch.localName
            placeholderBranch = existingBranch.localName
        } else {
            placeholderName = NameGenerator.generate()
            placeholderBranch = "tbd/\(placeholderName)"
        }
        let placeholder = Worktree(
            repoID: repoID,
            name: placeholderName,
            displayName: displayName ?? placeholderName,
            branch: placeholderBranch,
            path: "",
            status: .creating,
            tmuxServer: "",
            parentWorktreeID: parentWorktreeID
        )
        pendingWorktreeIDs.insert(placeholder.id)
        worktrees[repoID, default: []].append(placeholder)
        selectedWorktreeIDs = [placeholder.id]
        // With the queued prompt live, the modal owns focus and rename-on-create
        // stands down: the two cannot both have it, and the prompt is why the
        // modal exists. Renaming stays available from the sidebar. With the
        // capability off this is exactly today's behavior.
        let promptTarget: QueuedPromptTarget? = daemonCapabilities?.queuedPromptEnabled == true
            ? QueuedPromptTarget(
                placeholderID: placeholder.id,
                repoID: repoID,
                worktreeName: placeholder.displayName)
            : nil
        if promptTarget == nil {
            editingWorktreeID = placeholder.id
        }

        Task {
            defer { pendingWorktreeIDs.remove(placeholder.id) }
            // Every exit from this Task that did NOT reach `.created` is a
            // failure from the modal's point of view — a thrown RPC error, or
            // a row that vanished mid-create. `resolve` is idempotent, so a
            // success already reported wins and this is a no-op; without it a
            // submitted prompt would wait forever on an ID that never comes.
            defer { promptTarget?.resolve(.failed) }
            do {
                let size = mainAreaTerminalSize()
                // Let the daemon generate `name` and default `displayName` to it
                // via WorktreeStore.create's `displayName ?? name` default.
                // This yields `name == displayName` (fixing the bug where new
                // worktrees were born with diverged slugs), and keeps `folder == nil`
                // so the collision-retry safety net in attemptWorktreeAdd stays
                // enabled (do not pass folder; it gates retry logic). The local
                // optimistic placeholder still uses placeholderName for immediate UI,
                // and replaceCreationPlaceholder's rename inference (comparing local
                // state) is unaffected. A cosmetic slug-flip at swap is acceptable.
                let wt = try await worktreeCreator(WorktreeCreateRequest(
                    repoID: repoID,
                    branch: existingBranch?.name,
                    displayName: displayName,
                    cols: size.cols, rows: size.rows,
                    parentWorktreeID: parentWorktreeID,
                    useExistingBranch: existingBranch != nil,
                    profileID: profileID,
                    model: model,
                    primaryAgentPreference: primaryAgentPreference,
                    prNumber: prNumber,
                    checkoutPRHead: checkoutPRHead
                ))
                // Hand the modal the daemon's ID. Until this lands the modal
                // has nothing to park against, which is what makes "the
                // parking RPC cannot precede the create RPC" a property of the
                // code rather than of the timing.
                //
                // It happens before the swap, and unconditionally: the daemon
                // row exists from here on, whatever the local list looks like.
                // Resolving it inside the `if let swap` below told the operator
                // "worktree creation failed" for a worktree that had in fact
                // been created, and threw their typed prompt away with the row
                // still there to receive it.
                promptTarget?.resolve(.created(wt.id))
                // Replace the placeholder with the real worktree, carrying
                // over any rename the user typed while creation was in
                // flight. A nil result means neither the placeholder nor a
                // poll-merged daemon row exists anymore (e.g. the repo was
                // removed mid-create) — don't arm selection/editing for a
                // vanished row.
                if let swap = replaceCreationPlaceholder(
                    repoID: repoID,
                    placeholderID: placeholder.id,
                    placeholderName: placeholderName,
                    with: wt
                ) {
                    selectedWorktreeIDs = [wt.id]
                    if promptTarget == nil {
                        editingWorktreeID = wt.id
                    }
                    // Persist the carried rename now that a daemon-known row
                    // exists (the placeholder's id never reached the daemon,
                    // so renameWorktree's placeholder branch could only apply
                    // it locally). Route through renameWorktree rather than an
                    // inline daemonClient call: wt.id is daemon-known and NOT
                    // in pendingWorktreeIDs, so it takes the full RPC path —
                    // optimistic apply (idempotent; the swap already carried
                    // the name), post-success re-apply to beat an interleaved
                    // poll revert, and rollback + "Rename failed:" alert on
                    // failure. The old inline call's catch only logged, so a
                    // non-connection RPC failure silently lost the name.
                    if let typedName = swap.typedName {
                        await renameWorktree(id: wt.id, displayName: typedName)
                    }
                }
            } catch {
                // Remove the placeholder on failure
                worktrees[repoID]?.removeAll { $0.id == placeholder.id }
                logger.error("Failed to create worktree: \(error)")
                handleConnectionError(error)
            }
        }

        // Present the modal only now, with the creation Task already launched
        // and owning every await the RPC needs. Nothing above this line waits
        // on the operator, and nothing below can be reached by the creation
        // path — that is the whole "creation is not slowed" claim.
        if let promptTarget {
            presentQueuedPrompt(promptTarget)
        }
    }

    /// Whether the shared prompt-sheet slot is empty — nothing composing and
    /// nothing being read back. The one condition every writer to that slot
    /// checks, so "at most one prompt sheet, and it is never swapped for
    /// another" holds no matter which surface asks.
    var promptSheetSlotIsFree: Bool {
        queuedPromptTarget == nil && parkedPromptReadback == nil
    }

    /// Show `target`'s modal, or queue it behind whatever prompt sheet is up.
    ///
    /// Two Cmd+N presses in quick succession create two worktrees, and each
    /// deserves its own first message. Assigning `queuedPromptTarget` directly
    /// would orphan the first: `.sheet(item:)` handed a replacement item is
    /// unreliable on macOS — the presented sheet can keep the old target while
    /// state names the new one, so the operator types a message for the second
    /// worktree and it is parked against the first. Queuing sidesteps the swap
    /// entirely; the second modal opens when the first closes.
    ///
    /// A read-back holds the slot on exactly the same terms. Menu-bar commands
    /// still fire while a sheet is on screen, so Cmd+N over an open read-back
    /// would otherwise flip the presented item from the read-back to the new
    /// target without passing through nil — the same swap, entered by the other
    /// door.
    func presentQueuedPrompt(_ target: QueuedPromptTarget) {
        guard promptSheetSlotIsFree else {
            queuedPromptBacklog.append(target)
            return
        }
        queuedPromptTarget = target
    }

    /// Open the next queued modal, if the slot is free and any are waiting.
    /// Called when either sheet goes nil — submit, Cancel, Escape and Close all
    /// funnel through that.
    ///
    /// The next sheet is presented on a later main-actor turn rather than
    /// inline: AppKit is still tearing the closing sheet down, and presenting
    /// into that teardown is the very unreliability this queue exists to avoid.
    /// The turn is also a window in which the slot can be taken — the sidebar
    /// is clickable the moment a sheet closes — so the deferred half re-checks
    /// and puts the target back at the head of the queue rather than presenting
    /// over whatever arrived.
    func advanceQueuedPromptBacklog() {
        guard promptSheetSlotIsFree, !queuedPromptBacklog.isEmpty else { return }
        let next = queuedPromptBacklog.removeFirst()
        Task { @MainActor in
            guard promptSheetSlotIsFree else {
                queuedPromptBacklog.insert(next, at: 0)
                return
            }
            queuedPromptTarget = next
        }
    }

    /// Park the prompt the operator composed in `QueuedPromptModal`.
    ///
    /// Fire-and-forget, and deliberately a second RPC rather than a parameter
    /// on `worktree.create`: it may be sent long after creation finished, and
    /// creation must never wait for it. Blank text parks nothing — that is the
    /// same outcome as dismissing the sheet.
    ///
    /// **Nothing that fails here may swallow what the operator wrote.** The
    /// modal is gone by the time any of these answers arrives, and there is no
    /// draft store behind it — an alert alone would leave a message that exists
    /// nowhere. So every path that ends without the text parked puts it on the
    /// pasteboard first and says so, which is the same recovery the read-back's
    /// Copy offers for text that was parked and cannot be delivered.
    func submitQueuedPrompt(_ target: QueuedPromptTarget, text: String, submit: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            switch await target.awaitResolution() {
            case .failed:
                // There is no row to park against. Say so rather than dropping
                // the prompt silently; the text is still on screen behind the
                // alert only if the sheet is up, so name what happened.
                logger.error("Queued prompt not sent: worktree creation failed")
                keepUnqueuedFirstMessage(
                    trimmed,
                    "Worktree creation failed — your first message was not sent.")
            case .created(let worktreeID):
                do {
                    let result = try await pendingPromptSetter(worktreeID, trimmed, submit)
                    if case .refused(let reason) = result {
                        keepUnqueuedFirstMessage(
                            trimmed, "First message was not queued: \(reason)")
                    }
                } catch {
                    logger.error("Failed to queue prompt: \(error, privacy: .public)")
                    keepUnqueuedFirstMessage(
                        trimmed,
                        "Failed to queue your first message: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Hand a composed first message back to the operator after it failed to
    /// park, and tell them where it went.
    ///
    /// The pasteboard because it is the one place text can be put that survives
    /// the alert, needs no new surface, and is where they would paste from
    /// anyway. `reason` is a sentence — the alert appends where the text is, so
    /// the two facts arrive together and neither can be shown without the
    /// other.
    private func keepUnqueuedFirstMessage(_ text: String, _ reason: String) {
        pasteboardWriter(text)
        showAlert("\(reason) It has been copied to your clipboard.", isError: true)
    }

    /// Close whichever prompt sheet is on screen — the write half of the single
    /// `.sheet(item:)` both surfaces share. Clears exactly the presented one,
    /// so closing a compose modal cannot silently discard a read-back (and the
    /// compose observer still advances the creation backlog).
    func dismissPresentedPromptSheet() {
        if queuedPromptTarget != nil {
            queuedPromptTarget = nil
        } else {
            parkedPromptReadback = nil
        }
    }

    // MARK: - Reading a parked prompt back

    /// Open the read-back for the prompt still sitting in this worktree's
    /// `pending_prompt` column.
    ///
    /// The column is the recovery store, and `ParkedPromptReadback(worktree:)`
    /// is the one rule for reading it — the same rule every glyph's visibility
    /// uses.
    ///
    /// Takes the row's own `Worktree` rather than an ID: an archived row is not
    /// in `findWorktree`'s lists, and archived rows are precisely where retained
    /// text is most at risk of becoming unreachable. The value the glyph was
    /// drawn from is the value to read back.
    func revealParkedPrompt(_ worktree: Worktree) {
        // A compose modal owns the slot; opening over it would swap the
        // presented sheet non-nil→non-nil. Unreachable by pointer (the modal
        // covers the row), enforced anyway so `PromptSheet`'s precedence stays
        // a tiebreak rather than a mechanism.
        guard queuedPromptTarget == nil else { return }
        guard let readback = parkedPrompt(for: worktree) else {
            // Delivered (or unparked) between the click and the read. Say so
            // rather than opening an empty sheet.
            showTransientToast("That first message has already been delivered.", style: .notice)
            return
        }
        parkedPromptReadback = readback
    }

    /// Put the message on the pasteboard. The recovery path that works even
    /// when nothing can be delivered — an archived worktree, a shell primary,
    /// a daemon that is gone.
    ///
    /// Copies what is ON SCREEN, edits included: the text the operator is
    /// looking at is the text they mean. Defaults to the parked text for
    /// callers with no composer.
    func copyParkedPrompt(_ readback: ParkedPromptReadback, text: String? = nil) {
        pasteboardWriter(text ?? readback.text)
        showTransientToast("First message copied.", style: .success)
    }

    /// This worktree's parked first message, phase included — the one lookup
    /// every surface uses, so the pane banner, the status-bar entry and the
    /// composer are always describing the same state of the same text.
    func parkedPrompt(for worktree: Worktree) -> ParkedPromptReadback? {
        ParkedPromptReadback(worktree: worktree, terminals: terminals[worktree.id] ?? [])
    }

    /// Why this prompt cannot be delivered, if the app can see a reason. Read
    /// off the snapshot's own phase, so the sheet's copy, the disabled button
    /// and the guard in `deliverParkedPromptNow` cannot disagree.
    func parkedPromptUndeliverableReason(
        _ readback: ParkedPromptReadback
    ) -> ParkedPromptUndeliverable? {
        readback.phase.undeliverableReason
    }

    /// Park `text` — which may be an edit of what was parked before — and
    /// re-arm delivery.
    ///
    /// `worktree.setPendingPrompt` is not merely a column write: the daemon's
    /// `PendingPromptCoordinator.park` re-enters the worktree into this
    /// session's armed set, disarms any stale wait, and either arms a paste
    /// against the live primary agent (`.awaitingReady`) or leaves it for the
    /// next spawn to carry on its argv (`.parkedForSpawn`). That is why
    /// Deliver-now needs no RPC of its own — and why the two outcomes are
    /// reported differently: one is happening now, the other is a promise.
    ///
    /// The text and the submit bit come from the composer, not from `readback`:
    /// the wait is exactly when an operator changes their mind about what to
    /// say, and the send-immediately bit is a per-message choice rather than a
    /// property of the parked text.
    func deliverParkedPromptNow(
        _ readback: ParkedPromptReadback, text: String, submit: Bool
    ) async {
        // Empty text is the UNPARK signal, not a delivery: sending it here
        // would silently destroy the very message this surface exists to
        // protect. Discard is a deliberate act with its own button.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // An archived worktree and a shell primary are both undeliverable, and
        // a park answer alone cannot always say which: reporting one as
        // success would close the sheet, send the operator round the same loop,
        // and steer them away from Copy — the thing that does work.
        if let undeliverable = parkedPromptUndeliverableReason(readback) {
            showAlert(undeliverable.message, isError: true)
            return
        }
        // A second click while the first call is outstanding parks the same
        // text twice, and the daemon delivers what it is told.
        guard !parkedPromptDeliveryInFlight else { return }
        parkedPromptDeliveryInFlight = true
        defer { parkedPromptDeliveryInFlight = false }
        do {
            let result = try await pendingPromptSetter(readback.id, trimmed, submit)
            switch result {
            case .refused(let reason):
                showAlert("Couldn't deliver the first message: \(reason)", isError: true)
            case .awaitingReady:
                parkedPromptReadback = nil
                showTransientToast("Delivering the first message to the agent.", style: .notice)
            case .parkedForSpawn:
                parkedPromptReadback = nil
                showTransientToast(
                    "First message re-queued — it goes in when the agent starts.", style: .notice)
            }
        } catch {
            logger.error("Failed to deliver parked prompt: \(error, privacy: .public)")
            showAlert(
                "Couldn't deliver the first message: \(error.localizedDescription)", isError: true)
        }
    }

    /// Throw the parked text away, clearing the column.
    ///
    /// The wait before delivery can be long — a `preSession` hook runs for
    /// minutes — and a message written at creation is not always one still
    /// worth sending by the time an agent exists to read it. Without Discard
    /// the only ways out are to send something unwanted or to leave a notice
    /// standing.
    ///
    /// Unparking is `setPendingPrompt` with no text — the daemon clears the
    /// column and disarms any pending wait — so this needs no verb of its own.
    func discardParkedPrompt(_ readback: ParkedPromptReadback) async {
        guard !parkedPromptDeliveryInFlight else { return }
        parkedPromptDeliveryInFlight = true
        defer { parkedPromptDeliveryInFlight = false }
        do {
            let result = try await pendingPromptSetter(readback.id, nil, readback.submit)
            if let refusal = ParkedPromptReadback.discardRefusal(result) {
                showAlert("Couldn't discard the first message: \(refusal)", isError: true)
                return
            }
            parkedPromptReadback = nil
            showTransientToast("First message discarded.", style: .success)
        } catch {
            logger.error("Failed to discard parked prompt: \(error, privacy: .public)")
            showAlert(
                "Couldn't discard the first message: \(error.localizedDescription)", isError: true)
        }
    }

    /// Result of a successful creation-placeholder swap. `typedName` carries
    /// the rename the user typed while creation was in flight (nil when the
    /// placeholder was never renamed).
    struct PlaceholderSwapResult {
        let typedName: String?
    }

    /// Swap the optimistic creation placeholder row for the daemon's worktree.
    /// The daemon row has a different UUID, so a wholesale swap would clobber
    /// a rename the user typed while creation was in flight (renameWorktree's
    /// placeholder branch — gated on `pendingWorktreeIDs` — applies such
    /// renames locally, onto the placeholder). Detects that case by comparing
    /// the placeholder row's current `displayName` against `placeholderName`
    /// (the name it was created with, which `createWorktree` also sends in
    /// the create RPC so the daemon row starts with the same name); when they
    /// differ, the typed name is carried onto the replacement row and
    /// returned so the caller can persist it via the rename RPC.
    ///
    /// Exactly one final row ends up in the repo's list: a poll can merge the
    /// daemon row alongside the still-preserved placeholder, so any existing
    /// `wt.id` row is deduped, preferring the placeholder's position.
    /// Returns nil when neither the placeholder nor a `wt.id` row exists
    /// anymore (e.g. the repo was removed mid-create) — the row is NOT
    /// resurrected, and the caller must not select/edit the vanished row.
    func replaceCreationPlaceholder(
        repoID: UUID,
        placeholderID: UUID,
        placeholderName: String,
        with wt: Worktree
    ) -> PlaceholderSwapResult? {
        guard var rows = worktrees[repoID] else { return nil }
        let placeholderIdx = rows.firstIndex { $0.id == placeholderID }
        let existingIdx = rows.firstIndex { $0.id == wt.id }

        let typedName: String?
        if let placeholderIdx, rows[placeholderIdx].displayName != placeholderName {
            typedName = rows[placeholderIdx].displayName
        } else {
            typedName = nil
        }
        var replacement = wt
        if let typedName {
            replacement.displayName = typedName
        }

        switch (placeholderIdx, existingIdx) {
        case (let pIdx?, let eIdx?):
            // Poll merged the daemon row alongside the preserved placeholder:
            // keep the placeholder's position, drop the merged duplicate.
            rows[pIdx] = replacement
            rows.remove(at: eIdx)
        case (let pIdx?, nil):
            rows[pIdx] = replacement
        case (nil, let eIdx?):
            rows[eIdx] = replacement
        case (nil, nil):
            return nil
        }
        worktrees[repoID] = rows
        return PlaceholderSwapResult(typedName: typedName)
    }

    /// Create a repo-less scratch space and select it once the daemon confirms.
    func createScratch() {
        Task {
            do {
                let wt = try await daemonClient.createScratch()
                scratchWorktrees.append(wt)
                selectedWorktreeIDs = [wt.id]
                editingWorktreeID = wt.id
            } catch {
                logger.error("Failed to create scratch space: \(error)")
                handleConnectionError(error)
            }
        }
    }

    /// Delete a scratch space: closes its terminals and moves its folder to
    /// Trash. Handles both active rows (sidebar context menu) and archived
    /// rows (the Scratch detail pane's Archived tab) — the daemon-side
    /// `scratch.delete` works on either, so this clears the row from both
    /// client-side arrays. Error handling mirrors `archiveScratch`/
    /// `reviveScratch`: `handleConnectionError` drives the reconnect UI on a
    /// connection drop, and the alert makes non-connection failures visible.
    func deleteScratch(id: UUID) async {
        do {
            try await daemonClient.deleteScratch(worktreeID: id)
            scratchWorktrees.removeAll { $0.id == id }
            archivedScratchWorktrees.removeAll { $0.id == id }
        } catch {
            logger.error("Failed to delete scratch space: \(error)")
            handleConnectionError(error)
            showAlert("Couldn't delete scratch space: \(error.localizedDescription)", isError: true)
        }
    }

    /// Archive a scratch space: closes its terminals (folder untouched), moves
    /// it into the Scratch section's Archived tab. Runs the same synchronous
    /// cleanup as `archiveWorktree` — `removeArchivedWorktreeFromState` covers
    /// `scratchWorktrees` removal, selection cleanup (so the detail pane never
    /// flashes "Worktree not found"), the tombstone (so an in-flight poll can't
    /// re-append a ghost row), and terminal teardown. The `.worktreeArchived`
    /// delta repeats the removal for other clients (see
    /// `AppState+ArchiveTombstones.swift`).
    func archiveScratch(id: UUID) async {
        do {
            try await daemonClient.archiveScratch(worktreeID: id)
            removeArchivedWorktreeFromState(id: id)
            await refreshArchivedScratch()
        } catch {
            logger.error("Failed to archive scratch space: \(error)")
            handleConnectionError(error)
            showAlert("Couldn't archive scratch space: \(error.localizedDescription)", isError: true)
        }
    }

    /// Revive an archived scratch space. Surfaces a visible alert on failure —
    /// the daemon returns a real error (e.g. the folder was deleted out from
    /// under the archived row) that must not fail silently.
    func reviveScratch(id: UUID) async {
        do {
            try await daemonClient.reviveScratch(worktreeID: id)
            archivedScratchWorktrees.removeAll { $0.id == id }
            await refreshWorktrees()
        } catch {
            logger.error("Failed to revive scratch space: \(error)")
            handleConnectionError(error)
            showAlert("Couldn't revive scratch space: \(error.localizedDescription)", isError: true)
        }
    }

    /// Fetch archived scratch spaces (repo-less, `status == .archived`) for
    /// `ScratchArchivedView`. No pagination for v1 — scratch archive volume is
    /// expected to be low.
    func refreshArchivedScratch() async {
        do {
            archivedScratchWorktrees = try await daemonClient.listWorktrees(
                status: .archived, scratchOnly: true
            )
        } catch {
            logger.error("Failed to list archived scratch spaces: \(error)")
        }
    }

    /// List local + remote tracking branches for a repo, for the existing-
    /// branch picker on the sidebar `+` button. Rethrows so the picker can
    /// distinguish a fetch failure from a genuinely empty branch list.
    func listBranches(repoID: UUID) async throws -> [BranchInfo] {
        do {
            return try await daemonClient.listBranches(repoID: repoID)
        } catch {
            logger.error("Failed to list branches: \(error)")
            handleConnectionError(error)
            throw error
        }
    }

    /// List open PRs for a repo, for the branch picker's second load phase.
    /// Rethrows so callers can distinguish a fetch failure (keep showing
    /// branches, no PR pills) from a genuinely empty list.
    func listOpenPRs(repoID: UUID) async throws -> [OpenPRInfo] {
        do {
            return try await daemonClient.listOpenPRs(repoID: repoID)
        } catch {
            logger.error("Failed to list open PRs: \(error)")
            throw error
        }
    }

    /// Archive a worktree. Scratch-aware by construction: repo-less scratch
    /// spaces are delegated to `archiveScratch(id:)` so callers don't have to
    /// route per collection.
    ///
    /// The daemon routes them too now (`worktree.archive` dispatches a scratch
    /// row to the same `scratch.archive` body), so this branch is no longer
    /// what keeps the call from failing. It stays because the two client-side
    /// settlements differ: `archiveScratch` also refreshes the Scratch
    /// section's Archived tab, which the repo-worktree leg has no reason to do.
    func archiveWorktree(id: UUID, force: Bool = false) async {
        let worktree = findWorktree(id: id)
        if worktree?.isScratch == true {
            await archiveScratch(id: id)
            return
        }
        let worktreeName = worktree?.displayName ?? "worktree"
        do {
            try await daemonClient.archiveWorktree(id: id, force: force)
            removeArchivedWorktreeFromState(id: id)
            logger.info("Archived \(worktreeName)")
        } catch {
            logger.error("Failed to archive worktree: \(error)")
            showAlert("Archive failed: \(error)", isError: true)
        }
    }

    /// Re-run the worktree's `preSession` hook. The daemon spawns a
    /// non-focused tab and closes it on a clean exit; a failing hook leaves its
    /// tab open with the output and raises an `.error` notification. Running
    /// agents are untouched.
    ///
    /// The only thing to surface here is a refusal (no hook, already running,
    /// still creating) — hook FAILURE arrives later as a notification, not as
    /// an error on this call.
    func rerunPreSessionHook(worktreeID: UUID) async {
        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.rerunPreSessionHook(worktreeID: worktreeID, cols: size.cols, rows: size.rows)
            logger.info("Re-running pre-session hook for worktree \(worktreeID, privacy: .public)")
        } catch {
            logger.error("Failed to re-run pre-session hook: \(error)")
            showAlert("\(error)", isError: true)
        }
    }

    /// Revive an archived worktree.
    /// Mirrors `reviveWithSession`'s lingering-snapshot UX: keeps the row
    /// visible with a status pill until the user navigates away, instead
    /// of yanking them into the now-active worktree.
    func reviveWorktree(id: UUID) async {
        // Idempotency: see `reviveWithSession`. Concurrent invocations
        // would race the `.done` state to nil on the second call's error.
        guard revivingArchived[id] == nil else { return }
        // `archivedSnapshot` covers BOTH row sources. Resolving against
        // `archivedWorktrees` alone made this guard fail — silently, with no
        // RPC and no alert — for any row the user reached via search, i.e. any
        // row past the first loaded page.
        guard let snapshot = archivedSnapshot(id: id) else {
            logger.warning("reviveWorktree: no archived snapshot for \(id, privacy: .public)")
            return
        }
        revivingArchived[id] = .inFlight(snapshot: snapshot)
        advanceArchivedSelectionIfNeeded(worktreeID: id)

        do {
            let size = mainAreaTerminalSize()
            let revived = try await daemonClient.reviveWorktree(id: id, cols: size.cols, rows: size.rows)
            settleReviveState(id: id, snapshot: snapshot, revived: revived)
            recentlyArchivedWorktreeIDs.removeValue(forKey: id)
            // No refreshWorktrees() here: the sidebar refresh arrives via the
            // `.worktreeRevived` delta handler (AppState.swift handleDelta),
            // same as createWorktree relies on its delta.
            if let repoID = snapshot.repoID {
                await refreshArchivedWorktrees(repoID: repoID)
                await refreshReapRecords(repoID: repoID)
            }
        } catch {
            revivingArchived.removeValue(forKey: id)
            logger.error("Failed to revive worktree: \(error)")
            showAlert("Couldn't revive worktree: \(error.localizedDescription)", isError: true)
            handleConnectionError(error)
        }
    }

    /// Apply the revive RPC's returned worktree to `revivingArchived`.
    /// With a blocking `preSession` hook, `beginReviveWorktree` returns
    /// promptly with the row still `.creating` — marking `.done` then would
    /// show "Revived" in the archived view while the sidebar still says
    /// "Running setup…". Keep those entries `.inFlight`; the periodic
    /// `refreshWorktrees` poll promotes them via `promoteRevivedWorktrees`
    /// once the daemon reports the row `.active`.
    func settleReviveState(id: UUID, snapshot: Worktree, revived: Worktree) {
        guard revived.status != .creating else { return }
        revivingArchived[id] = .done(snapshot: snapshot)
    }

    /// Promote lingering `.inFlight` revive entries to `.done` once the
    /// daemon reports their worktree `.active` (i.e. the blocking
    /// `preSession` hook finished). A `.creating` observation never
    /// promotes — the hook is still running.
    func promoteRevivedWorktrees(observing fetched: [Worktree]) {
        for (id, state) in revivingArchived {
            guard case .inFlight(let snapshot) = state else { continue }
            guard fetched.contains(where: { $0.id == id && $0.status == .active }) else { continue }
            revivingArchived[id] = .done(snapshot: snapshot)
        }
    }

    /// Rename a worktree (repo-grouped or scratch).
    func renameWorktree(id: UUID, displayName: String) async {
        // Local-only iff the id is a client-side creation placeholder — the
        // daemon has never heard of it, so there is nothing to persist yet.
        // `createWorktree` carries the typed name onto the real daemon row
        // when it swaps the placeholder out (`replaceCreationPlaceholder`)
        // and issues the rename RPC for that row's id then. Daemon-known rows
        // take the RPC path regardless of status: a two-phase create leaves
        // the daemon row `.creating` for as long as its hooks run, and the
        // daemon rename handler has no status guard — gating on `.creating`
        // here would silently drop renames for that whole window.
        if pendingWorktreeIDs.contains(id) {
            applyLocalRename(id: id, displayName: displayName)
            return
        }
        // The id resolves nowhere (e.g. the placeholder was just swapped
        // away, or the row was archived): no-op instead of firing a doomed
        // RPC for a row that's already gone.
        guard let previous = findWorktree(id: id) else {
            logger.debug("renameWorktree: \(id, privacy: .public) resolves nowhere; skipping")
            return
        }
        // Optimistic: apply locally before any await so the UI reflects the
        // new name immediately, exactly once (callers must not pre-apply).
        applyLocalRename(id: id, displayName: displayName)
        do {
            if let override = renameRPCOverride {
                try await override(id, displayName)
            } else {
                try await daemonClient.renameWorktree(id: id, displayName: displayName)
            }
            // Re-apply after success: a poll snapshot captured before the
            // daemon row updated can land while the RPC was in flight and
            // revert the name for a full poll interval. Idempotent.
            applyLocalRename(id: id, displayName: displayName)
        } catch {
            logger.error("Failed to rename worktree: \(error)")
            // Roll back the optimistic apply and surface the failure —
            // silently reverting on the next poll hides that the daemon
            // still has the old name. Error handling mirrors
            // `archiveScratch`: `handleConnectionError` drives the reconnect
            // UI on a connection drop, the alert covers the rest.
            applyLocalRename(id: id, displayName: previous.displayName)
            handleConnectionError(error)
            showAlert("Rename failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Local rename applied to whichever collection holds the row: the
    /// repo-grouped `worktrees` dict, or `scratchWorktrees` for repo-less
    /// scratch spaces (which never appear in the dict). Idempotent — the
    /// rename paths re-apply it after RPC success to clobber any poll
    /// snapshot that reverted the name mid-flight. Owned by `renameWorktree`
    /// (optimistic pre-RPC apply + post-RPC re-apply + failure rollback) and
    /// `createWorktree`'s carried-rename persist block, so callers don't
    /// have to compensate per collection.
    private func applyLocalRename(id: UUID, displayName: String) {
        for repoID in worktrees.keys {
            if let idx = worktrees[repoID]?.firstIndex(where: { $0.id == id }) {
                worktrees[repoID]?[idx].displayName = displayName
            }
        }
        if let idx = scratchWorktrees.firstIndex(where: { $0.id == id }) {
            scratchWorktrees[idx].displayName = displayName
        }
    }

    // MARK: - Archived Worktrees

    /// Active-worktree path for deep-link navigation. Caller is responsible
    /// for verifying the id resolves via `findWorktree(id:)` first (which
    /// covers both repo-grouped worktrees and scratch spaces). When
    /// `terminalID` is non-nil, also switches the worktree's active tab to
    /// the one rendering that terminal (live transcript or terminal pane);
    /// silently falls back to current selection when no tab matches.
    @MainActor
    func navigateToActiveWorktree(_ id: UUID, terminalID: UUID? = nil) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = [id]
        // Expand the containing repo so the row is part of the rendered list
        // before we ask the sidebar to scroll to it.
        expandRepoContaining(worktreeID: id)
        pendingScrollToWorktreeID = id
        // Switch to the originating terminal's tab when one matches. Both
        // `.terminal` and `.liveTranscript` panes count as matches — clicking
        // the banner should land the user on whichever surface the worktree
        // currently exposes for that terminal. If neither match exists (e.g.
        // the terminal was deleted, or surfaced only via the pinned dock),
        // we silently keep whatever tab was active before.
        if let terminalID, let arr = tabs[id] {
            if let idx = arr.firstIndex(where: { tab in
                switch tab.content {
                case .terminal(let tid): return tid == terminalID
                case .liveTranscript(_, let tid): return tid == terminalID
                default: return false
                }
            }) {
                setActiveTab(worktreeID: id, tabIndex: idx)
            }
        }
        // Only foreground when the AppKit run loop is live — `NSApp` is nil
        // under unit tests, which would crash on the implicit unwrap.
        if NSApplication.shared.isRunning {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Archived-worktree path for deep-link navigation. Async — issues an RPC
    /// to find the worktree across all archived ones, then navigates to the
    /// archive entry immediately and shows a brief auto-dismissing notice
    /// explaining that the target is archived
    /// (spec: 2026-07-13-deeplink-archived-toast-design.md).
    /// Lookup failures and unknown UUIDs surface as error toasts (previously
    /// silent).
    @MainActor
    func navigateToArchivedWorktree(_ id: UUID) async {
        // Request-generation guard (F1). Two deep links (A then B) can have
        // overlapping lookups that resolve out of order; without this, A's
        // late resolution would replace B's toast (even one the user
        // hover-cancelled) and navigate to A. Stamp a fresh token now and
        // drop any resolution that isn't the newest request. Mirrors the
        // `revivingArchived[id] == nil` re-entrancy guard used for revive.
        let myRequestID = UUID()
        deepLinkRequestID = myRequestID

        let archived: [Worktree]
        do {
            if let override = archivedLookupOverride {
                archived = try await override(id)
            } else {
                archived = try await daemonClient.listWorktrees(
                    repoID: nil, status: .archived, includeSessionCounts: false
                )
            }
        } catch {
            // Drop a stale failure before it clobbers a newer link's toast.
            guard deepLinkRequestID == myRequestID else { return }
            logger.error("Deep-link archived lookup failed: \(error.localizedDescription)")
            showErrorToast("Couldn't look up the worktree: \(error.localizedDescription)")
            return
        }

        // Out-of-order RPC resolution: a newer deep link superseded this one
        // while its lookup was in flight. Drop this stale resolution before it
        // touches any toast/navigation state. (The toastID mechanism already
        // covers post-toast staleness; this guard only covers the
        // RPC-resolution window.)
        guard deepLinkRequestID == myRequestID else { return }

        guard let wt = archived.first(where: { $0.id == id }) else {
            logger.warning("Deep link references unknown worktree \(id.uuidString, privacy: .public)")
            showErrorToast("Worktree not found — it may have been deleted.")
            return
        }
        // Archived flows are repo-only — a scratch space has no archived view to deep-link into.
        guard let rid = wt.repoID else {
            dismissToast()
            return
        }

        // Navigate immediately, then show a brief auto-dismissing notice so
        // landing in the archive view is explained rather than surprising.
        showTransientToast(
            "“\(wt.displayName)” is archived — showing its archive entry",
            style: .notice
        )
        performArchivedNavigation(worktreeID: id, repoID: rid, archived: archived)
    }

    /// The navigation tail: select the repo, populate its archived rows, and
    /// flash-highlight the target. Runs immediately once the lookup resolves.
    @MainActor
    private func performArchivedNavigation(worktreeID: UUID, repoID: UUID, archived: [Worktree]) {
        selectedWorktreeIDs = []
        selectedRepoID = repoID
        selectedScratchSection = false
        selectedRemoteProvider = nil
        selectedRemoteSession = nil
        archivedWorktrees[repoID] = archived.filter { $0.repoID == repoID }
        archivedWorktreesHasMore[repoID] = false
        highlightedArchivedWorktreeID = worktreeID
        // Reconcile with fresh data (F2). The captured `archived` snapshot can
        // be minutes old when the user hover-cancels and clicks the CTA later,
        // leaving ghost rows for since-deleted/revived worktrees. The refresh
        // also restores the per-row session-count enrichment the fast
        // deep-link lookup skips (includeSessionCounts: false).
        //
        // Suppressed when the test seam is active: `archivedLookupOverride`
        // replaces the archived-lookup daemon roundtrip, and this reconcile is
        // a *second* daemon roundtrip that tests neither provide nor want
        // touching the real daemon (CLAUDE.md: tests must not touch ~/tbd).
        if archivedLookupOverride == nil {
            Task { await self.refreshArchivedWorktrees(repoID: repoID) }
        }
    }

    /// Public entry point for deep-link navigation. Synchronous fast path
    /// for active worktrees; falls through to the async archived path on a
    /// miss. When `terminalID` is non-nil, the active-worktree path also
    /// switches to the originating tab. The archived path silently drops
    /// `terminalID` — archived worktrees have no live terminals to focus.
    @MainActor
    func navigateToWorktree(_ id: UUID, terminalID: UUID? = nil) {
        // Cold-start guard: a tbd:// click can arrive between AppState.init()
        // and the daemon RPC populating `worktrees`. If we fall through to
        // archived lookup now we'll miss real active worktrees. Buffer
        // instead and let connectAndLoadInitialState drain at the end.
        if !isInitialStateLoaded {
            pendingDeepLinkID = id
            pendingDeepLinkTerminalID = terminalID
            return
        }

        let activeMatch = findWorktree(id: id) != nil
        if activeMatch {
            navigateToActiveWorktree(id, terminalID: terminalID)
        } else {
            // Foreground the app *before* the async lookup so the progress
            // toast is actually visible (guarded: NSApp is nil under tests).
            if NSApplication.shared.isRunning {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            showToast(Toast(id: UUID(), message: "Looking for worktree…", style: .progress))
            Task { await navigateToArchivedWorktree(id) }
        }
    }

    /// Select a repo to show its archived worktrees in the content pane.
    func selectRepo(id: UUID) {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = []
        selectedRepoID = id
        selectedScratchSection = false
        selectedRemoteProvider = nil
        selectedRemoteSession = nil
        Task { await refreshArchivedWorktrees(repoID: id) }
    }

    /// Reveal the repo's pre-session hook editor: select the repo, switch its
    /// detail pane to Settings, scroll to and focus the hook's editor.
    ///
    /// Ordering matters. `selectRepo` clears the worktree/scratch selection so
    /// `ContentView` swaps in `RepoDetailView`; the reveal is posted after, and
    /// survives until that view consumes it — whether it mounts fresh (onAppear)
    /// or is reused from another repo (onChange).
    func revealPreSessionHookEditor(repoID: UUID) {
        selectRepo(id: repoID)
        repoDetailReveal = .preSessionHook(repoID: repoID)
    }

    /// User-facing label for the repo-less scratch section. Single source for
    /// the sidebar section header (`ScratchSectionView`) and the jump menu's
    /// pseudo-repo label (`JumpMenuController.worktreeSnapshots`).
    nonisolated static let scratchSectionLabel = "Scratch"

    /// Select the "Scratch" sidebar section header to show `ScratchDetailView`
    /// (Archived/Instructions/Settings tabs) in the content pane. Mirrors
    /// `selectRepo(id:)`; no `NavigationEntry`/back-forward integration for v1
    /// (documented scope cut — the Scratch section header has no natural UUID
    /// identity for `List`'s native selection or the navigation history's
    /// worktree/repo entries to key off).
    func selectScratchSection() {
        highlightedArchivedWorktreeID = nil
        selectedWorktreeIDs = []
        selectedRepoID = nil
        selectedScratchSection = true
        selectedRemoteProvider = nil
        selectedRemoteSession = nil
    }

    static let archivedPageSize = 50

    /// Fetch archived worktrees for a repo, preserving any pages the user has
    /// already loaded (re-fetches up to `max(currentCount, pageSize)` items).
    func refreshArchivedWorktrees(repoID: UUID) async {
        let plan = ArchivedRefreshPlan(
            currentCount: archivedWorktrees[repoID]?.count ?? 0,
            pageSize: Self.archivedPageSize
        )
        do {
            let archived = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: plan.fetchCount
            )
            archivedWorktrees[repoID] = archived
            archivedWorktreesHasMore[repoID] = plan.hasMore(fetched: archived.count)
            ensureArchivedSelectionValid(repoID: repoID)
        } catch {
            logger.error("Failed to list archived worktrees: \(error)")
        }
        // Re-run any active search so a revive/archive doesn't leave stale
        // search rows on screen (the search set is fetched separately and is
        // not touched by the refetch above).
        await refreshArchivedSearch(repoID: repoID)
    }

    // MARK: - Archived row sources

    /// Union of the two sources the archived UI renders from, de-duplicated by
    /// id preferring `loaded` (which every `refreshArchivedWorktrees` re-fetches
    /// and is therefore the fresher of the two).
    ///
    /// Search results are a genuinely SECOND row source: the whole point of the
    /// daemon-side `nameQuery` filter is surfacing matches from pages
    /// `archivedWorktrees` never loaded. Any lookup written against the loaded
    /// pages alone silently fails for those rows — which is how Revive came to
    /// no-op on exactly the row a user searched to find. Keep every archived-row
    /// lookup routed through here rather than re-deriving the union.
    nonisolated static func mergeArchivedSnapshots(
        loaded: [Worktree],
        searchResults: [Worktree]
    ) -> [Worktree] {
        var seen = Set(loaded.map(\.id))
        var merged = loaded
        for wt in searchResults where seen.insert(wt.id).inserted {
            merged.append(wt)
        }
        return merged
    }

    /// Every archived snapshot the UI can currently render for `repoID`.
    func archivedSnapshots(repoID: UUID) -> [Worktree] {
        Self.mergeArchivedSnapshots(
            loaded: archivedWorktrees[repoID] ?? [],
            searchResults: archivedSearchResults[repoID]?.worktrees ?? []
        )
    }

    /// Resolve one archived snapshot by id across every repo — for callers
    /// (the revive paths) that hold a row id but not its repo.
    func archivedSnapshot(id: UUID) -> Worktree? {
        Self.mergeArchivedSnapshots(
            loaded: archivedWorktrees.values.flatMap { $0 },
            searchResults: archivedSearchResults.values.flatMap(\.worktrees)
        ).first { $0.id == id }
    }

    // MARK: - Archived-worktree search

    /// Re-fetch the active search after the archived set changed, preserving the
    /// pages the user already pulled in — the same invariant
    /// `refreshArchivedWorktrees` maintains for the unsearched list, via the
    /// same `ArchivedRefreshPlan`.
    ///
    /// Calling plain `searchArchivedWorktrees` here instead would always refetch
    /// page 0 and replace the stored results, silently collapsing Load
    /// More–accumulated search pages back to the first 50 — triggered by the
    /// feature's own primary action (revive), plus `selectRepo`, deep-link
    /// archived navigation, and back/forward restore.
    ///
    /// Keys off the query the stored results ANSWER, not the in-flight one: if
    /// a newer search is already in flight its own response is the right answer
    /// and this refresh has nothing useful to add.
    func refreshArchivedSearch(repoID: UUID) async {
        guard let current = archivedSearchResults[repoID] else { return }
        let query = current.query
        let plan = ArchivedRefreshPlan(
            currentCount: current.worktrees.count,
            pageSize: Self.archivedPageSize
        )
        do {
            let matches = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: plan.fetchCount,
                nameQuery: query
            )
            // Drop the response if the user has since typed a different query
            // (or cleared the search) — it answers a question nobody is asking.
            guard archivedSearchQuery[repoID] == query else { return }
            archivedSearchResults[repoID] = ArchivedSearchResults(
                query: query,
                worktrees: matches,
                hasMore: plan.hasMore(fetched: matches.count)
            )
        } catch {
            logger.error("Failed to refresh archived search: \(error)")
        }
    }

    /// Fetch the first page of archived worktrees matching `query` for a repo.
    ///
    /// The filter runs in the daemon's SQL (`nameQuery`), not client-side, so
    /// matches in pages the user hasn't loaded still show up — and pagination
    /// continues to page over the *matching* set (`loadMoreArchivedSearchResults`).
    /// A blank query clears the search instead of fetching.
    func searchArchivedWorktrees(repoID: UUID, query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearArchivedSearch(repoID: repoID)
            return
        }
        // Stamp the in-flight query BEFORE awaiting so a later keystroke's
        // search supersedes this one; the post-await checks drop the stale
        // response rather than letting it overwrite newer results.
        //
        // The previous query's RESULTS are deliberately left in place: the view
        // keys off `ArchivedSearchResults.query`, sees it no longer matches
        // what's typed, and falls back to the client-side preview on its own.
        archivedSearchQuery[repoID] = trimmed
        archivedSearchFailed[repoID] = false
        do {
            let matches = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: Self.archivedPageSize,
                nameQuery: trimmed
            )
            guard archivedSearchQuery[repoID] == trimmed else { return }
            archivedSearchResults[repoID] = ArchivedSearchResults(
                query: trimmed,
                worktrees: matches,
                hasMore: matches.count >= Self.archivedPageSize
            )
        } catch {
            logger.error("Failed to search archived worktrees: \(error)")
            // Only flag the failure if this is still the query the user is
            // waiting on — a superseded search's failure is not their problem.
            guard archivedSearchQuery[repoID] == trimmed else { return }
            archivedSearchFailed[repoID] = true
        }
    }

    /// Load the next page of archived search results, appending to the existing
    /// ones. Mirrors `loadMoreArchivedWorktrees`, including its concurrent-call
    /// guard and its "did the list shift under us" append check.
    func loadMoreArchivedSearchResults(repoID: UUID) async {
        guard isLoadingMoreArchivedSearch[repoID] != true else { return }
        // Only a SETTLED result set can be paged: the stored rows must answer
        // the query that is still in flight/current, or the next page would be
        // offset into a different search's answer.
        guard let current = archivedSearchResults[repoID],
              archivedSearchQuery[repoID] == current.query else { return }
        isLoadingMoreArchivedSearch[repoID] = true
        defer { isLoadingMoreArchivedSearch[repoID] = false }

        let currentCount = current.worktrees.count
        do {
            let more = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: Self.archivedPageSize, offset: currentCount,
                nameQuery: current.query
            )
            // Drop the page if the stored results were replaced or extended
            // while it was in flight (query changed, or a refresh re-ran the
            // search) — it belongs to a result set that no longer exists.
            guard let latest = archivedSearchResults[repoID],
                  latest.query == current.query,
                  latest.worktrees.count == currentCount else { return }
            archivedSearchResults[repoID] = ArchivedSearchResults(
                query: current.query,
                worktrees: latest.worktrees + more,
                hasMore: more.count >= Self.archivedPageSize
            )
        } catch {
            logger.error("Failed to load more archived search results: \(error)")
        }
    }

    /// Drop all search state for a repo — called when the query goes empty, so
    /// the view falls back to the unsearched `archivedWorktrees` pages.
    func clearArchivedSearch(repoID: UUID) {
        archivedSearchQuery.removeValue(forKey: repoID)
        archivedSearchResults.removeValue(forKey: repoID)
        archivedSearchFailed.removeValue(forKey: repoID)
    }

    /// Fetch orphan-GC reap records for a repo (History → Reclaimed).
    func refreshReapRecords(repoID: UUID) async {
        guard let repoPath = repos.first(where: { $0.id == repoID })?.path else { return }
        do {
            reapRecords[repoID] = try await daemonClient.listReapRecords(repoPath: repoPath)
        } catch {
            logger.error("Failed to list reap records: \(error)")
        }
    }

    /// Restore a swept `ReapRecord` (agent worktrees only) and refresh the
    /// repo's list so the row disappears from Reclaimed once restored.
    func restoreReap(_ record: ReapRecord, repoID: UUID) async {
        do {
            try await daemonClient.restoreReap(recordID: record.id)
            await refreshReapRecords(repoID: repoID)
            await refreshWorktrees()
        } catch {
            logger.error("Failed to restore reap record \(record.id, privacy: .public): \(error)")
            showAlert("Couldn't restore worktree: \(error.localizedDescription)", isError: true)
            handleConnectionError(error)
        }
    }

    /// Load the next page of archived worktrees, appending to the existing list.
    func loadMoreArchivedWorktrees(repoID: UUID) async {
        guard isLoadingMoreArchived[repoID] != true else { return }
        isLoadingMoreArchived[repoID] = true
        defer { isLoadingMoreArchived[repoID] = false }

        let currentCount = archivedWorktrees[repoID]?.count ?? 0
        do {
            let more = try await daemonClient.listWorktrees(
                repoID: repoID, status: .archived,
                limit: Self.archivedPageSize, offset: currentCount
            )
            if archivedWorktrees[repoID]?.count == currentCount {
                archivedWorktrees[repoID, default: []].append(contentsOf: more)
            }
            archivedWorktreesHasMore[repoID] = more.count >= Self.archivedPageSize
        } catch {
            logger.error("Failed to load more archived worktrees: \(error)")
        }
    }

    /// Ensure `selectedArchivedWorktreeIDs[repoID]` points to a row that
    /// actually exists in the archived list (or in `revivingArchived` for that
    /// repo). If unset or stale, set it to the most-recently-archived row.
    /// Also kicks off the session fetch for the newly-selected worktree.
    ///
    /// A deliberate Reclaimed-row selection (`selectedReapRecordIDs[repoID]`)
    /// must not be stolen by this fallback maintenance — see
    /// `ArchivedWorktreesView`/`ReclaimedSectionView` for the UI side of the
    /// mutual-exclusivity contract. `internal` (not `private`) so tests can
    /// drive it directly.
    func ensureArchivedSelectionValid(repoID: UUID) {
        guard selectedReapRecordIDs[repoID] == nil else { return }

        let archived = (archivedWorktrees[repoID] ?? [])
        let lingering = revivingArchived.values
            .map(\.snapshot)
            .filter { $0.repoID == repoID }
        // Validity spans BOTH row sources: a selection on a search-only row is
        // legitimate, and judging it stale against the loaded pages alone would
        // silently re-point the detail pane at the most recent loaded row on
        // the next refresh. The fallback PICK below deliberately stays on the
        // loaded set — a loaded row is always a row we still hold.
        let allIDs = Set(
            archivedSnapshots(repoID: repoID).map(\.id) + lingering.map(\.id)
        )

        let current = selectedArchivedWorktreeIDs[repoID]
        let needsNew = current == nil || !allIDs.contains(current!)
        guard needsNew else { return }

        let mostRecent = archived
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            .first
        if let pick = mostRecent {
            selectArchivedWorktree(pick.id, repoID: repoID)
            Task { await fetchSessions(worktreeID: pick.id) }
        } else {
            selectArchivedWorktree(nil, repoID: repoID)
        }
    }

    /// Select an archived-worktree row for `repoID`, clearing any Reclaimed
    /// (reap-record) selection for the same repo — the two are mutually
    /// exclusive per repo. Pass `nil` to clear the archived selection.
    func selectArchivedWorktree(_ id: UUID?, repoID: UUID) {
        if let id {
            selectedArchivedWorktreeIDs[repoID] = id
        } else {
            selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
        }
        selectedReapRecordIDs.removeValue(forKey: repoID)
    }

    /// Select a Reclaimed (reap-record) row for `repoID`, clearing any
    /// archived-worktree selection for the same repo. Mirrors
    /// `selectArchivedWorktree(_:repoID:)`. Pass `nil` to clear the reap selection.
    func selectReapRecord(_ id: UUID?, repoID: UUID) {
        if let id {
            selectedReapRecordIDs[repoID] = id
        } else {
            selectedReapRecordIDs.removeValue(forKey: repoID)
        }
        selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
    }

    // MARK: - Reorder top-level

    /// Reorder ONLY the top-level worktrees of a repo (parentWorktreeID == nil),
    /// triggered by SwiftUI `.onMove` whose indices index the top-level ForEach.
    /// Nested children stay attached to their parents — only top-level sortOrders change.
    /// Updates locally first (optimistic), then persists via RPC; rolls back on error.
    func reorderTopLevelWorktrees(repoID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        let previous = worktrees[repoID]
        var rows = (worktrees[repoID] ?? [])
        // Snapshot the top-level order BEFORE the move (matches the ForEach).
        var topLevel = rows
            .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        logger.debug("reorderTopLevel BEFORE: \(topLevel.map(\.displayName).joined(separator: " | "), privacy: .public) source=\(Array(source), privacy: .public) destination=\(destination, privacy: .public)")
        // guard: source/destination can outlive the snapshot they were captured against
        if topLevel.isEmpty || source.contains(where: { $0 >= topLevel.count }) || destination > topLevel.count {
            logger.warning("reorderTopLevel skipped: stale indices (topLevel.count=\(topLevel.count, privacy: .public) source=\(Array(source), privacy: .public) destination=\(destination, privacy: .public))")
            return
        }
        // Apply the swap to derive the new top-level order.
        topLevel.move(fromOffsets: source, toOffset: destination)
        logger.debug("reorderTopLevel AFTER: \(topLevel.map(\.displayName).joined(separator: " | "), privacy: .public)")

        // Optimistic local update: reassign sortOrders for the new top-level order.
        for (i, wt) in topLevel.enumerated() {
            if let idx = rows.firstIndex(where: { $0.id == wt.id }) {
                rows[idx].sortOrder = i
            }
        }
        worktrees[repoID] = rows

        // Persist via the bulk reorder RPC. Daemon renumbers all listed worktrees
        // to contiguous sortOrders matching the new top-level order, avoiding
        // gappy/non-contiguous values from prior individual moves.
        let orderedIDs = topLevel.map(\.id)
        Task {
            do {
                logger.debug("RPC worktree.reorder ids=\(orderedIDs.map { $0.uuidString.prefix(8) }.joined(separator: ","), privacy: .public)")
                try await daemonClient.reorderWorktrees(repoID: repoID, worktreeIDs: orderedIDs)
            } catch {
                logger.error("reorderTopLevelWorktrees RPC failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.worktrees[repoID] = previous }
            }
        }
    }

    // MARK: - Move (nested worktrees)

    /// Move a worktree to a new parent (or top-level) and sortOrder.
    /// Optimistic local update; rolls back on RPC error.
    func moveWorktree(id: UUID, newParentID: UUID?, newSortOrder: Int) {
        let snapshot = worktrees
        if let repoID = repoIDForWorktree(id), var rows = worktrees[repoID] {
            if let idx = rows.firstIndex(where: { $0.id == id }) {
                rows[idx].parentWorktreeID = newParentID
                rows[idx].sortOrder = newSortOrder
                worktrees[repoID] = rows
            }
        }
        Task {
            do {
                try await daemonClient.moveWorktree(
                    worktreeID: id, newParentID: newParentID, newSortOrder: newSortOrder
                )
            } catch {
                logger.error("moveWorktree failed: \(error.localizedDescription)")
                await MainActor.run { self.worktrees = snapshot }
            }
        }
    }

    /// All worktrees whose parentWorktreeID == parentID, across all repos, in sortOrder.
    /// Only active or creating worktrees are returned.
    /// Intentionally repo-scoped (dict-only, not `allWorktrees`): scratch
    /// spaces can never be children — nesting requires a `repoID`
    /// (`createNestedWorktree` guards on it), and `createScratch` never sets
    /// `parentWorktreeID` — so no child ever lives outside the dict.
    ///
    /// Served from the memoized `childrenIndex()` (`AppState.swift`), which the
    /// `worktrees` `didSet` invalidates. The sidebar calls this once per row
    /// while rendering, so recomputing the flatMap/filter/sort per call made a
    /// render pass O(N²).
    func children(of parentID: UUID) -> [Worktree] {
        childrenIndex()[parentID] ?? []
    }

    /// Find a worktree by id across all repos, including repo-less scratch
    /// spaces. Scratch spaces live only in `scratchWorktrees`, never in the
    /// repo-grouped `worktrees` dict, so a lookup that consulted `worktrees`
    /// alone returned nil for a selected scratch space — surfacing as
    /// "Worktree not found" the instant `createScratch()` auto-selected its
    /// freshly created row (see `SingleWorktreeView`).
    func findWorktree(id: UUID) -> Worktree? {
        for (_, rows) in worktrees {
            if let wt = rows.first(where: { $0.id == id }) { return wt }
        }
        return scratchWorktrees.first(where: { $0.id == id })
    }

    /// Resolve the effective auto-archive-on-merge setting for a worktree.
    /// Returns the per-worktree override when explicitly set; otherwise falls
    /// back to the global default (`autoArchiveOnMergeDefault`).
    func effectiveAutoArchive(for worktree: Worktree) -> Bool {
        worktree.autoArchiveOnMerge ?? autoArchiveOnMergeDefault
    }

    /// Set the per-worktree auto-archive override and update local state optimistically.
    func setAutoArchive(worktreeID: UUID, enabled: Bool) async {
        do {
            try await daemonClient.setWorktreeAutoArchive(id: worktreeID, enabled: enabled)
            // Optimistic local update so the toolbar reflects it immediately.
            for (key, list) in worktrees {
                if let idx = list.firstIndex(where: { $0.id == worktreeID }) {
                    worktrees[key]?[idx].autoArchiveOnMerge = enabled
                    break
                }
            }
        } catch {
            logger.error("Failed to set auto-archive: \(error, privacy: .public)")
            showAlert("Couldn't update auto-archive: \(error.localizedDescription)", isError: true)
        }
    }

    /// Pin or unpin a worktree for the sidebar dock.
    ///
    /// No optimistic local update, deliberately: the dock reflects daemon state,
    /// and the daemon stamps `pinnedAt` (so pin ORDER is server-assigned). A
    /// guessed local timestamp could order the dock differently from the next
    /// refresh. A failed pin therefore visibly does not take, which is honest.
    func setPinned(worktreeID: UUID, pinned: Bool) async {
        do {
            try await daemonClient.setWorktreePin(id: worktreeID, pinned: pinned)
            await refreshWorktrees()
        } catch {
            logger.error("Failed to set worktree pin: \(error, privacy: .public)")
            showAlert("Couldn't update pin: \(error.localizedDescription)", isError: true)
        }
    }

    /// Reorder the sidebar dock's pinned worktrees, triggered by SwiftUI
    /// `.onMove` whose indices address the dock's PINNED ROOTS (the outer
    /// ForEach), not the flattened row list.
    ///
    /// Optimistic, unlike `setPinned`: the client knows the entire resulting
    /// order rather than depending on a daemon-assigned timestamp, so the row
    /// can land under the cursor immediately and roll back if the RPC fails.
    func reorderPins(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Snapshot BOTH collections — pinned worktrees span repo-keyed
        // `worktrees` and repo-less `scratchWorktrees`, so a rollback that
        // restored only one would leave the other half mutated.
        let previousWorktrees = worktrees
        let previousScratch = scratchWorktrees

        // `children: { _ in [] }` collapses every subtree, which is exactly the
        // root list the outer ForEach renders — so the indices line up by
        // construction.
        let currentRoots = PinnedDockContent
            .rows(allWorktrees: allWorktrees, selectedIDs: [], children: { _ in [] })
            .map(\.worktree.id)

        guard let newOrder = PinnedDockReorder.reordered(
            roots: currentRoots, fromOffsets: source, toOffset: destination) else {
            logger.warning("reorderPins skipped: stale indices (roots=\(currentRoots.count, privacy: .public) source=\(Array(source), privacy: .public) destination=\(destination, privacy: .public))")
            return
        }

        // Optimistic local update: assign contiguous orders in the new sequence.
        for (index, id) in newOrder.enumerated() {
            applyPinSortOrder(index, to: id)
        }

        Task {
            do {
                try await daemonClient.reorderPinnedWorktrees(worktreeIDs: newOrder)
            } catch {
                logger.error("reorderPins RPC failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.worktrees = previousWorktrees
                    self.scratchWorktrees = previousScratch
                }
            }
        }
    }

    /// Write `pinSortOrder` into whichever collection holds this worktree:
    /// a pinned worktree can be a repo-keyed row or a repo-less scratch space,
    /// and only one of the two ever holds it.
    private func applyPinSortOrder(_ order: Int, to id: UUID) {
        for (key, list) in worktrees {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                worktrees[key]?[idx].pinSortOrder = order
                return
            }
        }
        if let idx = scratchWorktrees.firstIndex(where: { $0.id == id }) {
            scratchWorktrees[idx].pinSortOrder = order
        }
    }

    /// Resolve the effective auto-hibernate-on-merge setting for a worktree.
    /// Returns the per-worktree override when explicitly set; otherwise falls
    /// back to the global default (`autoHibernateOnMergeDefault`).
    func effectiveAutoHibernate(for worktree: Worktree) -> Bool {
        worktree.autoHibernateOnMerge ?? autoHibernateOnMergeDefault
    }

    /// Set the per-worktree auto-hibernate override and update local state optimistically.
    func setAutoHibernate(worktreeID: UUID, enabled: Bool) async {
        do {
            try await daemonClient.setWorktreeAutoHibernate(id: worktreeID, enabled: enabled)
            // Optimistic local update so the toolbar reflects it immediately.
            for (key, list) in worktrees {
                if let idx = list.firstIndex(where: { $0.id == worktreeID }) {
                    worktrees[key]?[idx].autoHibernateOnMerge = enabled
                    break
                }
            }
        } catch {
            logger.error("Failed to set auto-hibernate: \(error, privacy: .public)")
            showAlert("Couldn't update auto-hibernate: \(error.localizedDescription)", isError: true)
        }
    }

    /// Repo ID of the repo containing the given worktree, if any.
    private func repoIDForWorktree(_ id: UUID) -> UUID? {
        for (rid, rows) in worktrees where rows.contains(where: { $0.id == id }) {
            return rid
        }
        return nil
    }

    // MARK: - Keyboard Shortcut Actions

    /// All worktrees in **visual sidebar order**: each repo's main row (if any),
    /// then a depth-first walk of top-level worktrees followed by their
    /// descendants. Matches what the user sees in the sidebar so cmd+N keyboard
    /// shortcuts (via `selectWorktreeByIndex`) land on the right row.
    ///
    /// `sortOrder` is scoped per sibling group (top-level OR children-of-X), so
    /// a flat repo-wide sort by `sortOrder` would collapse two namespaces
    /// together and put nested children with `sortOrder: 0` ahead of top-level
    /// rows with `sortOrder: 1+`.
    var allWorktreesOrdered: [Worktree] {
        var result: [Worktree] = []
        for repo in repos {
            let inRepo = worktrees[repo.id] ?? []
            // Main row first (if present in this repo).
            if let main = inRepo.first(where: { $0.status == .main }) {
                result.append(main)
            }
            // Top-level active/creating worktrees in this repo, sorted by sortOrder.
            let topLevel = inRepo
                .filter { ($0.status == .active || $0.status == .creating) && $0.parentWorktreeID == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            for wt in topLevel {
                appendSubtree(wt, depth: 0, into: &result)
            }
        }
        return result
    }

    /// Depth-first append: the worktree itself, then its children (across all
    /// repos, since a child can have a different `repoID` from its parent),
    /// recursively. Used by `allWorktreesOrdered` to match sidebar order.
    /// Caps recursion at 50 to mirror `WorktreeSubtreeView.kMaxSubtreeDepth`
    /// in case a cyclic parent chain ever makes it into the in-memory state
    /// (DB-side cycle guards make this unlikely, but the keyboard-nav path
    /// shouldn't blow the stack while the renderer gracefully degrades).
    private func appendSubtree(_ wt: Worktree, depth: Int, into result: inout [Worktree]) {
        result.append(wt)
        guard depth < 50 else { return }
        for child in children(of: wt.id) {
            appendSubtree(child, depth: depth + 1, into: &result)
        }
    }

    /// The repo ID of the first selected worktree (used as "focused repo").
    var focusedRepoID: UUID? {
        guard let firstSelected = selectedWorktreeIDs.first else { return nil }
        for (repoID, wts) in worktrees {
            if wts.contains(where: { $0.id == firstSelected }) {
                return repoID
            }
        }
        return nil
    }

    /// Create a new worktree in the focused repo (or first repo if none focused).
    func newWorktreeInFocusedRepo() {
        let repoID = focusedRepoID ?? repos.first?.id
        guard let repoID else { return }
        createWorktree(repoID: repoID)
    }

    /// Resolve the archive target for a pre-resolved selection (the caller
    /// passes `selectedWorktreeIDs.first.flatMap(findWorktree)`). This seam
    /// only decides refuse-vs-proceed — `archiveWorktree(id:)` is
    /// scratch-aware and self-routes scratch rows to the `scratch.archive`
    /// RPC. Pure so the branches are unit-testable without a daemon.
    /// Returns `nil` when:
    /// - nothing is selected, or
    /// - the selected ID is stale/unknown (`findWorktree` returned nil — no
    ///   doomed RPC + error alert for a row that's already gone), or
    /// - the selected repo worktree is the main branch or still creating
    ///   (those refuse the archive shortcut; scratch rows always proceed —
    ///   the daemon creates them `.active`, never `.main`/`.creating`).
    nonisolated static func archiveShortcutRoute(
        selectedWorktree: Worktree?
    ) -> UUID? {
        guard let wt = selectedWorktree else { return nil }
        if wt.isScratch { return wt.id }
        // Don't archive the main branch worktree (or one still creating)
        if wt.status == .main || wt.status == .creating { return nil }
        return wt.id
    }

    /// Archive the first selected worktree (refuses main worktrees). Scratch
    /// routing happens inside `archiveWorktree(id:)` — same as the row
    /// context menu's Archive action.
    func archiveSelectedWorktree() {
        guard let id = Self.archiveShortcutRoute(
            selectedWorktree: selectedWorktreeIDs.first.flatMap { findWorktree(id: $0) }
        ) else { return }
        Task { await archiveWorktree(id: id) }
    }

    /// Select a worktree by its index in the sidebar order.
    func selectWorktreeByIndex(_ index: Int) {
        let ordered = allWorktreesOrdered
        guard index >= 0, index < ordered.count else { return }
        selectedWorktreeIDs = [ordered[index].id]
    }

    /// Placeholder: new terminal tab in the selected worktree.
    func newTerminalTab() {
        guard let worktreeID = selectedWorktreeIDs.first else { return }
        Task {
            await createTerminal(worktreeID: worktreeID)
        }
    }

    /// Backward-compatible wrapper for callers that still ask to close the
    /// current terminal tab. The close target now comes only from focus.
    func closeTerminalTab() {
        closeFocusedTab()
    }
}

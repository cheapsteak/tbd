import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The pure halves of the `tbd remote` group: address resolution, the receipt
/// wording, and the retained-transcript table.
///
/// The commands themselves need a live daemon, so the last hop — `run()` — is
/// out of reach here; everything it decides before the socket opens is not.
@Suite("tbd remote")
struct RemoteCommandsTests {
    private func session(provider: String, id: String) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, title: id, state: .running),
            gone: false, dismissed: false, lastSeen: Date())
    }

    /// Built through `Worktree`'s own initializer with a real
    /// `WorktreeLocation`, so `providerBinding` is derived the way production
    /// derives it rather than stamped by hand.
    private func remoteWorktree(
        id: UUID = UUID(), name: String, displayName: String? = nil,
        provider: String?, sessionID: String?
    ) -> Worktree {
        let location: WorktreeLocation = provider.flatMap { p in
            sessionID.map { WorktreeLocation.remote(provider: p, sessionID: $0) }
        } ?? .local
        return Worktree(
            id: id, repoID: UUID(), name: name, displayName: displayName ?? name,
            branch: "b", path: location.storagePath ?? "/tmp/acme/\(name)",
            tmuxServer: "tbd-test", location: location)
    }

    // MARK: - RemoteSessionRef.resolve

    /// The compound is an address, so it resolves without consulting the
    /// inventory at all — a session TBD has not mirrored, or a provider whose
    /// snapshot is stale, must still be addressable.
    @Test func resolvesTheProviderSlashSessionCompound() {
        let resolved = RemoteSessionRef.resolve(
            "agentbox/fix-flaky-ci", sessions: [], worktrees: [])
        #expect(resolved?.provider == "agentbox")
        #expect(resolved?.sessionID == "fix-flaky-ci")
    }

    /// A provider name cannot contain a slash and a session id can, so the
    /// split is at the FIRST one.
    @Test func splitsTheCompoundAtTheFirstSlashOnly() {
        let resolved = RemoteSessionRef.resolve(
            "agentbox/acme-app/probe", sessions: [], worktrees: [])
        #expect(resolved?.provider == "agentbox")
        #expect(resolved?.sessionID == "acme-app/probe")
    }

    @Test func refusesACompoundWithAnEmptyHalf() {
        #expect(RemoteSessionRef.resolve("/probe", sessions: [], worktrees: []) == nil)
        #expect(RemoteSessionRef.resolve("agentbox/", sessions: [], worktrees: []) == nil)
    }

    @Test func resolvesAWorktreeUUIDThroughItsProviderBinding() {
        let id = UUID()
        let worktree = remoteWorktree(
            id: id, name: "acme-lane", provider: "agentbox", sessionID: "fix-flaky-ci")
        let resolved = RemoteSessionRef.resolve(
            id.uuidString, sessions: [], worktrees: [worktree])
        #expect(resolved?.provider == "agentbox")
        #expect(resolved?.sessionID == "fix-flaky-ci")
    }

    /// A session nobody adopted has no worktree row, so its synthetic mirror id
    /// is the only UUID that names it.
    @Test func resolvesAMirrorRowsSyntheticUUID() {
        let info = session(provider: "agentbox", id: "unadopted")
        let resolved = RemoteSessionRef.resolve(
            info.id.uuidString, sessions: [info], worktrees: [])
        #expect(resolved?.provider == "agentbox")
        #expect(resolved?.sessionID == "unadopted")
    }

    @Test func resolvesAWorktreeName() {
        let worktree = remoteWorktree(
            name: "acme-lane", provider: "agentbox", sessionID: "fix-flaky-ci")
        let resolved = RemoteSessionRef.resolve(
            "acme-lane", sessions: [], worktrees: [worktree])
        #expect(resolved?.sessionID == "fix-flaky-ci")
    }

    @Test func resolvesAWorktreeDisplayName() {
        let worktree = remoteWorktree(
            name: "acme-lane", displayName: "fix flaky CI",
            provider: "agentbox", sessionID: "fix-flaky-ci")
        let resolved = RemoteSessionRef.resolve(
            "fix flaky CI", sessions: [], worktrees: [worktree])
        #expect(resolved?.sessionID == "fix-flaky-ci")
    }

    /// Two rows answering to one name resolve to nothing rather than to a
    /// guess: acting on the wrong session is worse than being asked which.
    @Test func refusesAnAmbiguousName() {
        let first = remoteWorktree(
            name: "probe", provider: "agentbox", sessionID: "one")
        let second = remoteWorktree(
            name: "probe", provider: "acme-cloud", sessionID: "two")
        #expect(RemoteSessionRef.resolve(
            "probe", sessions: [], worktrees: [first, second]) == nil)
    }

    /// A local worktree carries no provider binding, so its name names no
    /// remote session.
    @Test func refusesANameThatIsALocalWorktree() {
        let local = remoteWorktree(name: "local-lane", provider: nil, sessionID: nil)
        #expect(RemoteSessionRef.resolve(
            "local-lane", sessions: [], worktrees: [local]) == nil)
    }

    @Test func refusesAnUnknownName() {
        #expect(RemoteSessionRef.resolve("nothing", sessions: [], worktrees: []) == nil)
    }

    @Test func refusesBlankInput() {
        #expect(RemoteSessionRef.resolve("   ", sessions: [], worktrees: []) == nil)
    }

    // MARK: - The receipt's human wording

    @Test func confirmationNamesTheExpiryWhenTheProviderStatedOne() {
        let expiry = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let text = retainConfirmation(
            provider: "agentbox",
            receipt: RetainReceipt(key: "k", expiresAt: expiry, bytes: 148_213))
        #expect(text.contains("148213"))
        #expect(text.contains("2026-10-01T00:00:00Z"))
    }

    /// The contract makes rendering an absent expiry as permanence a MUST NOT,
    /// so the sentence says the provider stated nothing.
    @Test func confirmationNeverRendersAnAbsentExpiryAsPermanence() {
        let text = retainConfirmation(
            provider: "agentbox", receipt: RetainReceipt(key: "k", bytes: 10))
        #expect(text.contains("no expiry stated"))
        #expect(text.lowercased().contains("forever") == false)
        #expect(text.lowercased().contains("never expires") == false)
    }

    // MARK: - The --json receipt shape

    @Test func receiptJSONCarriesTheFourDocumentedFields() throws {
        let expiry = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let text = try #require(jsonString(RetainReceiptOutput(
            provider: "agentbox",
            receipt: RetainReceipt(key: "opaque", expiresAt: expiry, bytes: 12))))
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["provider"] as? String == "agentbox")
        #expect(object["key"] as? String == "opaque")
        #expect(object["bytes"] as? Int == 12)
        #expect(object["expires_at"] != nil)
    }

    /// Omitted, not null: `null` would read as an answer, and the answer the
    /// provider gave is that it has no claim to make.
    @Test func receiptJSONOmitsExpiresAtWhenThereIsNoClaim() throws {
        let text = try #require(jsonString(RetainReceiptOutput(
            provider: "agentbox", receipt: RetainReceipt(key: "opaque", bytes: 12))))
        #expect(text.contains("expires_at") == false)
    }

    // MARK: - retained list rendering

    @Test func retainedListingSaysSoWhenEmpty() {
        #expect(renderRetainedListing([]) == "No retained transcripts recorded.")
    }

    @Test func retainedListingNamesProviderKeyBytesAndSource() {
        let rows = [RetainedTranscript(
            provider: "agentbox", key: "opaque", expiresAt: nil, bytes: 12,
            sourceSessionID: "fix-flaky-ci", sourceTitle: "fix flaky CI")]
        let text = renderRetainedListing(rows)
        #expect(text.contains("agentbox"))
        #expect(text.contains("opaque"))
        #expect(text.contains("12"))
        #expect(text.contains("fix flaky CI"))
    }

    /// A blank EXPIRES cell is the honest rendering of "no claim". Any word
    /// there would be read as an answer.
    @Test func retainedListingLeavesExpiresBlankWhenThereIsNoClaim() {
        let text = renderRetainedListing([
            RetainedTranscript(provider: "agentbox", key: "k", expiresAt: nil, bytes: 1),
        ])
        #expect(text.lowercased().contains("never") == false)
        #expect(text.lowercased().contains("forever") == false)
    }

    @Test func retainedListingShowsAStatedExpiry() {
        let expiry = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let text = renderRetainedListing([
            RetainedTranscript(provider: "agentbox", key: "k", expiresAt: expiry, bytes: 1),
        ])
        #expect(text.contains("2026-10-01T00:00:00Z"))
    }

    /// An `import` names no session on the provider, so the source column says
    /// where it came from instead of leaving a hole.
    @Test func retainedListingLabelsAnImportedTranscript() {
        let text = renderRetainedListing([
            RetainedTranscript(provider: "agentbox", key: "k", bytes: 1),
        ])
        #expect(text.contains("imported"))
    }

    // MARK: - The missing-capability refusal

    @Test func missingCapabilityRefusalNamesTheCapabilityAndProvider() {
        let text = remoteMissingCapability("recall", provider: "agentbox")
        #expect(text.contains("recall"))
        #expect(text.contains("agentbox"))
    }

    // MARK: - delete: the caller-side policy

    private let address = "agentbox/acme-app/probe"

    /// Exited and clean: nothing to refuse.
    @Test func deleteProceedsForAnExitedCleanSession() {
        #expect(RemoteDeletePrecondition.refusal(
            state: .exited, workspaceDirty: false, force: false, address: address) == nil)
    }

    /// The two refusals are named separately because they have different
    /// remedies: one waits or stops the session, the other commits or pushes on
    /// the provider's machine.
    @Test func deleteRefusesARunningSessionByName() {
        let refusal = RemoteDeletePrecondition.refusal(
            state: .running, workspaceDirty: false, force: false, address: address)
        #expect(refusal?.contains("still running") == true)
        #expect(refusal?.contains(address) == true)
        #expect(refusal?.contains("--force") == true)
    }

    @Test func deleteRefusesAStartingSession() {
        #expect(RemoteDeletePrecondition.refusal(
            state: .starting, workspaceDirty: false, force: false, address: address) != nil)
    }

    /// The app's `RemoteDeleteConfirmation.decide` treats `.unknown` as live
    /// (`live = state != .exited`) because a state TBD could not read is not a
    /// statement the session is finished. The CLI must agree: `.unknown` is not
    /// the frictionless path.
    @Test func deleteRefusesASessionInUnknownState() {
        let refusal = RemoteDeletePrecondition.refusal(
            state: .unknown, workspaceDirty: false, force: false, address: address)
        #expect(refusal != nil)
        #expect(refusal?.contains(address) == true)
        #expect(refusal?.contains("--force") == true)
    }

    @Test func forceOverridesAnUnknownStateRefusal() {
        #expect(RemoteDeletePrecondition.refusal(
            state: .unknown, workspaceDirty: false, force: true, address: address) == nil)
    }

    @Test func deleteRefusesADirtyWorkspaceByName() {
        let refusal = RemoteDeletePrecondition.refusal(
            state: .exited, workspaceDirty: true, force: false, address: address)
        #expect(refusal?.contains("workspace_dirty") == true)
        #expect(refusal?.contains("--force") == true)
    }

    /// `--force` overrides both, which is the whole reason the contract leaves
    /// this policy to the caller.
    @Test func forceOverridesBothRefusals() {
        #expect(RemoteDeletePrecondition.refusal(
            state: .running, workspaceDirty: true, force: true, address: address) == nil)
    }

    /// A session TBD has never mirrored has no state and no meta to read, and
    /// `<provider>/<session-id>` must keep working against exactly that. The
    /// provider is still the last word on whether the delete happens.
    @Test func anUnmirroredSessionIsNotRefusedOnAbsentInformation() {
        #expect(RemoteDeletePrecondition.refusal(
            state: nil, workspaceDirty: false, force: false, address: address) == nil)
    }

    // MARK: - delete: resolving --retain

    /// Unspecified is not "off" — it asks for a receipt whenever the provider
    /// can give one, matching what the app already does.
    @Test func unspecifiedRetainDefaultsOnWhenTheProviderDeclaresIt() {
        #expect(RemoteDeletePrecondition.resolveRetain(nil, capabilities: ["delete", "retain"]))
    }

    /// A provider that never declared `retain` has no receipt to give, and
    /// that is "no receipt available", not a caller mistake — this must not
    /// be conflated with the explicit-`--retain` refusal, which errors.
    @Test func unspecifiedRetainStaysOffWithoutTheCapabilityAndDoesNotError() {
        #expect(!RemoteDeletePrecondition.resolveRetain(nil, capabilities: ["delete"]))
    }

    /// `--no-retain` declines even against a provider that could have
    /// retained — the explicit opt-out always wins.
    @Test func explicitNoRetainDeclinesEvenWhenTheProviderCanRetain() {
        #expect(!RemoteDeletePrecondition.resolveRetain(false, capabilities: ["delete", "retain"]))
    }

    // MARK: - delete: the two outcomes

    /// `deleted: false` is a success — there was nothing to destroy — and is
    /// worded so nobody reads it as a deletion that happened.
    @Test func anAlreadyGoneSessionIsNotReportedAsDeleted() {
        let text = remoteDeleteConfirmation(
            address: address, result: RemoteDeleteResult(id: "probe", deleted: false))
        #expect(text.contains("already gone"))
        #expect(!text.contains("deleted \(address)"))
    }

    @Test func aDeleteWithNoReceiptSaysOnlyThat() {
        let text = remoteDeleteConfirmation(
            address: address, result: RemoteDeleteResult(id: "probe", deleted: true))
        #expect(text.contains("deleted \(address)"))
        #expect(!text.contains("retained"))
    }

    @Test func aRetainingDeletePrintsTheKeyAndTheStatedExpiry() {
        let expiry = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let text = remoteDeleteConfirmation(
            address: address,
            result: RemoteDeleteResult(
                id: "probe", deleted: true,
                retained: RetainReceipt(key: "opaque", expiresAt: expiry, bytes: 12)))
        #expect(text.contains("retained: opaque"))
        #expect(text.contains("2026-10-01T00:00:00Z"))
    }

    /// An absent expiry is never rendered as permanence.
    @Test func aRetainingDeleteWithNoStatedExpirySaysSo() {
        let text = remoteDeleteConfirmation(
            address: address,
            result: RemoteDeleteResult(
                id: "probe", deleted: true,
                retained: RetainReceipt(key: "opaque", bytes: 12)))
        #expect(text.contains("no expiry stated"))
        #expect(!text.lowercased().contains("never"))
        #expect(!text.lowercased().contains("forever"))
    }

    // MARK: - dismiss contrasts itself with delete

    /// Without the contrast users reach for whichever they find first, and the
    /// two are not interchangeable in either direction: one is a local tidy-up,
    /// the other is irreversible.
    @Test func dismissHelpSaysWhatItDoesNotDo() {
        let discussion = RemoteDismiss.configuration.discussion
        #expect(discussion.contains("delete"))
        #expect(discussion.contains("local"))
        #expect(RemoteDismiss.configuration.abstract.contains("changing nothing on the provider"))
    }

    /// And delete's own help points at the gate, since a refusal naming a flag
    /// the user cannot find is not much of a refusal.
    @Test func deleteHelpNamesTheFlagAndHowToLiftIt() {
        let discussion = RemoteDelete.configuration.discussion
        #expect(discussion.contains("remote_delete_enabled"))
        #expect(discussion.contains("tbd remote allow-delete on"))
    }
}

import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The rule that decides whether deleting a remote session asks first
/// (`docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`,
/// "App"): confirmation is skipped only when nothing is at stake — the session
/// has exited, claims no uncommitted work, and a record of the conversation is
/// coming back. Everything else confirms.
///
/// A pure function, so every branch is testable without an `AppState` — the
/// same split `RemoteSessionActionMenu` keeps.
@Suite("Remote delete confirmation")
struct RemoteDeleteConfirmationTests {
    private typealias Decision = RemoteDeleteConfirmation.Decision

    private let expiry = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!

    private func message(_ decision: Decision) -> String? {
        if case .confirm(let message) = decision { return message }
        return nil
    }

    // MARK: - The one branch that proceeds

    /// Exited, clean, and a receipt is coming: nothing is destroyed that
    /// anybody can miss, so the gesture goes straight through.
    @Test func exitedAndCleanWithARetainProceeds() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .exited, workspaceDirty: false, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: expiry)
        #expect(decision == .proceed)
    }

    // MARK: - Every branch that confirms

    /// Still running: deleting ends compute that is doing something right now.
    @Test func runningConfirms() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: expiry)
        #expect(decision != .proceed)
    }

    /// `starting` and `unknown` are not `exited`, and the skip is granted only
    /// to `exited`. A state TBD cannot read is the last one to wave through.
    @Test func startingAndUnknownStatesConfirm() {
        for state in [RemoteProcessState.starting, .unknown] {
            let decision = RemoteDeleteConfirmation.decide(
                state: state, workspaceDirty: false, willRetain: true,
                sessionTitle: "fix flaky CI", expiresAt: expiry)
            #expect(decision != .proceed, "\(state) must confirm")
        }
    }

    /// `meta.workspace_dirty`: uncommitted work lives on the provider's machine
    /// and goes with the session.
    @Test func dirtyWorkspaceConfirms() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .exited, workspaceDirty: true, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: expiry)
        #expect(decision != .proceed)
        #expect(message(decision)?.contains("uncommitted") == true)
    }

    /// **The branch that is easy to miss.** An exited, clean session still
    /// confirms when no record is being kept, because there is then nothing
    /// left to recover afterwards.
    @Test func keepingNoRecordConfirmsEvenWhenExitedAndClean() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .exited, workspaceDirty: false, willRetain: false,
            sessionTitle: "fix flaky CI", expiresAt: nil)
        #expect(decision != .proceed)
        let text = try? #require(message(decision))
        #expect(text?.contains("No transcript") == true)
    }

    // MARK: - What the message must say

    /// The dialog names the session, so a user with several open knows which
    /// one is about to go.
    @Test func theMessageNamesTheSession() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: expiry)
        #expect(message(decision)?.contains("fix flaky CI") == true)
    }

    /// A session the provider never titled still reads as a sentence rather
    /// than as empty quotes.
    @Test func anUntitledSessionStillReadsAsASentence() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: false,
            sessionTitle: "   ", expiresAt: nil)
        let text = try? #require(message(decision))
        #expect(text?.contains("\u{201C}\u{201D}") != true, "no empty quotes")
        #expect(text?.contains("this remote session") == true)
    }

    /// A kept transcript is stated as kept, and the stated expiry is shown.
    @Test func theMessageStatesTheExpiryWhenTheProviderGaveOne() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: expiry)
        let text = try? #require(message(decision))
        #expect(text?.contains("transcript") == true)
        #expect(text?.contains("expires") == true)
        #expect(text?.contains(RemoteDeleteConfirmation.expiryDescription(expiry)) == true)
    }

    /// **An absent expiry is never permanence.** The contract makes rendering
    /// absence as a guarantee a MUST NOT, so the message says the provider
    /// stated nothing rather than "never expires" or "kept forever".
    @Test func anAbsentExpiryIsNeverRenderedAsPermanence() {
        let decision = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: true,
            sessionTitle: "fix flaky CI", expiresAt: nil)
        let text = try? #require(message(decision))
        #expect(text?.contains("transcript") == true)
        let lowered = text?.lowercased() ?? ""
        #expect(!lowered.contains("never"))
        #expect(!lowered.contains("forever"))
        #expect(!lowered.contains("indefinitely"))
        #expect(text?.contains("states no expiry") == true)
    }

    /// The retention clause is one or the other, never both, whichever branch
    /// produced the confirmation.
    @Test func theRetentionClauseIsExactlyOneOfTheTwo() {
        let kept = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: true,
            sessionTitle: "t", expiresAt: expiry)
        let notKept = RemoteDeleteConfirmation.decide(
            state: .running, workspaceDirty: false, willRetain: false,
            sessionTitle: "t", expiresAt: expiry)
        #expect(message(kept)?.contains("No transcript") != true)
        #expect(message(notKept)?.contains("No transcript") == true)
        #expect(message(notKept)?.contains("expires") != true,
                "an expiry is meaningless when nothing is being kept")
    }
}

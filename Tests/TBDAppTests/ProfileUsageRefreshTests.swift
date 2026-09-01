import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The profile row's `⋯ ▸ Refresh usage` item: when it is offered, what it
/// warns about, and what it reports back.
///
/// The item exists because a token profile is otherwise unreachable. It is off
/// the daemon's 90-second cadence sweep (its probe is a billed request), and
/// its only other trigger is a `working → idle` transition on a session using
/// it — so once that session closes, nothing in the app or the CLI can move its
/// bars again. Every rule below is pinned in both directions: a rule that
/// answered "yes, offer it" or "yes, that worked" unconditionally would satisfy
/// the token cases on its own and be wrong everywhere else.
@Suite("Profile row — manual usage refresh")
struct ProfileUsageRefreshTests {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func snapshot(fetchedAt: Date?, lastAttemptAt: Date) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(buckets: [],
                             fetchedAt: fetchedAt,
                             lastAttemptAt: lastAttemptAt,
                             status: "ok",
                             statusKind: .ok)
    }

    // MARK: - showsRefreshItem

    @Test func showsRefreshItem_tokenProfile_isOffered() {
        // The whole reason the item exists: no cadence sweep reaches this kind.
        #expect(ProfileUsageRefreshPresentation.showsRefreshItem(kind: .oauthToken,
                                                                 loginIdentity: nil))
        #expect(ProfileUsageRefreshPresentation.showsRefreshItem(kind: .oauthToken,
                                                                 loginIdentity: "a@acme.com"))
    }

    @Test func showsRefreshItem_signedInOAuth_isOffered() {
        #expect(ProfileUsageRefreshPresentation.showsRefreshItem(kind: .oauth,
                                                                 loginIdentity: "a@acme.com"))
    }

    @Test func showsRefreshItem_signedOutOAuth_isHidden() {
        // No credential to read the usage endpoint with — the daemon's poller
        // does not consider this profile supported, so the item would spin and
        // report nothing. A blank identity is the same state as a missing one.
        #expect(!ProfileUsageRefreshPresentation.showsRefreshItem(kind: .oauth,
                                                                  loginIdentity: nil))
        #expect(!ProfileUsageRefreshPresentation.showsRefreshItem(kind: .oauth,
                                                                  loginIdentity: "   "))
    }

    @Test func showsRefreshItem_apiKeyAndBedrock_areHidden() {
        // There is no usage endpoint for these kinds at all. A menu item that
        // silently no-ops is worse than one that is absent.
        #expect(!ProfileUsageRefreshPresentation.showsRefreshItem(kind: .apiKey,
                                                                  loginIdentity: nil))
        #expect(!ProfileUsageRefreshPresentation.showsRefreshItem(kind: .bedrock,
                                                                  loginIdentity: nil))
    }

    // MARK: - refreshHelp

    @Test func refreshHelp_tokenProfile_namesTheCostAndTheFloor() {
        let help = ProfileUsageRefreshPresentation.refreshHelp(kind: .oauthToken)
        #expect(help.contains("billed"))
        #expect(help.contains("5 minutes"))
    }

    @Test func refreshHelp_otherKinds_promiseNoBilling() {
        // A signed-in profile's refresh is a free read; telling the user it
        // costs money would deter a harmless click.
        for kind in [CredentialKind.oauth, .apiKey, .bedrock] {
            #expect(!ProfileUsageRefreshPresentation.refreshHelp(kind: kind).contains("billed"))
        }
    }

    // MARK: - classify

    @Test func classify_newFetchTimestamp_isARefresh() {
        let before = snapshot(fetchedAt: t0, lastAttemptAt: t0)
        let after = snapshot(fetchedAt: t0.addingTimeInterval(600),
                             lastAttemptAt: t0.addingTimeInterval(600))
        #expect(ProfileUsageRefreshOutcome.classify(before: before, after: after) == .refreshed)
    }

    @Test func classify_firstEverSuccess_isARefresh() {
        let after = snapshot(fetchedAt: t0, lastAttemptAt: t0)
        #expect(ProfileUsageRefreshOutcome.classify(before: nil, after: after) == .refreshed)
    }

    @Test func classify_identicalSnapshot_isAlreadyCurrent() {
        // The case the note exists for: the daemon declined to spend a billed
        // probe inside the five-minute floor, so the row is byte-identical.
        // Reporting this as a refresh would be a lie; reporting nothing at all
        // is what a broken button looks like.
        let same = snapshot(fetchedAt: t0, lastAttemptAt: t0)
        #expect(ProfileUsageRefreshOutcome.classify(before: same, after: same) == .alreadyCurrent)
    }

    @Test func classify_attemptedButFetchTimestampUnmoved_isAProbeFailure() {
        // A 429 or a rejected token advances `lastAttemptAt` and leaves
        // `fetchedAt` where it was. That is neither a refresh nor a skip, and
        // conflating it with either hides a real failure behind a reassuring
        // sentence.
        let before = snapshot(fetchedAt: t0, lastAttemptAt: t0)
        let after = snapshot(fetchedAt: t0, lastAttemptAt: t0.addingTimeInterval(600))
        #expect(ProfileUsageRefreshOutcome.classify(before: before, after: after) == .probeFailed)
    }

    @Test func classify_firstEverAttemptThatFailed_isAProbeFailure() {
        let after = snapshot(fetchedAt: nil, lastAttemptAt: t0)
        #expect(ProfileUsageRefreshOutcome.classify(before: nil, after: after) == .probeFailed)
    }

    @Test func classify_noSnapshotCameBack_isNoData() {
        // Never silently reported as success.
        #expect(ProfileUsageRefreshOutcome.classify(before: nil, after: nil) == .noData)
        let before = snapshot(fetchedAt: t0, lastAttemptAt: t0)
        #expect(ProfileUsageRefreshOutcome.classify(before: before, after: nil) == .noData)
    }

    // MARK: - note

    @Test func note_everyOutcomeSaysSomething() {
        // A refresh whose visible result is nothing at all is exactly what a
        // broken button looks like, so no outcome may render an empty line —
        // including the two that leave the bars unchanged.
        let outcomes: [ProfileUsageRefreshOutcome] = [
            .refreshed, .probeFailed, .alreadyCurrent, .noData, .failed("connection refused"),
        ]
        var notes: Set<String> = []
        for outcome in outcomes {
            let note = ProfileUsageRefreshPresentation.note(for: outcome)
            #expect(!note.isEmpty)
            notes.insert(note)
        }
        // Distinct, not five wordings of "done".
        #expect(notes.count == outcomes.count)
    }

    @Test func note_alreadyCurrent_saysNoRequestWasMade() {
        // The user just clicked and nothing moved; the note has to explain why
        // rather than claim numbers were fetched.
        let note = ProfileUsageRefreshPresentation.note(for: .alreadyCurrent)
        #expect(note.contains("too recently"))
        // And it must not claim numbers were fetched, nor that the data is
        // current — a backoff window can hold a probe over data the row's own
        // status line is already calling stale.
        #expect(!note.lowercased().contains("refreshed"))
        #expect(!note.lowercased().contains("up to date"))
    }

    @Test func note_failure_carriesTheUnderlyingMessage() {
        #expect(ProfileUsageRefreshPresentation.note(for: .failed("connection refused"))
                .contains("connection refused"))
    }

    // MARK: - noteIsWarning

    @Test func noteIsWarning_onlyForOutcomesThatWentWrong() {
        #expect(!ProfileUsageRefreshPresentation.noteIsWarning(for: .refreshed))
        // Declining to spend a billed probe inside the floor is the feature
        // working, not a fault — an orange line here would train the user to
        // treat a correct outcome as an error.
        #expect(!ProfileUsageRefreshPresentation.noteIsWarning(for: .alreadyCurrent))
        #expect(ProfileUsageRefreshPresentation.noteIsWarning(for: .probeFailed))
        #expect(ProfileUsageRefreshPresentation.noteIsWarning(for: .noData))
        #expect(ProfileUsageRefreshPresentation.noteIsWarning(for: .failed("boom")))
    }
}

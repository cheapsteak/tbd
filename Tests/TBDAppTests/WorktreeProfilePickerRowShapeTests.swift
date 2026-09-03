import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Which of the `+` menu's two profile-row shapes a profile gets, and whether
/// that row's subtitle is the graphical usage meter.
///
/// The rules used to read `kind == .oauth`, which quietly excluded the fourth
/// credential kind: a token profile with a healthy snapshot fell through to the
/// plain row and rendered its numbers as the text line "5h 61% · 7d 38%" where
/// a signed-in account got a meter. Both branches of every rule are pinned
/// here, because a rule that answered "yes" to everything would satisfy the
/// token cases alone.
@Suite("WorktreeProfilePickerView — profile row shape")
struct WorktreeProfilePickerRowShapeTests {

    private func snapshot(
        buckets: [ClaudeUsageLimitBucket],
        fetchedAt: Date? = Date(timeIntervalSince1970: 1_780_000_000),
        statusKind: ProfileUsageStatusKind = .ok
    ) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(buckets: buckets,
                             fetchedAt: fetchedAt,
                             lastAttemptAt: Date(timeIntervalSince1970: 1_780_000_000),
                             status: "ok",
                             statusKind: statusKind)
    }

    private func entry(
        kind: CredentialKind,
        loginIdentity: String? = nil,
        usageSnapshot: ProfileUsageSnapshot? = nil
    ) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: UUID(), name: "Acme", kind: kind),
            usage: nil,
            loginIdentity: loginIdentity,
            usageSnapshot: usageSnapshot)
    }

    /// The two buckets a token profile can ever have. The probe reads its
    /// numbers from response headers, which carry no per-model breakdown, so
    /// there is never a `weekly_scoped` bucket to go with them.
    private var twoBucketSnapshot: ProfileUsageSnapshot {
        snapshot(buckets: [
            ClaudeUsageLimitBucket(kind: "session", group: "session",
                                   percent: 61, severity: "normal"),
            ClaudeUsageLimitBucket(kind: "weekly_all", group: "weekly",
                                   percent: 38, severity: "normal"),
        ])
    }

    // MARK: - rendersClaudeRow

    @Test func rendersClaudeRow_tokenProfile_getsTheClaudeAccountRow() {
        // The regression: a token profile is a Claude account, authenticated by
        // a stored setup-token rather than a browser round-trip. It gets the
        // model rail and the meter, exactly as a signed-in account does.
        #expect(WorktreeProfilePickerView.rendersClaudeRow(kind: .oauthToken,
                                                           isSelectable: true))
    }

    @Test func rendersClaudeRow_signedInOAuth_isUnchanged() {
        #expect(WorktreeProfilePickerView.rendersClaudeRow(kind: .oauth,
                                                           isSelectable: true))
    }

    @Test func rendersClaudeRow_apiKeyAndBedrock_keepThePlainRow() {
        // Neither has a usage snapshot or an account to meter, so widening the
        // gate must not sweep them in.
        #expect(!WorktreeProfilePickerView.rendersClaudeRow(kind: .apiKey,
                                                            isSelectable: true))
        #expect(!WorktreeProfilePickerView.rendersClaudeRow(kind: .bedrock,
                                                            isSelectable: true))
    }

    @Test func rendersClaudeRow_unselectableRow_keepsThePlainRow() {
        // A signed-out oauth row is dimmed and disabled; a model rail there
        // would be inert chrome.
        #expect(!WorktreeProfilePickerView.rendersClaudeRow(kind: .oauth,
                                                            isSelectable: false))
        #expect(!WorktreeProfilePickerView.rendersClaudeRow(kind: .oauthToken,
                                                            isSelectable: false))
    }

    // MARK: - showsUsageBars

    @Test func showsUsageBars_tokenProfileWithTwoBuckets_drawsTheMeter() {
        // The composed outcome the finding is about: session + weekly_all and
        // no scoped bucket is enough for the meter. `UsageBarsView` draws each
        // of its first two rows from an optional lookup and then loops over the
        // scoped buckets, so an empty scoped set contributes no rows at all —
        // two aligned bars, not two bars and a gap.
        #expect(WorktreeProfilePickerView.showsUsageBars(for: entry(kind: .oauthToken,
                                                                    usageSnapshot: twoBucketSnapshot)))
    }

    @Test func showsUsageBars_tokenProfileWithSessionBucketOnly_stillDrawsTheMeter() {
        let sessionOnly = snapshot(buckets: [
            ClaudeUsageLimitBucket(kind: "session", group: "session", percent: 61),
        ])
        #expect(WorktreeProfilePickerView.showsUsageBars(for: entry(kind: .oauthToken,
                                                                    usageSnapshot: sessionOnly)))
    }

    @Test func showsUsageBars_tokenProfileWithNoSnapshot_keepsTheTextSubtitle() {
        // There is nothing to draw before the first probe lands, and an empty
        // meter would be worse than the text line.
        #expect(!WorktreeProfilePickerView.showsUsageBars(for: entry(kind: .oauthToken)))
    }

    @Test func showsUsageBars_tokenProfileWithBucketlessSnapshot_keepsTheTextSubtitle() {
        // A rejected token records a snapshot with no buckets; the honest note
        // must carry the row rather than a meter of nothing.
        let rejected = snapshot(buckets: [], fetchedAt: nil, statusKind: .needsLogin)
        #expect(!WorktreeProfilePickerView.showsUsageBars(for: entry(kind: .oauthToken,
                                                                     usageSnapshot: rejected)))
    }

    @Test func showsUsageBars_signedOutOAuth_neverDrawsTheMeter() {
        // Even carrying a stale snapshot: the row is not selectable, so it does
        // not get the Claude row shape at all.
        #expect(!WorktreeProfilePickerView.showsUsageBars(
            for: entry(kind: .oauth, loginIdentity: nil, usageSnapshot: twoBucketSnapshot)))
        #expect(WorktreeProfilePickerView.showsUsageBars(
            for: entry(kind: .oauth, loginIdentity: "a@acme.com", usageSnapshot: twoBucketSnapshot)))
    }

    @Test func showsUsageBars_apiKeyProfile_neverDrawsTheMeter() {
        #expect(!WorktreeProfilePickerView.showsUsageBars(
            for: entry(kind: .apiKey, usageSnapshot: twoBucketSnapshot)))
    }

    // MARK: - claudeRowShowsSkeleton

    @Test func claudeRowShowsSkeleton_signedInOAuthAwaitingFirstPoll_shimmers() {
        #expect(WorktreeProfilePickerView.claudeRowShowsSkeleton(kind: .oauth,
                                                                 usageNote: nil,
                                                                 snapshot: nil))
    }

    @Test func claudeRowShowsSkeleton_tokenProfileAwaitingFirstProbe_doesNot() {
        // Widening the row gate made this branch reachable for the first time.
        // A token profile is off the 90-second cadence — it probes after a
        // session goes idle — so a skeleton would promise numbers that may not
        // arrive until someone finishes a turn on it, or ever.
        #expect(!WorktreeProfilePickerView.claudeRowShowsSkeleton(kind: .oauthToken,
                                                                  usageNote: nil,
                                                                  snapshot: nil))
    }

    @Test func claudeRowShowsSkeleton_neverWhenThereIsSomethingToSay() {
        #expect(!WorktreeProfilePickerView.claudeRowShowsSkeleton(kind: .oauth,
                                                                  usageNote: "needs re-login",
                                                                  snapshot: nil))
        #expect(!WorktreeProfilePickerView.claudeRowShowsSkeleton(kind: .oauth,
                                                                  usageNote: nil,
                                                                  snapshot: twoBucketSnapshot))
    }
}

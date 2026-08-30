import Foundation
import TestSupport
import SwiftUI
import Testing

@testable import TBDApp
@testable import TBDShared

// DEFECT UNDER TEST: a view renders the persisted `PRStatus` as current truth.
// That cache was measured lying — "Ready to merge" for pull requests merged days
// earlier — so every surface that shows it must show how old it is, and must
// distinguish "nobody could find out" from "there is no pull request". These are
// assertions on the COMPOSED strings the row and the toolbar actually render,
// not on the inputs, because a helper that computed the right words and a view
// that dropped them would be the same bug.

@Suite("PR freshness presentation")
struct PRFreshnessTests {

    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private static func status(observedAt: Date?) -> PRStatus {
        PRStatus(number: 42, url: "https://example.com/42", state: .mergeable,
                 reason: "Ready to merge", observedAt: observedAt)
    }

    private static func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - Age

    @Test("a fresh reading reads as just now")
    func freshReadingReadsAsJustNow() {
        #expect(PRFreshness.checkedLabel(observedAt: Self.ago(30), now: Self.now) == "checked just now")
    }

    @Test("a days-old reading says so — the measured lie, now labeled")
    func daysOldReadingSaysSo() {
        // The exact failure the stamp exists for: three days after the last
        // read, a "Ready to merge" icon must carry its age.
        let rendered = PRFreshness.checkedLabel(observedAt: Self.ago(3 * 86_400), now: Self.now)
        #expect(rendered == "checked 3d ago")
    }

    @Test("age buckets coarsen: minutes, hours, days")
    func ageBucketsCoarsen() {
        #expect(PRFreshness.checkedLabel(observedAt: Self.ago(12 * 60), now: Self.now) == "checked 10m ago")
        #expect(PRFreshness.checkedLabel(observedAt: Self.ago(3 * 3600), now: Self.now) == "checked 3h ago")
    }

    @Test("a five-minute bucket is stable between steps, so the toolbar item is not rebuilt per minute")
    func minuteBucketsAreStable() {
        // AppKit materializes the split button once and only rebuilds it when
        // its `.id` changes — and the id includes these words. A per-minute
        // label would rebuild the item (and its NSMenu) every minute.
        let early = PRFreshness.checkedLabel(observedAt: Self.ago(21 * 60), now: Self.now)
        let later = PRFreshness.checkedLabel(observedAt: Self.ago(24 * 60), now: Self.now)
        #expect(early == later)
        #expect(early == "checked 20m ago")
        #expect(PRFreshness.checkedLabel(observedAt: Self.ago(26 * 60), now: Self.now) == "checked 25m ago")
    }

    @Test("a status with no stamp says its age is unknown rather than implying freshness")
    func missingStampIsNotSilence() {
        // A row persisted before the stamp existed must not read as current.
        #expect(PRFreshness.checkedLabel(observedAt: nil, now: Self.now) == "last checked at an unknown time")
    }

    // MARK: - Undetermined vs settled

    @Test("an undetermined last check is surfaced with its cause")
    func undeterminedIsSurfaced() {
        let clause = PRFreshness.undeterminedClause(
            PRObservation(outcome: .undetermined(cause: "the forge query failed"), observedAt: Self.now))
        #expect(clause == "last check did not resolve (the forge query failed)")
    }

    @Test("a settled .none adds no caveat — and is therefore not the same as .undetermined")
    func settledNoneAddsNoCaveat() {
        let none = PRFreshness.undeterminedClause(
            PRObservation(outcome: .none, observedAt: Self.now))
        let observed = PRFreshness.undeterminedClause(
            PRObservation(outcome: .observed, observedAt: Self.now))
        let undetermined = PRFreshness.undeterminedClause(
            PRObservation(outcome: .undetermined(cause: "the forge query failed"), observedAt: Self.now))
        #expect(none == nil)
        #expect(observed == nil)
        #expect(undetermined != nil)
        #expect(none != undetermined)
    }

    @Test("a stale value whose last check failed renders BOTH its age and the failure")
    func staleUnconfirmedRendersBothClauses() {
        // The pair that is the whole point: a value from before, honestly
        // labeled as not reconfirmed.
        let clauses = PRFreshness.clauses(
            status: Self.status(observedAt: Self.ago(2 * 86_400)),
            observation: PRObservation(
                outcome: .undetermined(cause: "the forge CLI was unavailable"), observedAt: Self.now),
            now: Self.now)
        #expect(clauses == ["checked 2d ago", "last check did not resolve (the forge CLI was unavailable)"])
    }

    @Test("a confirmed value renders its age and nothing else")
    func confirmedRendersAgeOnly() {
        let clauses = PRFreshness.clauses(
            status: Self.status(observedAt: Self.ago(60)),
            observation: PRObservation(outcome: .observed, observedAt: Self.now),
            now: Self.now)
        #expect(clauses == ["checked just now"])
    }

    // MARK: - Invisible is not acceptable

    @Test("no cached PR plus an undetermined check produces a visible indicator")
    func undeterminedWithNoStatusIsVisible() {
        // Without this the row renders exactly like a worktree with no pull
        // request, and a forge outage looks like a quiet fleet.
        let tooltip = PRFreshness.unknownIndicatorTooltip(
            PRObservation(outcome: .undetermined(cause: "the forge query failed"),
                          observedAt: Self.ago(600)),
            now: Self.now)
        let rendered = try? #require(tooltip)
        #expect(rendered == "PR status unknown — the forge query failed · checked 10m ago")
        #expect(RowStatusIndicator.leading(
            isPending: false, hasPRStatus: false, hasUndeterminedPR: true) == .prUnknown)
    }

    @Test("no cached PR plus a settled .none produces no indicator at all")
    func settledNoneWithNoStatusIsSilent() {
        // The complement, and the reason the case above is not just noise: a
        // worktree the forge answered about shows nothing.
        #expect(PRFreshness.unknownIndicatorTooltip(
            PRObservation(outcome: .none, observedAt: Self.now), now: Self.now) == nil)
        #expect(PRFreshness.unknownIndicatorTooltip(nil, now: Self.now) == nil)
        #expect(RowStatusIndicator.leading(
            isPending: false, hasPRStatus: false, hasUndeterminedPR: false) == nil)
    }

    @Test("a real PR status still wins the leading slot over an undetermined marker")
    func cachedStatusOutranksTheUnknownMarker() {
        #expect(RowStatusIndicator.leading(
            isPending: false, hasPRStatus: true, hasUndeterminedPR: true) == .prStatus)
        #expect(RowStatusIndicator.leading(
            isPending: true, hasPRStatus: false, hasUndeterminedPR: true) == .pending)
    }

    // MARK: - App state keeps the two facts apart

    @Test("app state carries the outcome beside the value, never merged into it")
    @MainActor
    func appStateKeepsBothFacts() {
        // The layer between the RPC and the views. Merging them — dropping an
        // observation because there is no status, or vice versa — is the same
        // collapse one layer further out.
        let defaultsSuite = TestDefaultsSuite("PRFreshness")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        let state = AppState(userDefaults: defaults)
        let withValue = UUID()
        let noValue = UUID()

        state.prStatuses[withValue] = Self.status(observedAt: Self.ago(86_400))
        state.prObservations[withValue] = PRObservation(
            outcome: .undetermined(cause: "the forge query failed"), observedAt: Self.now)
        state.prObservations[noValue] = PRObservation(outcome: .none, observedAt: Self.now)

        // A retained value whose last check failed keeps both halves.
        #expect(state.prStatuses[withValue]?.number == 42)
        #expect(state.prObservations[withValue]?.outcome
                == .undetermined(cause: "the forge query failed"))
        // And a worktree with no value still reports which kind of "no" it is.
        #expect(state.prStatuses[noValue] == nil)
        #expect(state.prObservations[noValue]?.outcome == PRObservation.Outcome.none)
        #expect(state.prObservations[noValue]?.outcome != state.prObservations[withValue]?.outcome)
    }

    // MARK: - The toolbar carries it too

    @Test("the toolbar split button rebuilds when the rendered age changes")
    @MainActor
    func toolbarIDTracksTheRenderedAge() {
        // AppKit materializes the label once, so an id that ignored these words
        // would freeze the help string at whatever age it was first built with.
        let pr = Self.status(observedAt: Self.ago(3 * 86_400))
        let worktreeID = UUID()
        func key(_ clauses: [String]) -> String {
            PRButtonLabel.prSplitButtonID(
                worktreeID: worktreeID, worktreeFound: true, armed: false, hibernateArmed: false,
                blocked: false,
                bindings: [PRBinding(
                    worktreeID: worktreeID, owner: "acme", repo: "acme-prod",
                    number: pr.number, url: pr.url, status: pr, source: .hook)],
                freshnessClauses: clauses, colorScheme: .light)
        }
        #expect(key(["checked 3d ago"]) != key(["checked 4d ago"]))
        #expect(key(["checked 3d ago"]) != key(["checked 3d ago", "last check did not resolve (x)"]))
        #expect(key(["checked 3d ago"]) == key(["checked 3d ago"]))
    }
}

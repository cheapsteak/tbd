import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `HibernateIdleDuration`, the pure amount/unit value type behind
/// the Settings "Idle before hibernating" field. Tier 1: deterministic, no
/// SwiftUI, no daemon.
@Suite("HibernateIdleDuration")
struct HibernateIdleDurationTests {

    // MARK: - Unit selection: largest unit that divides evenly

    @Test func oneMinuteStaysMinutes() {
        let d = HibernateIdleDuration(totalMinutes: 1)
        #expect(d.unit == .minutes)
        #expect(d.amount == 1)
    }

    @Test func thirtyMinutesStaysMinutes() {
        let d = HibernateIdleDuration(totalMinutes: 30)
        #expect(d.unit == .minutes)
        #expect(d.amount == 30)
    }

    @Test func sixtyMinutesBecomesOneHour() {
        let d = HibernateIdleDuration(totalMinutes: 60)
        #expect(d.unit == .hours)
        #expect(d.amount == 1)
    }

    @Test func ninetyMinutesStaysMinutes() {
        // 90 doesn't divide evenly into hours (90/60 = 1.5), so it stays in
        // the smallest unit rather than losing precision.
        let d = HibernateIdleDuration(totalMinutes: 90)
        #expect(d.unit == .minutes)
        #expect(d.amount == 90)
    }

    @Test func oneHundredTwentyMinutesBecomesTwoHours() {
        let d = HibernateIdleDuration(totalMinutes: 120)
        #expect(d.unit == .hours)
        #expect(d.amount == 2)
    }

    @Test func fourteenFortyMinutesBecomesOneDay() {
        let d = HibernateIdleDuration(totalMinutes: 1440)
        #expect(d.unit == .days)
        #expect(d.amount == 1)
    }

    @Test func twentyEightEightyMinutesBecomesTwoDays() {
        let d = HibernateIdleDuration(totalMinutes: 2880)
        #expect(d.unit == .days)
        #expect(d.amount == 2)
    }

    @Test func maxMinutesBecomesNinetyNineDays() {
        let d = HibernateIdleDuration(totalMinutes: 142_560)
        #expect(d.unit == .days)
        #expect(d.amount == 99)
        #expect(d.totalMinutes == Config.maxHibernateIdleMinutes)
    }

    // MARK: - Clamping

    @Test func zeroClampsToOneMinute() {
        let d = HibernateIdleDuration(totalMinutes: 0)
        #expect(d.totalMinutes == 1)
        #expect(d.unit == .minutes)
        #expect(d.amount == 1)
    }

    @Test func negativeClampsToOneMinute() {
        let d = HibernateIdleDuration(totalMinutes: -100)
        #expect(d.totalMinutes == 1)
    }

    @Test func aboveMaxClampsToNinetyNineDays() {
        let d = HibernateIdleDuration(totalMinutes: 200_000)
        #expect(d.totalMinutes == Config.maxHibernateIdleMinutes)
        #expect(d.unit == .days)
        #expect(d.amount == 99)
    }

    @Test func amountUnitConstructorClampsTotalMinutes() {
        // 999 days worth of minutes, far past the 99-day ceiling.
        let d = HibernateIdleDuration(amount: 999, unit: .days)
        #expect(d.totalMinutes == Config.maxHibernateIdleMinutes)
    }

    @Test func overflowingAmountDoesNotTrap() {
        let d = HibernateIdleDuration(amount: Int.max, unit: .days)
        #expect(d.totalMinutes == Config.maxHibernateIdleMinutes)
    }

    // MARK: - Per-unit max amounts

    @Test func perUnitMaxAmounts() {
        #expect(HibernateIdleDuration.Unit.minutes.maxAmount == Config.maxHibernateIdleMinutes)
        #expect(HibernateIdleDuration.Unit.hours.maxAmount == 2_376)
        #expect(HibernateIdleDuration.Unit.days.maxAmount == 99)
    }

    // MARK: - Round-tripping

    @Test func roundTripsThroughTotalMinutes() {
        for minutes in [1, 5, 30, 60, 90, 120, 1440, 2880, 142_560] {
            let first = HibernateIdleDuration(totalMinutes: minutes)
            let second = HibernateIdleDuration(totalMinutes: first.totalMinutes)
            #expect(second.totalMinutes == first.totalMinutes)
            #expect(second.unit == first.unit)
            #expect(second.amount == first.amount)
        }
    }

    @Test func amountUnitRoundTripsWhenNormalized() {
        // 2 hours normalizes to itself (2 doesn't divide the days boundary).
        let original = HibernateIdleDuration(amount: 2, unit: .hours)
        let normalized = HibernateIdleDuration(totalMinutes: original.totalMinutes)
        #expect(normalized == original)
    }

    // MARK: - Singular/plural naming

    @Test func singularNamesForCountOne() {
        #expect(HibernateIdleDuration.Unit.minutes.displayName(count: 1) == "minute")
        #expect(HibernateIdleDuration.Unit.hours.displayName(count: 1) == "hour")
        #expect(HibernateIdleDuration.Unit.days.displayName(count: 1) == "day")
    }

    @Test func pluralNamesForCountOtherThanOne() {
        #expect(HibernateIdleDuration.Unit.minutes.displayName(count: 2) == "minutes")
        #expect(HibernateIdleDuration.Unit.hours.displayName(count: 0) == "hours")
        #expect(HibernateIdleDuration.Unit.days.displayName(count: 99) == "days")
    }

    // MARK: - resolveAmount: shared revert-vs-clamp rule for the Settings
    // amount field's commit and the unit picker's reinterpret-on-change
    // commit (SettingsView.commitHibernateIdleAmount / hibernateIdleUnitBinding).

    @Test func resolveAmountKeepsAValidInRangeParse() {
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "45", targetUnit: .minutes) == 45)
    }

    @Test func resolveAmountRevertsUnparseableText() {
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "abc", targetUnit: .minutes) == 10)
    }

    @Test func resolveAmountRevertsEmptyText() {
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "  ", targetUnit: .minutes) == 10)
    }

    @Test func resolveAmountRevertsZero() {
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "0", targetUnit: .minutes) == 10)
    }

    @Test func resolveAmountRevertsNegative() {
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "-5", targetUnit: .minutes) == 10)
    }

    @Test func resolveAmountClampsInsteadOfRevertingWhenOverUnitMax() {
        // 5000 is a valid positive parse, but exceeds what Days can express
        // (99) — must clamp to the max, not revert to the unrelated last
        // committed amount.
        let last = HibernateIdleDuration(amount: 10, unit: .minutes)
        #expect(last.resolveAmount(fromText: "5000", targetUnit: .days) == HibernateIdleDuration.Unit.days.maxAmount)
    }

    @Test func resolveAmountClampsRevertFallbackToNewUnitMax() {
        // The fallback (last committed amount) must also be clamped to the
        // target unit's max — reverting while reinterpreting into Days must
        // not carry over an amount only valid in Minutes.
        let last = HibernateIdleDuration(amount: 5_000, unit: .minutes)
        #expect(last.resolveAmount(fromText: "", targetUnit: .days) == HibernateIdleDuration.Unit.days.maxAmount)
    }

    @Test func resolveAmountSameUnitRoundTrips() {
        let last = HibernateIdleDuration(amount: 30, unit: .minutes)
        #expect(last.resolveAmount(fromText: "30", targetUnit: .minutes) == 30)
    }

    // MARK: - syncing: the pure decision behind
    // SettingsView.syncHibernateIdleFromAppState. Regression coverage for
    // the shipped-default-blank-field bug: the totals-agree guard must stop
    // amount+unit from being re-derived, but must NOT also suppress writing
    // the display text.

    @Test func syncingWithMatchingDefaultPopulatesText() {
        // The exact regression: current is the view's @State default (30
        // min, the shipped default) and the daemon's persisted value is
        // also 30 — the common case for most users on first appearance.
        // The old totals-agree early return skipped everything, including
        // the text write, leaving the field blank for the view's lifetime.
        let current = HibernateIdleDuration(totalMinutes: 30)
        let result = HibernateIdleDuration.syncing(
            current: current,
            persistedMinutes: 30,
            isFocused: false,
            force: false
        )
        #expect(result?.amountText == "30")
        #expect(result?.duration == current)
    }

    @Test func syncingCommittedMinutesRoundTripKeepsUnit() {
        // Committing "120 Minutes" leaves the totals equal on the next
        // sync (e.g. the settle-sync after commit, or a later .onAppear).
        // Re-deriving from the total would renormalize to "2 Hours" even
        // though nothing external changed — the unit must survive.
        let committed = HibernateIdleDuration(amount: 120, unit: .minutes)
        let result = HibernateIdleDuration.syncing(
            current: committed,
            persistedMinutes: 120,
            isFocused: false,
            force: false
        )
        #expect(result?.duration.unit == .minutes)
        #expect(result?.duration.amount == 120)
        #expect(result?.amountText == "120")
    }

    @Test func syncingGenuineExternalDeltaRederivesAmountAndUnit() {
        // A different total (another window/session changed the config)
        // must re-derive amount+unit from the new total, not just refresh
        // the text of the stale duration.
        let current = HibernateIdleDuration(amount: 30, unit: .minutes)
        let result = HibernateIdleDuration.syncing(
            current: current,
            persistedMinutes: 120,
            isFocused: false,
            force: false
        )
        #expect(result?.duration.unit == .hours)
        #expect(result?.duration.amount == 2)
        #expect(result?.amountText == "2")
    }

    @Test func syncingFocusedNotForcedMakesNoChange() {
        // An external delta must not stomp an in-progress edit.
        let current = HibernateIdleDuration(amount: 30, unit: .minutes)
        let result = HibernateIdleDuration.syncing(
            current: current,
            persistedMinutes: 120,
            isFocused: true,
            force: false
        )
        #expect(result == nil)
    }

    @Test func syncingFocusedForcedStillApplies() {
        // The view's own settled commit RPC must apply even if the field
        // is still focused (`.onSubmit` doesn't resign first responder).
        let current = HibernateIdleDuration(amount: 30, unit: .minutes)
        let result = HibernateIdleDuration.syncing(
            current: current,
            persistedMinutes: 120,
            isFocused: true,
            force: true
        )
        #expect(result?.duration.unit == .hours)
        #expect(result?.duration.amount == 2)
        #expect(result?.amountText == "2")
    }
}

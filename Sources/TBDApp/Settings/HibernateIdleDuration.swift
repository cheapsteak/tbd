import Foundation
import TBDShared

/// Field+unit split for editing `Config.hibernateIdleMinutes` in the Settings
/// UI. Replaces a `Stepper` capped at 240 minutes (48 clicks to reach a day,
/// impossible past 4 hours) with a numeric amount plus a unit picker spanning
/// `Config.minHibernateIdleMinutes...Config.maxHibernateIdleMinutes` (1 minute
/// to 99 days).
///
/// Deliberately free of SwiftUI so it unit-tests without a view host — the
/// view owns the `TextField`/`Picker` and the commit-on-blur/submit timing;
/// this type just knows how to pick a sensible unit for a total and convert
/// back.
struct HibernateIdleDuration: Equatable {
    enum Unit: String, CaseIterable, Identifiable {
        case minutes
        case hours
        case days

        var id: String { rawValue }

        var minutesPerUnit: Int {
            switch self {
            case .minutes: return 1
            case .hours: return 60
            case .days: return 60 * 24
            }
        }

        /// Singular/plural-aware display name, e.g. "1 hour" vs "2 hours".
        func displayName(count: Int) -> String {
            let plural = count != 1
            switch self {
            case .minutes: return plural ? "minutes" : "minute"
            case .hours: return plural ? "hours" : "hour"
            case .days: return plural ? "days" : "day"
            }
        }

        /// The largest whole amount of this unit that stays within
        /// `Config.maxHibernateIdleMinutes` — bounds the amount field so it
        /// can never express an out-of-range total.
        var maxAmount: Int {
            Config.maxHibernateIdleMinutes / minutesPerUnit
        }
    }

    /// The accepted total-minutes range, mirroring `Config`'s bounds.
    static let range = Config.minHibernateIdleMinutes...Config.maxHibernateIdleMinutes

    var amount: Int
    var unit: Unit

    /// Picks the **largest unit that divides `totalMinutes` evenly** and
    /// whose amount is a whole number >= 1, so a round total displays round
    /// (1440 -> 1 day, 120 -> 2 hours, 90 -> 90 minutes, 30 -> 30 minutes).
    /// Falls back to minutes when no larger unit divides evenly. Input is
    /// clamped to `Self.range` first.
    init(totalMinutes: Int) {
        let clamped = Self.clamp(totalMinutes)
        for candidate in [Unit.days, .hours] {
            let perUnit = candidate.minutesPerUnit
            if clamped % perUnit == 0, clamped / perUnit >= 1 {
                self.amount = clamped / perUnit
                self.unit = candidate
                return
            }
        }
        self.amount = clamped
        self.unit = .minutes
    }

    /// Direct constructor for a field+unit pair the view already validated
    /// (e.g. a freshly parsed amount paired with the picker's current unit).
    init(amount: Int, unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    /// The total in minutes, clamped to `Self.range`. Overflow-safe: an
    /// out-of-range `amount` (a caller skipping the view's validation, or a
    /// pathological test input) saturates to `Int.max` before clamping
    /// rather than trapping on the multiply.
    var totalMinutes: Int {
        let product = amount.multipliedReportingOverflow(by: unit.minutesPerUnit)
        let raw = product.overflow ? Int.max : product.partialValue
        return Self.clamp(raw)
    }

    private static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, Self.range.lowerBound), Self.range.upperBound)
    }

    /// Resolve the amount to apply for `targetUnit` from user-typed text,
    /// treating `self` as the last committed duration to fall back to.
    /// Shared by the Settings amount field's commit and the unit picker's
    /// reinterpret-on-change commit — one rule for both: text that fails to
    /// parse, is empty, or is zero/negative reverts to `self.amount` (the
    /// last committed value); text that parses to a positive number but
    /// exceeds what `targetUnit` can express clamps to `targetUnit.maxAmount`
    /// instead of reverting the whole edit. Pure and view-independent so it
    /// unit-tests without a view host; the caller re-derives its displayed
    /// text from the duration it applies with the result.
    func resolveAmount(fromText text: String, targetUnit: Unit) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Int(trimmed), parsed >= 1 else {
            return min(amount, targetUnit.maxAmount)
        }
        return min(parsed, targetUnit.maxAmount)
    }
}

/// The outcome of reconciling the Settings field with a freshly read
/// `appState.hibernateIdleMinutes` — see
/// `HibernateIdleDuration.syncing(current:persistedMinutes:isFocused:force:)`.
struct HibernateIdleSyncResult: Equatable {
    var duration: HibernateIdleDuration
    var amountText: String
}

extension HibernateIdleDuration {
    /// Pure decision behind `SettingsView.syncHibernateIdleFromAppState`:
    /// whether, and how, to reconcile the field with the daemon's
    /// persisted value. Free of SwiftUI so it unit-tests without a view
    /// host; the view owns only the SwiftUI plumbing (`.onAppear`,
    /// `.onChange`, `@FocusState`) that calls this and applies the result.
    ///
    /// `isFocused` guards against an *external* delta stomping an
    /// in-progress edit; it is skipped when `force` is true, which marks
    /// this view reconciling its own settled commit RPC rather than an
    /// external change (success or failure — see
    /// `SettingsView.applyHibernateIdleDuration`). Returns `nil` — no
    /// change — only when that guard blocks the sync outright.
    ///
    /// When the guard passes, `duration` re-derives amount+unit from
    /// `persistedMinutes` ONLY when the totals actually differ — a
    /// genuine external delta. Re-deriving unconditionally would undo the
    /// user's deliberately chosen unit: committing "120" with unit
    /// Minutes would otherwise silently renormalize to "2 Hours" the
    /// moment the round-trip lands and this fires again with an unchanged
    /// total.
    ///
    /// `amountText`, however, is always recomputed from the (possibly
    /// unchanged) `duration.amount` whenever the guard passes — it does
    /// NOT share the totals-differ condition above. That distinction is
    /// what keeps the field populated the first time this fires: on
    /// `.onAppear`, `current` (the view's `@State` default) and
    /// `persistedMinutes` (loaded from the daemon) both routinely equal
    /// the shipped 30-minute default, so totals agree and `duration`
    /// stays as-is — but the text field still needs its initial value
    /// written, or it renders blank for the session (the regression this
    /// type exists to make testable).
    static func syncing(
        current: HibernateIdleDuration,
        persistedMinutes: Int,
        isFocused: Bool,
        force: Bool
    ) -> HibernateIdleSyncResult? {
        guard force || !isFocused else { return nil }
        let duration = current.totalMinutes != persistedMinutes
            ? HibernateIdleDuration(totalMinutes: persistedMinutes)
            : current
        return HibernateIdleSyncResult(duration: duration, amountText: String(duration.amount))
    }
}

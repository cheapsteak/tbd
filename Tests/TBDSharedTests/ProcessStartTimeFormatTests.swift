import Testing
import Foundation
@testable import TBDShared

/// `ProcessStartTime.format` renders a peer registry record's `procStart`, and
/// every consumer of that value — `RosterWatcher.admit`, the recycled-pid ghost
/// check, `tbd peer list` — decides liveness by comparing it against Claude
/// Code's own string with `==`. So the formatter is not a display concern: a
/// one-character disagreement fails every comparison, silently and everywhere.
///
/// **The defect these tests exist to catch.** The formatter used `ctime_r`,
/// which renders the *local* zone, while Claude Code writes `procStart` in
/// **UTC**. Measured against a live registry on a machine at `-0400`, 12 of 12
/// records disagreed with the formatter by exactly the offset — every record
/// read as not-live, so nothing was ever admitted and every live session
/// classified as a ghost. `TZ=UTC ps -o lstart=` reproduced each record
/// byte-for-byte; bare `ps` reproduced the bug.
///
/// **Why the old tests could not catch it, and what changed.** They asserted
/// the *shape* (24 characters, a regex, the space-padded day) and never the
/// *value*, and `RosterWatcherTests` fed one `liveProcStart` literal in as both
/// the record's value and the injected lookup's answer — the two sides were the
/// same string and could not disagree. Every test here therefore pins the
/// formatter against an expectation computed from UTC by machinery that shares
/// nothing with the implementation.
///
/// **The residual limit, stated plainly.** Proving zone-independence directly
/// would mean setting `TZ` and calling `tzset`, which is process-wide: all test
/// targets compile into one process and Swift Testing runs suites in parallel,
/// so it would corrupt any sibling suite formatting a local date, and
/// `.serialized` does not help — it orders bodies within a suite, not across
/// them (`Tests/CLAUDE.md`). The repo's convention is an injected `TimeZone`
/// instead, which is unavailable here because the whole point is that the
/// rendering is UTC unconditionally. So these tests fail hard on any machine
/// whose zone is not UTC — every developer box in a non-UTC zone, and the
/// pre-push hook — and on a UTC machine they lock the value without being able
/// to distinguish the two implementations. That is the right trade: on a UTC
/// machine the two implementations agree, which is precisely when the bug does
/// not bite.
///
/// Tier 1: pure computation over fixed epochs. No sleeps, no subprocesses, no
/// filesystem, no `~/tbd`, and nothing here reads or writes the process
/// environment.
@Suite("Process start time formatting")
struct ProcessStartTimeFormatTests {
    /// `ctime(3)`'s layout rebuilt from UTC calendar components, sharing no
    /// code with the implementation: the implementation goes through
    /// `gmtime_r`/`asctime_r`, this goes through Foundation's Gregorian
    /// calendar. `%2ld` on the day of month is the space padding, spelled out.
    private static func expectedUTCRendering(epoch: Int) -> String {
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return String(
            format: "%@ %@ %2ld %02ld:%02ld:%02ld %04ld",
            weekdays[parts.weekday! - 1], months[parts.month! - 1],
            parts.day!, parts.hour!, parts.minute!, parts.second!, parts.year!)
    }

    /// Byte-exact pins, hand-computed in UTC. Each epoch is chosen so a
    /// local-time formatter produces a *visibly* different string west of
    /// Greenwich, which is what the previous implementation did:
    ///
    /// - epoch 0 renders in the wrong **year** (`"Wed Dec 31 19:00:00 1969"` at
    ///   `-0500`), so even a coarse reader can see the failure;
    /// - the new-year epoch crosses a year boundary the other way;
    /// - the Aug 9 epoch lands on a single-digit day, where the local
    ///   rendering also shifts the padded day column;
    /// - the last entry is a **real value measured off this machine's live
    ///   registry** (pid 62061, `procStart` `"Sat Aug 29 04:17:34 2026"`,
    ///   confirmed equal to `TZ=UTC ps -o lstart=` for that pid). It is the
    ///   end-to-end anchor: if the formatter stops reproducing it, TBD has
    ///   stopped agreeing with Claude Code.
    @Test("fixed epochs render in UTC, byte for byte", arguments: [
        (0, "Thu Jan  1 00:00:00 1970"),
        (1_767_225_600, "Thu Jan  1 00:00:00 2026"),
        (1_786_244_767, "Sun Aug  9 03:06:07 2026"),
        (1_788_041_297, "Sat Aug 29 22:08:17 2026"),
        (1_787_977_054, "Sat Aug 29 04:17:34 2026"),
    ])
    func fixedEpochsRenderInUTC(epoch: Int, expected: String) throws {
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: TimeInterval(epoch))))
        #expect(formatted == expected)
        // The shape the record format requires, re-asserted on the pinned
        // value so a change to either half cannot drift from the other.
        #expect(formatted.count == 24)
    }

    /// The pins above fix five moments; this fixes the *rule* behind them. The
    /// spread — both sides of the epoch, a month boundary, two new-year
    /// boundaries, and the minutes on either side of both US DST transitions —
    /// exists so that no single constant offset can satisfy the whole table by
    /// accident: a local-time formatter's disagreement with UTC changes size
    /// across the DST pairs, and changes the day, month and year fields across
    /// the boundary cases.
    @Test("every rendered field is the UTC field, not the local one", arguments: [
        0,                  // the epoch itself
        -1,                 // one second before it, in the previous year
        1_772_325_000,      // 2026-03-01T00:30:00Z, just past a month boundary
        1_772_951_400,      // 2026-03-08T06:30:00Z, minutes before US DST starts
        1_772_955_000,      // 2026-03-08T07:30:00Z, minutes after it starts
        1_793_511_000,      // 2026-11-01T05:30:00Z, as US DST ends
        1_780_000_000,      // an arbitrary midsummer moment
        1_798_761_600,      // 2027-01-01T00:00:00Z, another year boundary
    ])
    func renderedFieldsAreTheUTCFields(epoch: Int) throws {
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: TimeInterval(epoch))))
        #expect(formatted == Self.expectedUTCRendering(epoch: epoch))
    }

    /// `Date()` rather than a constant, so the assertion keeps holding as the
    /// calendar moves — including across whatever DST transition the machine's
    /// own zone is next to, which is when a local-time formatter's disagreement
    /// with UTC changes size.
    @Test("the current moment renders in UTC too")
    func theCurrentMomentRendersInUTC() throws {
        // Whole seconds only: the formatter truncates toward zero on its way
        // into `time_t`, so a fractional Date would compare against a calendar
        // that rounds the other way for negative intervals.
        let epoch = Int(Date().timeIntervalSince1970)
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: TimeInterval(epoch))))
        #expect(formatted == Self.expectedUTCRendering(epoch: epoch))
    }

    /// `ctime(3)` space-pads the day of month; ICU has no specifier for that,
    /// which is why this is hand-rolled C rather than a `DateFormatter`. The
    /// column is load-bearing: `"Aug  5"` and `"Aug 5"` are different strings,
    /// and the comparison is `==`.
    ///
    /// The epochs are fixed rather than built from `Calendar.current`, so the
    /// assertion cannot quietly change meaning with the machine's zone.
    @Test("a single-digit day of month is space-padded, not zero-padded",
          arguments: [
            (1_785_931_200, "Wed Aug  5 12:00:00 2026"),
            (1_772_325_000, "Sun Mar  1 00:30:00 2026"),
          ])
    func singleDigitDayIsSpacePadded(epoch: Int, expected: String) throws {
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: TimeInterval(epoch))))
        #expect(formatted == expected)
        // Spelled out separately from the byte-exact compare above, so a
        // failure names the padding rather than just "the string differs".
        #expect(formatted.dropFirst(8).first == " ")
        #expect(formatted.count == 24)
    }

    /// A date this shape cannot express yields nil, never `""`.
    ///
    /// The distinction is the whole point of the recycled-pid check: it asks
    /// whether the `procStart` on a record still matches the `procStart` of the
    /// pid it is filed under, and two empty strings compare **equal**. A
    /// failure that returned `""` would report a ghost as live precisely when
    /// the formatter could say nothing at all.
    ///
    /// `asctime_r` refuses any year outside 1-9999 and `gmtime_r` refuses an
    /// out-of-range epoch; the non-finite cases would trap on the way into
    /// `time_t` without the guard in front of them.
    @Test("a date outside the renderable range yields nil, not an empty string")
    func undescribableDatesYieldNil() {
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: 1e12)) == nil)
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: -1e12)) == nil)
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: 1e18)) == nil)
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: .infinity)) == nil)
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: -.infinity)) == nil)
        #expect(ProcessStartTime.format(Date(timeIntervalSince1970: .nan)) == nil)
    }

    /// The boundary the case above sits just outside: the last second
    /// `asctime_r` will render is still rendered, so the nil branch is a real
    /// range check rather than an over-eager guard that discards live values.
    @Test("the last renderable second still renders")
    func theLastRenderableSecondRenders() throws {
        let formatted = try #require(
            ProcessStartTime.format(Date(timeIntervalSince1970: 253_402_300_799)))
        #expect(formatted == "Fri Dec 31 23:59:59 9999")
    }
}

import Foundation
import os

private let recordReaderLogger = Logger(subsystem: "com.tbd.daemon", category: "actuation-record")

/// Reads the actuation record back: the active `actuations.jsonl` plus its
/// rotated `actuations-<date>.jsonl` segments, in record order.
///
/// The writer's counterpart, and deliberately a separate type with no shared
/// state: it opens nothing the writer holds, takes no lock, and can run while
/// the daemon appends. A row that lands mid-read simply belongs to the next
/// read — the record is append-only, so nothing already returned can change.
///
/// **Unparseable lines are skipped, never thrown.** The writer goes to real
/// lengths to leave whole lines (`ActuationLog.appendWithOneRetry`), but the
/// cases it cannot cover — a crash between `write` and `fsync`, a hand-edit —
/// leave a fragment behind, and a reader that threw on one would let a single
/// junk byte blind an entire replay. One bad line costs one row.
struct ActuationRecordReader: Sendable {
    /// The active file. Rotated segments are looked for beside it.
    let activePath: String

    init(activePath: String) {
        self.activePath = activePath
    }

    /// `FileManager.default` is documented thread-safe for the three read-only
    /// calls below, and holding one would cost this type its `Sendable`
    /// conformance for nothing — the reader has no state worth injecting, and
    /// its tests read real files out of a temp directory.
    private var fileManager: FileManager { .default }

    /// The files that make up the record, oldest first: the rotated day
    /// segments in name order, then the active file.
    ///
    /// Segments are stamped `YYYY-MM-DD`, which sorts lexicographically, and
    /// rotation writes no header, footer or marker row — so concatenating them
    /// *is* the record (§6). The active file always comes last: it holds the
    /// newest rows.
    ///
    /// **Sorted by (day, collision index), not by name.** A plain `.sorted()`
    /// gets the one case rotation's collision handling exists for exactly
    /// backwards: `ActuationLog.rotationDestination` leaves the earlier segment
    /// as `actuations-<day>.jsonl` and names the later one
    /// `actuations-<day>-1.jsonl`, and `-` (0x2D) sorts before `.` (0x2E), so
    /// name order puts the later segment first. That writer chose a numeric
    /// suffix over concatenation precisely so nobody's record would be silently
    /// reordered; reading it back by name would reorder it anyway. The rule is
    /// cheap to state and the cost of being wrong is no longer cosmetic —
    /// `DeliveryRecord.statuses` reads outcomes in record order.
    func segmentPaths() -> [String] {
        let directory = (activePath as NSString).deletingLastPathComponent
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        let activeName = (activePath as NSString).lastPathComponent
        let rotated = names
            .filter { $0 != activeName && $0.hasPrefix("actuations-") && $0.hasSuffix(".jsonl") }
            .map { (name: $0, order: Self.segmentOrder(ofName: $0)) }
            .sorted { ($0.order.day, $0.order.index) < ($1.order.day, $1.order.index) }
            .map { (directory as NSString).appendingPathComponent($0.name) }
        guard fileManager.fileExists(atPath: activePath) else { return rotated }
        return rotated + [activePath]
    }

    /// A rotated segment's place in the record: its stamped day, and which
    /// segment of that day it is. `actuations-2026-08-05.jsonl` is index 0 and
    /// `actuations-2026-08-05-1.jsonl` is index 1, matching the order
    /// `ActuationLog.rotationDestination` writes them in.
    ///
    /// A name that fits neither shape keeps its whole stem as the day and sorts
    /// by that — unknown, but stable and never interleaved into a real day.
    static func segmentOrder(ofName name: String) -> (day: String, index: Int) {
        let stem = String(name.dropFirst("actuations-".count).dropLast(".jsonl".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 4, let index = Int(parts[3]) {
            return (parts[0..<3].joined(separator: "-"), index)
        }
        return (stem, 0)
    }

    /// Every parseable row in the record, oldest first.
    func readRows() -> [ActuationRow] {
        segmentPaths().flatMap { rows(inFileAt: $0) }
    }

    /// The segments that can still contain a row at or after `since`, oldest
    /// first.
    ///
    /// Walks `segmentPaths()` **newest-first**, taking whole segments, and
    /// stops after the first segment whose oldest parseable row predates
    /// `since` — **that segment is included**, because a request row can
    /// precede the cutoff while the outcome that settles it lands after, and a
    /// join that dropped the request would report a settled act as owing an
    /// observation forever.
    ///
    /// **A segment with no parseable row does not terminate the walk.** Ending
    /// there would let one corrupt or hand-emptied file silently truncate the
    /// whole record — the same failure `rows(inLinesOf:)` refuses one level
    /// down, where one bad line costs one row and never the file.
    ///
    /// Whole segments rather than a row-level cutoff: rotation writes no header
    /// or marker, so a segment is the record's own unit, and a caller that
    /// wants a row-level window applies it to the rows this returns.
    func segmentPaths(since: Date) -> [String] {
        var covering: [String] = []
        for path in segmentPaths().reversed() {
            covering.append(path)
            let oldest = rows(inFileAt: path)
                .compactMap { DeliveryRecord.parseTimestamp($0.ts) }
                .min()
            if let oldest, oldest < since { break }
        }
        return covering.reversed()
    }

    /// Rows from the segments that can still contain a row at or after `since`,
    /// oldest first.
    ///
    /// Oldest-first is contract, not convenience: `DeliveryRecord.statuses`
    /// walks rows in record order and a retried send shares its original act's
    /// id, so reversing them would leave a stale observation standing as an
    /// act's final word.
    ///
    /// The covering segments are parsed twice — once by `segmentPaths(since:)`
    /// to find the cutoff and once here. That is deliberate: the alternative is
    /// a second walk implementation, and the lookbacks this serves span one or
    /// two day-segments.
    func readRows(since: Date) -> [ActuationRow] {
        segmentPaths(since: since).flatMap { rows(inFileAt: $0) }
    }

    /// Every parseable row in one segment.
    func rows(inFileAt path: String) -> [ActuationRow] {
        guard let data = fileManager.contents(atPath: path) else {
            recordReaderLogger.debug(
                "actuation record segment unreadable: \(path, privacy: .public)")
            return []
        }
        return Self.rows(inLinesOf: data, path: path)
    }

    /// Decode one row per newline-delimited line, skipping what will not parse.
    ///
    /// Splitting on the byte rather than on `String` lines keeps a segment with
    /// invalid UTF-8 in it — the other thing a torn write leaves — costing only
    /// the lines it damaged.
    static func rows(inLinesOf data: Data, path: String = "") -> [ActuationRow] {
        let decoder = JSONDecoder()
        var rows: [ActuationRow] = []
        var skipped = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let row = try? decoder.decode(ActuationRow.self, from: Data(line)) {
                rows.append(row)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            recordReaderLogger.debug(
                """
                skipped \(skipped, privacy: .public) unparseable line(s) \
                in \(path, privacy: .public)
                """)
        }
        return rows
    }
}

// MARK: - The query-time delivery rule

/// What the record says about one dispatched payload's delivery.
///
/// Computed, never stored. No row ever says `unconfirmed`: that is the whole
/// design (§12). Writing a "gave up" row would make the record's claims depend
/// on a sweep having run, and a daemon that was down when the deadline passed
/// would leave a permanent lie behind. Because the rule lives here instead, an
/// act whose observation never ran renders unconfirmed by construction, and a
/// late observation simply moves it.
enum DeliveryStatus: Sendable, Equatable {
    /// An observation ran and established something. What it established is the
    /// `ObservedResult` — including `notLanded` and `undetermined`, which are
    /// findings, not absences.
    case observed(ObservedResult)
    /// Verification is armed and the acknowledgement deadline has not passed
    /// yet. Nothing is owed and nothing is wrong.
    case awaitingObservation
    /// Verification is armed, the deadline has passed, and no *observed*
    /// outcome confirms the act. Renders as loudly as an anomaly, and is the
    /// startup replay's work list: these are the acts whose observation the
    /// daemon performs late.
    case unconfirmed
}

/// One act and what the record says about its delivery.
struct DeliveryAssessment: Sendable, Equatable {
    /// The request row — the act itself, not its outcomes.
    let request: ActuationRow
    let status: DeliveryStatus
}

/// The query-time delivery rule of §12, as a pure function over parsed rows.
///
/// No daemon, no filesystem, no clock: rows in, `now` in, assessments out. The
/// startup replay is its first consumer and the account will be its second,
/// and both want the same answer from the same evidence.
enum DeliveryRecord {
    /// How long after a request row's timestamp an observation is owed.
    ///
    /// §13's compiled-numbers table: "Post-intervention re-check — 60 s — §4
    /// step 7, §12". The one place this repo spells that number; §12's ladder
    /// and §7's in-memory timers both derive their deadline from it, so a
    /// second copy would be a second answer.
    static let acknowledgementDeadline: TimeInterval = 60

    /// The delivery status of every act in `rows` that armed verification.
    ///
    /// Acts that did not arm it are absent from the result entirely — they are
    /// owed no observation, so there is no honest status to report about them,
    /// and reporting `unconfirmed` for a plain send would drown the real ones.
    ///
    /// The join is deliberately narrow: only an outcome row whose `result` is
    /// an **observed** value counts as confirming. A synchronous `dispatched`
    /// is the second rung of the ladder and says only that the transport
    /// accepted the payload — the exact claim the field failure this whole
    /// mechanism exists for made falsely, for hours, into a dead pane. So a
    /// dispatched-only act past its deadline still renders `unconfirmed`.
    static func statuses(
        in rows: [ActuationRow],
        now: Date,
        deadline: TimeInterval = acknowledgementDeadline
    ) -> [DeliveryAssessment] {
        // What each act's outcomes leave it standing at, walked in record order.
        //
        // Order matters, and the retry is why: it shares the original act's id
        // by design, so a retried send's ladder is
        // `dispatched → not-landed → dispatched → landed`, four rows on one id.
        // Taking "the newest observed row" alone would let a restart between the
        // retry's dispatch and its own re-check leave the stale `not-landed`
        // standing as the act's final word — settled, so the startup replay
        // skips it, and the retry is never observed at all. A delivery that
        // happened after the last observation is a delivery still owed one.
        enum Standing {
            /// A payload reached the pane and nothing has observed it since.
            case awaitingObservation
            /// The newest observation, with no later delivery after it.
            case observed(ObservedResult)
            /// The transport never accepted this act at all.
            case neverDispatched
        }
        var standing: [String: Standing] = [:]
        for row in rows where row.kind == .outcome {
            guard let confirms = row.confirms else { continue }
            if let observed = row.result?.observed {
                standing[confirms] = .observed(observed)
                continue
            }
            switch row.result {
            case .synchronous(.dispatched):
                standing[confirms] = .awaitingObservation
            case .synchronous(.refused), .synchronous(.transportFailed):
                // A refusal only settles an act that never got off the ground.
                // The same result on an act that already dispatched is the
                // single retry failing, which erases neither the delivery that
                // did happen nor the observation of it.
                if standing[confirms] == nil { standing[confirms] = .neverDispatched }
            default: break
            }
        }

        return rows.compactMap { row in
            guard row.kind != .outcome, row.verify == true, !row.id.isEmpty else { return nil }
            switch standing[row.id] {
            case .observed(let observed):
                return DeliveryAssessment(request: row, status: .observed(observed))
            case .neverDispatched:
                // `verify == true` says the caller *asked* for an observation,
                // not that one is owed: the request row is written before the
                // flag check and before the pane consultation, so a refused send
                // carries the flag too. Nothing was typed, so nothing can have
                // landed — and without this the act would render unconfirmed
                // forever and the startup replay would "observe" it, writing a
                // landing verdict about a payload that never reached a pane.
                return nil
            case .awaitingObservation, nil:
                break
            }
            // Fail-closed on an unreadable timestamp: a deadline that cannot be
            // computed is not a deadline that has not passed. §12's rule is
            // "never default to landed", and this is the same instinct one
            // level down.
            guard let stamped = parseTimestamp(row.ts) else {
                return DeliveryAssessment(request: row, status: .unconfirmed)
            }
            let due = stamped.addingTimeInterval(deadline)
            return DeliveryAssessment(
                request: row, status: now < due ? .awaitingObservation : .unconfirmed)
        }
    }

    /// Reads back what `ActuationLog` stamps: ISO8601 UTC, with fractional
    /// seconds. The fractionless form parses too — §6's own example rows are
    /// written that way, and a hand-authored fixture will be.
    static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

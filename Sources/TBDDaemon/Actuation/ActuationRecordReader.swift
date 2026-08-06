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
    /// Name order is chronological by construction — segments are stamped
    /// `YYYY-MM-DD`, which sorts lexicographically — and rotation writes no
    /// header, footer or marker row, so concatenating them *is* the record
    /// (§6). The active file always comes last: it holds the newest rows.
    func segmentPaths() -> [String] {
        let directory = (activePath as NSString).deletingLastPathComponent
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        let activeName = (activePath as NSString).lastPathComponent
        let rotated = names
            .filter { $0 != activeName && $0.hasPrefix("actuations-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { (directory as NSString).appendingPathComponent($0) }
        guard fileManager.fileExists(atPath: activePath) else { return rotated }
        return rotated + [activePath]
    }

    /// Every parseable row in the record, oldest first.
    func readRows() -> [ActuationRow] {
        segmentPaths().flatMap { rows(inFileAt: $0) }
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
        // The newest observed result per confirmed request. Later rows win:
        // one request may carry several outcomes (dispatched → not-landed →
        // dispatched → landed-and-acting), and the last observation is the one
        // that still stands.
        var observations: [String: ObservedResult] = [:]
        // Which acts the transport ever accepted, and which it answered with a
        // terminal refusal. `verify == true` says the caller *asked* for an
        // observation, not that one is owed: the request row is written before
        // the flag check and before the pane consultation, so a refused send
        // carries the flag too. An act that never dispatched can have landed
        // nothing, so it owes no observation — and without this it would render
        // unconfirmed forever and be "observed" by the startup replay, writing a
        // landing verdict about a payload that never reached a pane.
        var everDispatched: Set<String> = []
        var refusedOrFailed: Set<String> = []
        for row in rows where row.kind == .outcome {
            guard let confirms = row.confirms else { continue }
            if let observed = row.result?.observed {
                observations[confirms] = observed
                continue
            }
            switch row.result {
            case .synchronous(.dispatched): everDispatched.insert(confirms)
            case .synchronous(.refused), .synchronous(.transportFailed):
                refusedOrFailed.insert(confirms)
            default: break
            }
        }

        return rows.compactMap { row in
            guard row.kind != .outcome, row.verify == true, !row.id.isEmpty else { return nil }
            if let observed = observations[row.id] {
                return DeliveryAssessment(request: row, status: .observed(observed))
            }
            // Settled synchronously and never dispatched: the refusal or the
            // transport failure IS the whole answer. A dispatch anywhere in the
            // act's outcomes outranks a later refusal, which can only be the
            // single retry failing after a real first delivery.
            if refusedOrFailed.contains(row.id) && !everDispatched.contains(row.id) {
                return nil
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

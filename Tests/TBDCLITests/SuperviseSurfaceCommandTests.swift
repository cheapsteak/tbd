import ArgumentParser
import Foundation
import Testing
import TBDShared

@testable import TBDCLI

// The sweep program's three surfaces — `readout`, `brief`, `ledger`. Tier 1:
// argument parsing and pure functions only, so nothing here needs a daemon, a
// socket, or the machine's own clock and time zone.

@Suite("tbd supervise sweep-surface command registration and parsing")
struct SuperviseSurfaceCommandParsingTests {
    // MARK: registration

    /// The full inventory is pinned by `groupRegistersEverySubcommand` in
    /// `SuperviseCommandParsingTests`; this one names the three surfaces the
    /// sweep program's whole contract with TBD consists of.
    @Test func groupRegistersTheThreeSweepSurfaces() {
        let names = Set(SuperviseCommand.configuration.subcommands.map { $0._commandName })
        #expect(names.isSuperset(of: ["readout", "brief", "ledger"]))
    }

    @Test func rootRoutesEachSweepSurface() throws {
        #expect(try TBDCommand.parseAsRoot(
            ["supervise", "readout", "--project", "acme-platform"]) is SuperviseReadoutCommand)
        #expect(try TBDCommand.parseAsRoot(
            ["supervise", "brief", "--project", "acme-platform"]) is SuperviseBriefCommand)
        #expect(try TBDCommand.parseAsRoot([
            "supervise", "ledger", "--project", "acme-platform", "--since", "22:00",
        ]) is SuperviseLedgerCommand)
    }

    // MARK: readout

    @Test func readoutParsesTheProjectOption() throws {
        #expect(try SuperviseReadoutCommand.parse(
            ["--project", "acme-platform"]).project == "acme-platform")
    }

    @Test func readoutRequiresAProject() {
        #expect(throws: (any Error).self) { _ = try SuperviseReadoutCommand.parse([]) }
    }

    /// JSON is the only output this surface has — its consumer is a program —
    /// so there is deliberately no `--json` flag to pass.
    @Test func readoutHasNoJSONFlagBecauseJSONIsItsOnlyOutput() {
        #expect(throws: (any Error).self) {
            _ = try SuperviseReadoutCommand.parse(["--project", "acme-platform", "--json"])
        }
    }

    // MARK: ledger

    @Test func ledgerParsesProjectAndSince() throws {
        let cmd = try SuperviseLedgerCommand.parse([
            "--project", "acme-platform", "--since", "2026-08-15T02:10:00Z",
        ])
        #expect(cmd.project == "acme-platform")
        #expect(cmd.since == "2026-08-15T02:10:00Z")
    }

    @Test func ledgerRequiresBothProjectAndSince() {
        #expect(throws: (any Error).self) {
            _ = try SuperviseLedgerCommand.parse(["--project", "acme-platform"])
        }
        #expect(throws: (any Error).self) {
            _ = try SuperviseLedgerCommand.parse(["--since", "22:00"])
        }
    }

    // MARK: brief

    @Test func briefParsesTheProjectOptionAndTakesNoTextArgument() throws {
        #expect(try SuperviseBriefCommand.parse(
            ["--project", "acme-platform"]).project == "acme-platform")
        // The briefing arrives on stdin, never as an argument.
        #expect(throws: (any Error).self) {
            _ = try SuperviseBriefCommand.parse(["--project", "acme-platform", "some text"])
        }
    }

    @Test func briefRequiresAProject() {
        #expect(throws: (any Error).self) { _ = try SuperviseBriefCommand.parse([]) }
    }

    // MARK: project names

    /// All three surfaces validate `--project` through the one guard, so a
    /// whitespace-only name is refused before any socket call — including the
    /// newline-only form `CharacterSet.whitespaces` would let through.
    @Test func aWhitespaceOnlyProjectIsRefusedOnEverySweepSurface() throws {
        for value in ["", "   ", "\n", "\t \n"] {
            let readout = try SuperviseReadoutCommand.parse(["--project", value])
            #expect(throws: CLIError.self) {
                _ = try requireSupervisionProjectName(readout.project)
            }
            let brief = try SuperviseBriefCommand.parse(["--project", value])
            #expect(throws: CLIError.self) {
                _ = try requireSupervisionProjectName(brief.project)
            }
            let ledger = try SuperviseLedgerCommand.parse(
                ["--project", value, "--since", "30m"])
            #expect(throws: CLIError.self) {
                _ = try requireSupervisionProjectName(ledger.project)
            }
        }
    }
}

@Suite("tbd supervise ledger --since")
struct SuperviseSinceParsingTests {
    /// A fixed zone and a fixed `now`, so every assertion below reads the same
    /// on any machine on any morning. 2026-08-15T16:00:00Z is 09:00 PDT.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    /// A fixture instant. Force-unwrapped: a literal that does not parse is a
    /// broken test rather than a finding, and it should say so loudly.
    private func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private var now: Date { instant("2026-08-15T16:00:00Z") }

    /// Assert a value is refused **by the grammar** — the refusal that names all
    /// three shapes — rather than merely throwing something.
    ///
    /// The distinction is load-bearing, and a weaker assertion hid a hole here
    /// once: `#expect(throws: CLIError.self)` passes for `24:00` even with the
    /// hour range widened to accept it, because hour 24 then simply matches no
    /// instant and the *search* refuses instead. Asserting the composed refusal
    /// makes the range guard the thing under test.
    private func expectGrammarRefusal(_ value: String, at reference: Date? = nil) {
        do {
            let parsed = try parseSupervisionSince(
                value, now: reference ?? now, calendar: calendar)
            // Recorded as an Error, not a String: only `Issue.record(some Error)`
            // puts the text on the primary failure line, and here the text —
            // which value slipped through — is the entire finding.
            Issue.record(SinceValueUnexpectedlyAccepted(value: value, parsed: parsed))
        } catch let error as CLIError {
            #expect(
                error.description == supervisionSinceRefusal(value),
                "refusal for \"\(value)\" must be the grammar refusal naming all three shapes")
        } catch {
            Issue.record(SinceRefusalWasNotACLIError(value: value, underlying: error))
        }
    }

    private struct SinceValueUnexpectedlyAccepted: Error, CustomStringConvertible {
        let value: String
        let parsed: Date
        var description: String {
            "--since \"\(value)\" must be refused, but parsed as \(parsed)"
        }
    }

    private struct SinceRefusalWasNotACLIError: Error, CustomStringConvertible {
        let value: String
        let underlying: any Error
        var description: String {
            "--since \"\(value)\" must be refused with a CLIError, got \(underlying)"
        }
    }

    // MARK: shape one — ISO-8601

    @Test func isoWithZParsesToThatExactInstant() throws {
        #expect(try parseSupervisionSince(
            "2026-08-15T02:10:00Z", now: now, calendar: calendar)
            == (instant("2026-08-15T02:10:00Z")))
    }

    @Test func isoWithAnOffsetParsesToTheSameInstantItNames() throws {
        #expect(try parseSupervisionSince(
            "2026-08-15T02:10:00-07:00", now: now, calendar: calendar)
            == (instant("2026-08-15T09:10:00Z")))
    }

    @Test func isoWithFractionalSecondsParses() throws {
        let parsed = try parseSupervisionSince(
            "2026-08-15T02:10:00.482Z", now: now, calendar: calendar)
        let expected = instant("2026-08-15T02:10:00Z").addingTimeInterval(0.482)
        #expect(abs(parsed.timeIntervalSince(expected)) < 0.001)
    }

    /// The offset is what makes the ISO shape unambiguous, so a timestamp
    /// without one is refused rather than read in whatever zone the machine
    /// happens to be in.
    @Test func isoWithoutAnOffsetIsRefused() {
        expectGrammarRefusal("2026-08-15T02:10:00")
    }

    @Test func aShellExpandedTrailingNewlineIsTolerated() throws {
        #expect(try parseSupervisionSince(
            "2026-08-15T02:10:00Z\n", now: now, calendar: calendar)
            == (instant("2026-08-15T02:10:00Z")))
        #expect(try parseSupervisionSince("22:00\n", now: now, calendar: calendar)
            == (instant("2026-08-15T05:00:00Z")))
        #expect(try parseSupervisionSince("30m\n", now: now, calendar: calendar)
            == (now.addingTimeInterval(-1800)))
    }

    // MARK: shape two — bare HH:MM, most recent past occurrence

    @Test func clockTimeEarlierTodayResolvesToToday() throws {
        // 02:10 PDT on the 15th, read at 09:00 PDT on the 15th.
        #expect(try parseSupervisionSince("02:10", now: now, calendar: calendar)
            == (instant("2026-08-15T09:10:00Z")))
    }

    @Test func clockTimeStillAheadTodayRollsBackToYesterday() throws {
        // 22:00 has not happened yet today, so it means last night's.
        #expect(try parseSupervisionSince("22:00", now: now, calendar: calendar)
            == (instant("2026-08-15T05:00:00Z")))
        #expect(try parseSupervisionSince("23:59", now: now, calendar: calendar)
            == (instant("2026-08-15T06:59:00Z")))
    }

    @Test func midnightAndTheCurrentMinuteAreBothReachable() throws {
        #expect(try parseSupervisionSince("00:00", now: now, calendar: calendar)
            == (instant("2026-08-15T07:00:00Z")))
        // "Most recent past occurrence" includes this very minute.
        #expect(try parseSupervisionSince("09:00", now: now, calendar: calendar)
            == (instant("2026-08-15T16:00:00Z")))
    }

    @Test func aSingleDigitHourIsAcceptedAndMeansTheSameTime() throws {
        #expect(try parseSupervisionSince("2:10", now: now, calendar: calendar)
            == (try parseSupervisionSince("02:10", now: now, calendar: calendar)))
    }

    /// A wall clock out of range is a mistake, not something to clamp: `24:00`
    /// would silently become midnight and `99:99` would become 23:59, each
    /// answering a question the operator did not ask.
    @Test func outOfRangeClockTimesAreRefusedRatherThanClamped() throws {
        for value in ["24:00", "25:00", "99:99", "12:60", "23:99"] {
            expectGrammarRefusal(value)
        }
    }

    /// The digits test is explicit because `Int("+2")` succeeds — a sign would
    /// otherwise smuggle `+2:10` through as `02:10`.
    @Test func malformedClockTimesAreRefused() throws {
        for value in ["+2:10", "-2:10", "2:1", "023:10", "2:100", "22:", ":00", "22", "١٢:٣٠"] {
            expectGrammarRefusal(value)
        }
    }

    /// **The daylight-saving fall-back case.** On 1 November 2026 the US west
    /// coast puts its clocks back at 02:00 PDT, so local `01:30` happens twice:
    /// once at 08:30Z (PDT) and again at 09:30Z (PST). The most recent past
    /// occurrence is the *later* of the two, and the assertion pins that it is
    /// not the earlier one.
    @Test func anAmbiguousFallBackTimeResolvesToTheLaterInstant() throws {
        let morningAfter = instant("2026-11-01T18:00:00Z")  // 10:00 PST
        let resolved = try parseSupervisionSince(
            "01:30", now: morningAfter, calendar: calendar)
        #expect(resolved == (instant("2026-11-01T09:30:00Z")))
        #expect(resolved != (instant("2026-11-01T08:30:00Z")))
    }

    // MARK: shape three — bare relative duration

    @Test func durationsAreReadAsThatLongAgo() throws {
        let fixedNow = now
        let cases: [(String, TimeInterval)] = [
            ("90s", 90), ("30m", 1800), ("2h", 7200), ("3d", 259_200),
        ]
        for (value, seconds) in cases {
            #expect(try parseSupervisionSince(value, now: fixedNow, calendar: calendar)
                == fixedNow.addingTimeInterval(-seconds), "\(value)")
        }
    }

    /// Zero is a legitimate magnitude: `0m` means now, which is an empty window
    /// rather than an error.
    @Test func aZeroDurationIsAcceptedAndMeansNow() throws {
        let fixedNow = now
        #expect(try parseSupervisionSince("0m", now: fixedNow, calendar: calendar) == fixedNow)
        #expect(try parseSupervisionSince("0s", now: fixedNow, calendar: calendar) == fixedNow)
    }

    @Test func negativeAndNonIntegerMagnitudesAreRefused() throws {
        for value in ["-5m", "-0s", "1.5h", "1,5h", "1e3s", "+2h", " 2 h"] {
            expectGrammarRefusal(value)
        }
    }

    @Test func unknownUnitsAndBareNumbersAreRefused() throws {
        for value in ["30", "5x", "2w", "m", "s", "hour", "2hours", "", "   ", "yesterday"] {
            expectGrammarRefusal(value)
        }
    }

    /// A magnitude that overflows the multiplication is refused rather than
    /// wrapping into a nonsense instant.
    @Test func anAbsurdMagnitudeIsRefusedRatherThanWrapping() throws {
        for value in ["9223372036854775807d", "99999999999999999999s"] {
            expectGrammarRefusal(value)
        }
    }

    // MARK: the refusal

    @Test func theRefusalNamesAllThreeShapesWithAnExampleOfEach() throws {
        let fixedNow = now
        do {
            _ = try parseSupervisionSince("yesterday", now: fixedNow, calendar: calendar)
            Issue.record("expected a refusal")
        } catch let error as CLIError {
            let text = error.description
            #expect(text.contains("yesterday"))
            #expect(text.contains("ISO-8601"))
            #expect(text.contains("2026-08-15T02:10:00Z"))
            #expect(text.contains("HH:MM"))
            #expect(text.contains("22:00"))
            #expect(text.contains("duration"))
            #expect(text.contains("30m"))
        } catch {
            Issue.record("expected CLIError, got \(error)")
        }
    }
}

@Suite("tbd supervise brief exit codes and the size bound")
struct SuperviseBriefResultTests {
    /// **The whole mapping, pinned by name.** `SupervisionBriefOutcome`'s seven
    /// values are contract, and the assertion against `allCases.count` is what
    /// makes an eighth outcome added later fail here rather than slip through
    /// untested.
    @Test func exitCodeMappingCoversEveryOutcomeByName() {
        let expected: [SupervisionBriefOutcome: Int32] = [
            .delivered: 0,
            .refusedPaused: 75,
            .refusedOff: 1,
            .refusedRateLimit: 1,
            .refusedSize: 1,
            .transportFailed: 1,
            .noLiveSupervisor: 1,
        ]
        #expect(SupervisionBriefOutcome.allCases.count == 7)
        #expect(expected.count == SupervisionBriefOutcome.allCases.count)
        #expect(Set(expected.keys) == Set(SupervisionBriefOutcome.allCases))
        for (outcome, code) in expected {
            #expect(supervisionBriefExitCode(outcome) == code, "\(outcome.rawValue)")
        }
    }

    /// 75 is the one pinned numeric code, and it means exactly one thing: the
    /// brake is engaged, so retry when supervision resumes. Nothing else may
    /// answer with it, or a script branching on 75 would retry a refusal whose
    /// remedy is not waiting.
    @Test func onlyABrakeRefusalIsSeventyFive() {
        #expect(supervisionBriefExitCode(.refusedPaused) == SupervisionBriefing.pausedExitCode)
        #expect(SupervisionBriefing.pausedExitCode == 75)
        for outcome in SupervisionBriefOutcome.allCases where outcome != .refusedPaused {
            #expect(supervisionBriefExitCode(outcome) != 75, "\(outcome.rawValue)")
        }
    }

    @Test func deliveredIsTheOnlyZero() {
        for outcome in SupervisionBriefOutcome.allCases where outcome != .delivered {
            #expect(supervisionBriefExitCode(outcome) != 0, "\(outcome.rawValue)")
        }
        #expect(supervisionBriefExitCode(.delivered) == 0)
    }

    // MARK: what gets sent

    /// **An oversize briefing is sent, not refused locally.** The pipeline's
    /// first step is unconditional — timestamp and attribute, which is what
    /// moves the project's liveness record — and it comes before the size
    /// refusal. A submission the CLI turned away would move no record, so a
    /// sweep program with a runaway composer would read as *silent* rather than
    /// broken, counterfeiting the one signal reserved for "nobody looked".
    ///
    /// `supervisionBriefParams` composes params and cannot refuse: it does not
    /// throw, so the early refusal cannot come back without changing its
    /// signature. This test pins the other half — that the payload arrives
    /// whole rather than truncated at the bound.
    @Test func anOversizeBriefingIsSentWholeRatherThanRefusedLocally() {
        let oversize = Data(
            repeating: UInt8(ascii: "a"), count: SupervisionBriefing.maxBriefingBytes + 1)
        let params = supervisionBriefParams(project: "acme-platform", stdin: oversize)
        #expect(params.project == "acme-platform")
        #expect(params.text.utf8.count == SupervisionBriefing.maxBriefingBytes + 1)
    }

    /// **An empty submission is still a submission** — the attested "looked,
    /// found nothing". It is composed and sent like any other, because refusing
    /// it locally is the same hole: no submission, no contact, and a calm night
    /// becomes indistinguishable from a dead sensor.
    @Test func anEmptySubmissionIsComposedAndSent() {
        let params = supervisionBriefParams(project: "acme-platform", stdin: Data())
        #expect(params.project == "acme-platform")
        #expect(params.text.isEmpty)
    }

    /// The bytes go through as typed — no trimming, no normalization. TBD never
    /// parses a briefing, so nothing here is entitled to edit one.
    @Test func theBriefingTextIsPassedThroughVerbatim() {
        let composed = "  findings:\n\n  - acme-web is stalled\n"
        let params = supervisionBriefParams(
            project: " staging ", stdin: Data(composed.utf8))
        #expect(params.text == composed)
        #expect(params.project == " staging ")
    }

    /// `refused-size` remains a value the *daemon* can answer with, and the
    /// mapping covers it — the bound is real, it is just enforced on the side
    /// that records contact first.
    @Test func refusedSizeIsStillAnOutcomeTheMappingCovers() {
        #expect(supervisionBriefExitCode(.refusedSize) == supervisionBriefRefusedExitCode)
        #expect(supervisionBriefExitCode(.refusedSize) != 0)
        #expect(supervisionBriefExitCode(.refusedSize) != SupervisionBriefing.pausedExitCode)
    }
}

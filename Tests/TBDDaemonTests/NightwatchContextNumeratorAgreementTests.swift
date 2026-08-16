import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2. One session's context numerator is computed twice in this product —
/// once in Swift, for `session.states`, and once in the Python that the
/// nightwatch desk runs — and both numbers are put in front of the same
/// operator. Two selection rules over one transcript is not a rounding
/// difference: it is two answers with nothing to say which is right.
///
/// So the agreement is asserted by running both implementations over the same
/// bytes, rather than by reading the two sources and believing they match. The
/// duplication of the rule is unavoidable across languages; the duplication
/// going *unnoticed* is what this suite is for.
@Suite("Nightwatch context numerator agrees with ContextLoadReader")
struct NightwatchContextNumeratorAgreementTests {

    // MARK: - Harness

    /// What the shipped `tick.py` answers for one transcript, plus the two
    /// constants it must share with the Swift side.
    private struct PythonAnswer {
        let tokens: Int?
        let assumedWindow: Int
        let tailWindowBytes: Int
    }

    /// Loads the installed `tick.py` as a module and calls into it directly.
    /// `--selftest` proves the script agrees with itself; only this proves it
    /// agrees with `ContextLoadReader`.
    private static let driver = """
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("nightwatch_tick", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    print(json.dumps({"tokens": mod.context_tokens(sys.argv[2]),
                      "assumed_window": mod.ASSUMED_WINDOW,
                      "tail_window": mod.TAIL_WINDOW_BYTES}))
    """

    /// The driver exited non-zero — almost always because `context_tokens`
    /// raised. Carries the traceback so the failure names the defect.
    private struct DriverFailure: Error, CustomStringConvertible {
        let status: Int32
        let stderr: String
        var description: String {
            "tick.py driver exited \(status) instead of answering — "
                + "context_tokens raised on a shape it must tolerate:\n\(stderr)"
        }
    }

    private func askPython(tickPath: String, transcriptPath: String) throws -> PythonAnswer {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", "-c", Self.driver, tickPath, transcriptPath]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        // Thrown, not `#expect`ed: a raise inside `context_tokens` prints
        // nothing on stdout, so an expectation here would be followed by an
        // opaque JSON-parse error and the traceback — the finding — would never
        // reach the failure line. `Issue.record(_: some Error)` is the only
        // shape that carries it there.
        guard proc.terminationStatus == 0 else {
            throw DriverFailure(status: proc.terminationStatus, stderr: stderr)
        }
        let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        let root = try #require(object, "tick.py driver printed no JSON. stderr:\n\(stderr)")
        return PythonAnswer(
            tokens: root["tokens"] as? Int,
            assumedWindow: try #require(root["assumed_window"] as? Int),
            tailWindowBytes: try #require(root["tail_window"] as? Int)
        )
    }

    /// One assistant record whose three window-relevant buckets sum to `total`.
    private func usageRecord(_ total: Int) throws -> String {
        let usage = ["input_tokens": total - 30,
                     "cache_creation_input_tokens": 20,
                     "cache_read_input_tokens": 10]
        let data = try JSONSerialization.data(withJSONObject: ["message": ["usage": usage]])
        return String(decoding: data, as: UTF8.self)
    }

    private func writeTranscript(_ lines: [String], in dir: URL) throws -> String {
        let path = dir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: path)
        return path.path
    }

    // MARK: - The agreement

    @Test("Both implementations read the same numerator out of the same transcript")
    func numeratorsAgree() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-ctx-agree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginDirWriter(applicationSupportRoot: root.path).writePlugin()
        let tick = root.appendingPathComponent("TBD/plugin/skills/nightwatch/scripts/tick.py").path

        // Each case is one where a plausible *other* rule gives a different
        // answer, so agreement here is evidence rather than coincidence.
        let cases: [(name: String, lines: [String])] = try [
            // Largest ≠ last. A parent session's subagents append into the same
            // file, so "largest in the tail" and "what this session carries"
            // diverge by an order of magnitude on an ordinary desk transcript.
            ("largest is not last", [usageRecord(180_000), usageRecord(12_345)]),
            // Unparseable lines and records without a usage block are skipped
            // by both, rather than ending the read.
            ("noise after the last usage record",
             [usageRecord(41_000), "not json at all", #"{"message":{}}"#]),
            // Beyond the tail window: both bound the read, so both answer
            // "unknown" rather than reporting a figure from further back.
            ("usage record beyond the tail window",
             [usageRecord(999_999),
              #"{"filler":"\#(String(repeating: "x", count: ContextLoadReader.defaultTailWindowBytes + 4096))"}"#]),
            // Nothing to read at all.
            ("no usage records anywhere", [#"{"message":{}}"#]),
            // A bucket the record spells as `null`, and one spelled as a
            // string. Swift counts each as nothing (`as? Int ?? 0`), so Python
            // has to as well — and the cost of getting this one wrong is not a
            // disagreeing number, it is a `TypeError` out of `burn_risk`, which
            // `tick.py` calls inline in its fleet loop with no `try`. One such
            // record in one agent's transcript would end the tick for the whole
            // fleet: no classification table, no decision queue, nothing
            // supervised that night.
            ("a null cache bucket",
             [#"{"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":null}}}"#]),
            ("a non-numeric cache bucket",
             [#"{"message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":"12"}}}"#])
        ]

        let reader = ContextLoadReader()
        for testCase in cases {
            let path = try writeTranscript(testCase.lines, in: root)
            let swift = reader.read(
                capturePath: root.appendingPathComponent("absent.json").path,
                transcriptPath: path,
                tee: .notADesk
            ).used?.value
            let python = try askPython(tickPath: tick, transcriptPath: path).tokens
            let detail = "\(testCase.name): Swift read \(String(describing: swift)), "
                + "tick.py read \(String(describing: python))"
            #expect(swift == python, "\(detail)")
        }
    }

    /// The two constants the rule is expressed in terms of. They cannot be
    /// shared across the language boundary, so the only thing standing between
    /// them and silent divergence is this assertion.
    @Test("The assumed window and the tail window are the same number on both sides")
    func constantsAgree() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-ctx-const-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PluginDirWriter(applicationSupportRoot: root.path).writePlugin()
        let tick = root.appendingPathComponent("TBD/plugin/skills/nightwatch/scripts/tick.py").path
        let empty = try writeTranscript([#"{"message":{}}"#], in: root)

        let python = try askPython(tickPath: tick, transcriptPath: empty)

        #expect(python.assumedWindow == ContextWindow.assumedTokens)
        #expect(python.tailWindowBytes == ContextLoadReader.defaultTailWindowBytes)
    }

    /// Each spelling of the assumption has to name the other, since nothing
    /// mechanical connects them: an editor who arrives at one site is otherwise
    /// given no reason to believe there is a second.
    ///
    /// `handoff.py` is deliberately not in this list. It resolves its ceiling
    /// against the window its own session reported, so it holds no copy of the
    /// assumption to keep in step — the only two spellings are tick.py's and
    /// Swift's.
    @Test("Each spelling of the assumed window points at the other")
    func eachSpellingNamesTheOther() {
        #expect(NightwatchSkillContent.tickPy.contains("ContextWindow.assumedTokens"),
                "tick.py's ASSUMED_WINDOW no longer names its Swift twin")
        #expect(!NightwatchSkillContent.handoffPy.contains("ASSUMED_WINDOW"),
                "handoff.py assumes a window again instead of reading the one its session reported")
        #expect(NightwatchSkillContent.tickPy.contains("ContextLoadReader.lastUsage"),
                "tick.py's numerator no longer names the rule it has to agree with")
    }

    /// The assumption also has to be labeled where a **human** reads it, not
    /// only where an editor does. A percentage printed bare is indistinguishable
    /// from one taken against a window something actually measured, and the
    /// desk acts on these lines.
    @Test("Every reported percentage says its denominator was assumed")
    func theReportSaysTheWindowWasAssumed() {
        let tick = NightwatchSkillContent.tickPy
        #expect(tick.contains("of an ASSUMED {ASSUMED_WINDOW:,}-token "),
                "tick.py's burn-risk header prints a percentage without calling the window assumed")
        #expect(tick.contains("% of assumed {ASSUMED_WINDOW:,}"),
                "tick.py's per-agent burn line prints a percentage without calling the window assumed")
    }
}

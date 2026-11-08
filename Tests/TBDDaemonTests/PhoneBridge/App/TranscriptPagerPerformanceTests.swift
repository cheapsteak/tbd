import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// The first-page target (spec section 7, "Pages"): the first page of a 30 MB
/// transcript costs under 200 ms. A long session must open on the phone as
/// fast as a short one, so the page has to come from the file's tail without
/// reading the rest.
///
/// Tier 2: it writes a transcript of about 20,000 items into a scratch
/// directory of its own and reads it back. The fixture is made at test time
/// and never committed. Writing it and timing the page both run on
/// `GateExecutor.shared`, threads the tests own, so neither holds one of the
/// cooperative pool's threads (Tests/CLAUDE.md, "the pool stall").
///
/// The measure is the thread's CPU time, not wall time: in the parallel pass
/// wall time is mostly queueing (Tests/CLAUDE.md, "Population is the
/// scheduler"). The failure message gives wall time as evidence.
@Suite("Phone transcript first-page performance", .fastPassBounded)
struct TranscriptPagerPerformanceTests {
    @Test func theFirstPageOfA30MBTranscriptTakesUnder200ms() async throws {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-perf"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.jsonl").path

        let written = try await withTaskExecutorPreference(GateExecutor.shared) {
            try PerfTranscript.write(to: path)
        }
        let fileSize = written.fileSize
        let itemCount = written.itemCount
        #expect(fileSize >= 30_000_000)
        #expect(itemCount >= 19_000)

        let timing = await withTaskExecutorPreference(GateExecutor.shared) {
            Self.timeFirstPage(path: path)
        }
        // A page built from nothing would be fast for the wrong reason: the
        // fixture's lines must parse into rows.
        let build = try #require(timing.build)
        #expect(!build.page.items.isEmpty)
        #expect(timing.threadName == GateExecutor.threadName)
        let bestCPUms = timing.bestCPUms
        let wallMs = timing.wallMs
        #expect(bestCPUms < 200, "first page took \(bestCPUms) ms CPU (wall \(wallMs) ms)")
        #expect(try PhoneAppCoding.makeEncoder().encode(build.page).count <= 16_384)
    }

    /// The first page and its cost, from the best of `PerfTranscript.runs` runs.
    struct Timing: Sendable {
        /// The thread CPU time of the cheapest run, in milliseconds.
        let bestCPUms: Double
        /// The wall time of that run, in milliseconds.
        let wallMs: Double
        let build: PageBuild?
        /// The thread the runs ran on, to show the preference reached them.
        let threadName: String?
    }

    /// Times only `TranscriptPager.firstPage`, with the `ShapingContext` the
    /// feed builds for a first page, subagent counter included. The best of
    /// several runs is kept, so the first read's cold page cache does not
    /// decide the verdict.
    ///
    /// Synchronous on purpose. `Thread.current` is unavailable in an async
    /// context, and nothing here suspends, so every run, and both reads of
    /// the CPU clock around it, happen on the one thread named.
    private static func timeFirstPage(path: String) -> Timing {
        let counts = SubagentCountCache()
        let ctx = ShapingContext(showDetails: false, subagentItemCount: { agentID in
            counts.count(agentID: agentID, transcriptPath: path, showDetails: false)
        })
        let clock = ContinuousClock()
        var best: (cpu: UInt64, wall: Duration)?
        var build: PageBuild?
        for _ in 0..<PerfTranscript.runs {
            var cpu: UInt64 = 0
            var page: PageBuild?
            let wall = clock.measure {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                page = TranscriptPager.firstPage(filePath: path, generation: 1, ctx: ctx)
                cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
            }
            if best.map({ cpu < $0.cpu }) ?? true {
                best = (cpu, wall)
                build = page
            }
        }
        let cpuNanos = best?.cpu ?? 0
        let wall = best?.wall ?? .zero
        let wallMs = Double(wall.components.seconds) * 1_000 + Double(wall.components.attoseconds) / 1e15
        return Timing(
            bestCPUms: Double(cpuNanos) / 1_000_000, wallMs: wallMs, build: build,
            threadName: Thread.current.name)
    }
}

/// A seeded, generated transcript of a long Claude Code session: a repeating
/// cycle of a prompt, an assistant text, a Bash call with a 1 KB command, its
/// 4 KB result, and an Edit whose strings are 40 lines each.
private enum PerfTranscript {
    static let targetBytes = 30_000_000
    static let targetItems = 20_000
    static let runs = 3
    /// Each cycle builds four items: the prompt, the text, the Bash call (its
    /// result joins it), and the Edit.
    static let itemsPerCycle = 4
    /// How many bytes are buffered before each write to the file.
    static let flushBytes = 1_048_576
    static let timestamp = "2026-05-05T10:00:00.000Z"

    struct Written: Sendable {
        let fileSize: Int
        let itemCount: Int
    }

    /// Writes whole cycles to `path` until the file holds at least
    /// `targetBytes` bytes and `targetItems` items. The size is the file's
    /// own, read back once the file is closed.
    static func write(to path: String) throws -> Written {
        let itemCount = try writeCycles(to: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return Written(fileSize: fileSize, itemCount: itemCount)
    }

    private static func writeCycles(to path: String) throws -> Int {
        var rng = SplitMix64(seed: 0x7BD0_0030)
        let pools = Pools(&rng)
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var buffer = Data()
        var flushed = 0
        var items = 0
        var cycle = 0
        while flushed + buffer.count < targetBytes || items < targetItems {
            for line in try lines(ofCycle: cycle, pools, &rng) {
                buffer.append(line)
                buffer.append(UInt8(ascii: "\n"))
            }
            items += itemsPerCycle
            cycle += 1
            if buffer.count >= flushBytes {
                try handle.write(contentsOf: buffer)
                flushed += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        return items
    }

    /// Cycle `n`'s five lines, as JSON.
    private static func lines(ofCycle n: Int, _ pools: Pools, _ rng: inout SplitMix64) throws -> [Data] {
        let prompt: [String: Any] = [
            "type": "user", "uuid": "p\(n)", "timestamp": timestamp,
            "message": ["role": "user", "content": pools.prompts.pick(&rng)] as [String: Any],
        ]
        let text = assistant("t\(n)", block: ["type": "text", "text": pools.texts.pick(&rng)])
        let bash = assistant("b\(n)", block: [
            "type": "tool_use", "id": "toolu_b\(n)", "name": "Bash",
            "input": ["command": pools.commands.pick(&rng), "description": "Run the step"] as [String: Any],
        ])
        let resultBlock: [String: Any] = [
            "type": "tool_result", "tool_use_id": "toolu_b\(n)", "content": pools.results.pick(&rng),
        ]
        let result: [String: Any] = [
            "type": "user", "uuid": "r\(n)", "timestamp": timestamp,
            "message": ["role": "user", "content": [resultBlock]] as [String: Any],
        ]
        let edit = assistant("e\(n)", block: [
            "type": "tool_use", "id": "toolu_e\(n)", "name": "Edit",
            "input": [
                "file_path": "/acme/src/module\(n % 97).swift",
                "old_string": pools.editStrings.pick(&rng),
                "new_string": pools.editStrings.pick(&rng),
            ] as [String: Any],
        ])
        return try [prompt, text, bash, result, edit].map { try JSONSerialization.data(withJSONObject: $0) }
    }

    private static func assistant(_ uuid: String, block: [String: Any]) -> [String: Any] {
        [
            "type": "assistant", "uuid": uuid, "timestamp": timestamp,
            "message": ["role": "assistant", "content": [block]] as [String: Any],
        ]
    }

    /// Texts made once from the seeded generator, which each cycle picks from,
    /// so the file varies without building 30 MB of text word by word.
    private struct Pools {
        static let size = 32
        static let vocabulary = [
            "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
            "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
        ]

        let prompts: [String]
        let texts: [String]
        let commands: [String]
        let results: [String]
        let editStrings: [String]

        init(_ rng: inout SplitMix64) {
            var prompts: [String] = []
            var texts: [String] = []
            var commands: [String] = []
            var results: [String] = []
            var editStrings: [String] = []
            for _ in 0..<Self.size {
                prompts.append(Self.text(bytes: 160, &rng))
                texts.append(Self.text(bytes: 600, &rng))
                commands.append(Self.text(bytes: 1_024, &rng))
                results.append(Self.text(bytes: 4_096, &rng))
                var editLines: [String] = []
                for _ in 0..<40 {
                    editLines.append(Self.text(bytes: 24, &rng))
                }
                editStrings.append(editLines.joined(separator: "\n"))
            }
            self.prompts = prompts
            self.texts = texts
            self.commands = commands
            self.results = results
            self.editStrings = editStrings
        }

        /// Words from `vocabulary`, picked at random until the text is at
        /// least `bytes` long.
        static func text(bytes: Int, _ rng: inout SplitMix64) -> String {
            var text = ""
            while text.utf8.count < bytes {
                if !text.isEmpty { text += " " }
                text += vocabulary.pick(&rng)
            }
            return text
        }
    }
}

private extension Array where Element == String {
    /// One element, picked by the seeded generator. The array is never empty.
    func pick(_ rng: inout SplitMix64) -> String {
        self[Int(rng.next() % UInt64(count))]
    }
}

/// SplitMix64: a small seeded generator, so every run writes the same file.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

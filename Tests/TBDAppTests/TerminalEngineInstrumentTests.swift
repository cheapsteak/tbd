import AppKit
import Foundation
import os
import Testing
@testable import TBDApp
import TBDGhosttyTerminal
import TBDShared
import TestSupport

/// The draw instruments reach both engines: the engine's own draw-start and
/// frame-presented hooks, and the latency tap, which reports how long a fed
/// chunk waited for the draw that showed it.
///
/// Each engine's view is mounted in an ordered-front window far off every
/// display. A SwiftTerm frame is drawn with `display()`, falling back to the
/// window's own display pass; a libghostty frame with `drawFrameNow()`, whose
/// view is told its window is visible, because an offscreen window's display
/// link never runs. Metal's present is the one step no test can force: an
/// offscreen window's drawable may never be reported presented, so a missing
/// libghostty present is recorded as a known issue and the engine's wiring of
/// the view's hook is checked by calling it directly.
@MainActor
@Suite("Terminal engine instruments", .fastPassBounded)
struct TerminalEngineInstrumentTests {

    @Test("After a feed, each engine calls onDrawStart as its frame begins and onFramePresented once it is drawn",
          arguments: TerminalEngineFactory.availableKinds)
    func bothEnginesFireDrawStartAndFramePresented(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineInstruments.Hooks")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let host = Self.mount(fixture.engine)
        defer { host.tearDown() }
        let events = InstrumentEvents()
        fixture.engine.onDrawStart = { events.log.append("drawStart") }
        fixture.engine.onFramePresented = { events.log.append("framePresented") }

        fixture.feed("an instrumented frame\r\n")
        let drew = Self.drawFrame(of: fixture.engine) { events.log.contains("drawStart") }
        try #require(drew, "\(kind) never began drawing a frame: \(events.log)")

        if let ghosttyView = fixture.engine.view as? GhosttyTerminalView {
            let start = ContinuousClock.now
            let outcome = await pollUntilTrue(timeout: .seconds(10), pollInterval: .milliseconds(20)) { @Sendable in
                await MainActor.run { events.log.contains("framePresented") }
            }
            switch outcome {
            case .satisfied:
                break
            case .cancelled:
                return
            case .timedOut:
                withKnownIssue("an offscreen window's Metal drawable may never be reported presented") {
                    Issue.record(InstrumentWaitTimedOut(
                        what: "Metal to report a libghostty frame presented",
                        observed: "\(events.log)", elapsed: ContinuousClock.now - start))
                }
                // The engine's half, which is the part this PR wires: the
                // view's hook reaches the engine's.
                ghosttyView.onFramePresented?()
            }
        }
        let presented = Self.drawFrame(of: fixture.engine) { events.log.contains("framePresented") }
        #expect(presented, "\(kind) drew a frame and never reported it presented: \(events.log)")
        let firstStart = events.log.firstIndex(of: "drawStart")
        let firstPresent = events.log.firstIndex(of: "framePresented")
        if let firstStart, let firstPresent {
            #expect(firstStart < firstPresent, "\(kind) reported a frame presented before it began drawing: \(events.log)")
        }
    }

    @Test("A chunk fed through the holder is reported by the next frame's draw on each engine, and not once the tap is withdrawn",
          arguments: TerminalEngineFactory.availableKinds)
    func latencyTapStampsFeedsOnBothEngines(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineInstruments.Tap")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let host = Self.mount(fixture.engine)
        defer { host.tearDown() }
        let terminalID = UUID()
        let lines = TapLines()
        let tap = TerminalLatencyTap(terminalID: terminalID, transport: .holder, emit: { lines.append($0) })
        let holder = TerminalViewHolder()
        holder.set(fixture.engine)
        defer { holder.clear() }
        holder.setTap(tap)
        fixture.engine.latencyTap = tap

        holder.feed(Array("a tapped chunk\r\n".utf8)[...])
        let reported = Self.drawFrame(of: fixture.engine) { !lines.draws.isEmpty }
        try #require(reported, "\(kind) drew no frame that reported the chunk: \(lines.all)")
        let line = try #require(lines.draws.first)
        #expect(line.contains("transport=holder"), "\(line)")
        #expect(line.contains("terminal=\(terminalID.uuidString)"), "\(line)")
        #expect(line.contains("chunks=1"), "\(kind) reported the wrong chunk count: \(line)")

        // Control: withdrawn from the engine, the tap still stamps the chunk
        // the holder feeds, and no draw reports it.
        fixture.engine.latencyTap = nil
        let drawsBefore = lines.draws.count
        let events = InstrumentEvents()
        fixture.engine.onDrawStart = { events.log.append("drawStart") }
        holder.feed(Array("an untapped chunk\r\n".utf8)[...])
        let drewAgain = Self.drawFrame(of: fixture.engine) { events.log.contains("drawStart") }
        try #require(drewAgain, "\(kind) drew no frame for the control")
        #expect(lines.draws.count == drawsBefore, "a draw reported a chunk with the tap withdrawn: \(lines.draws)")
    }

    // MARK: - Helpers

    /// The engine's view in an ordered-front window far off every display. A
    /// libghostty view is told the window is visible first, as its own tests
    /// do, so it builds frames.
    private static func mount(_ engine: any TerminalEngine) -> OffscreenAppKitHost {
        if let ghosttyView = engine.view as? GhosttyTerminalView {
            ghosttyView.windowVisibility = { _ in true }
        }
        let controller = NSViewController()
        controller.view = engine.view
        return OffscreenAppKitHost(controller: controller, size: NSSize(width: 640, height: 400))
    }

    /// Draws `engine`'s view until `condition` holds, bounded. Synchronous: a
    /// SwiftTerm draw and a libghostty encode both run their hooks before they
    /// return, and the window's own display pass runs on a run-loop turn.
    private static func drawFrame(of engine: any TerminalEngine, until condition: () -> Bool) -> Bool {
        let view = engine.view
        return RunLoopPump.until {
            if condition() { return true }
            if let ghosttyView = view as? GhosttyTerminalView {
                ghosttyView.drawFrameNow()
            } else {
                view.needsDisplay = true
                view.display()
            }
            return condition()
        }
    }
}

/// What the hooks were called with, in order. Main-actor, so a main-actor
/// hook appends to it without capturing a mutable local.
@MainActor
private final class InstrumentEvents {
    var log: [String] = []
}

/// The latency tap's lines. The tap emits from whichever thread stamps the
/// draw, so the lines sit behind a lock.
private final class TapLines: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] { lines.withLock { $0 } }

    /// The draw reports, the lines that say what a chunk waited.
    var draws: [String] { all.filter { $0.hasPrefix("draw ") } }
}

/// A bounded wait that ran out, as the error its issue records.
private struct InstrumentWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let elapsed: Duration

    var description: String {
        "Timed out after \(elapsed) waiting for \(what); observed \(observed)"
    }
}

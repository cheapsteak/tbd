import AppKit
import Foundation
import Testing
@testable import TBDApp
import TestSupport

/// What the engine suites outside the contract suite share: an engine built
/// through the factory with a recorder as its delegate, the waits, and the skip
/// rule for libghostty. The contract suite keeps its own copies, which it
/// documents in place.
@MainActor
enum EngineTestSupport {
    /// Why a test that needs libghostty did not run.
    nonisolated static let noMetalDevice: Comment =
        "no Metal device on this runner, so libghostty cannot draw and the factory builds SwiftTerm instead"

    /// Whether this machine can build a libghostty engine at all.
    nonisolated static var canBuildGhostty: Bool {
        TerminalEngineFactory.availableKinds.contains(.ghostty)
    }

    /// One main-queue turn: resumes behind everything already queued on main.
    static func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Five main-queue turns with a short real pause between them, the
    /// contract suite's settle rule: long enough for every hop a parse queued,
    /// and for SwiftTerm's OSC observer queue.
    static func settle() async {
        for _ in 0..<5 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
    }

    /// Polls `condition` on main within the shared saturated-pass budget.
    /// Returns true once it holds. On a timeout it records an error naming
    /// what was awaited, what was observed and how long the wait took, and
    /// returns false; on cancellation it records nothing and returns false.
    @discardableResult
    static func waitUntil(
        _ what: String,
        observed: @escaping @MainActor @Sendable () -> String,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            await MainActor.run { condition() }
        }
        switch outcome {
        case .satisfied:
            return true
        case .cancelled:
            return false
        case .timedOut:
            Issue.record(EngineWaitTimedOut(
                what: what, observed: observed(), elapsed: ContinuousClock.now - start))
            return false
        }
    }

    /// Puts `view` in a borderless window far off every display, never ordered
    /// front, filling it.
    static func mount(_ view: NSView, size: NSSize = NSSize(width: 800, height: 600)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = ground.bounds
        ground.addSubview(view)
        window.contentView = ground
        return window
    }

    static func unmount(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    /// `bytes` as text a failure message can show, escapes visible.
    nonisolated static func describe(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8)?.debugDescription ?? "\(bytes)"
    }
}

/// A `waitUntil` timeout, as the error its issue records, so the primary
/// failure line carries what was awaited, what was observed and how long.
struct EngineWaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let observed: String
    let elapsed: Duration

    var description: String {
        "Timed out after \(elapsed) waiting for \(what); observed \(observed)"
    }
}

/// One engine from the factory, the way the coordinators build theirs, with a
/// recorder as its delegate and isolated defaults behind its appearance.
@MainActor
final class EngineUnderTest {
    let suite: TestDefaultsSuite
    let appearance: AppearanceSettings
    let engine: any TerminalEngine
    let recorder: EngineEventRecorder

    init(kind: TerminalEngineKind, label: String) {
        // `UserDefaults.standard` on this unbundled executable is the
        // developer's real TBDApp.plist.
        let suite = TestDefaultsSuite("TBDAppTests.\(label)")
        let appearance = AppearanceSettings(defaults: suite.defaults)
        let engine = TerminalEngineFactory.make(
            kind: kind,
            font: appearance.font,
            appearance: appearance,
            configuration: TerminalEngineConfiguration())
        let recorder = EngineEventRecorder()
        engine.delegate = recorder
        self.suite = suite
        self.appearance = appearance
        self.engine = engine
        self.recorder = recorder
    }

    func feed(_ text: String) {
        engine.feed(Array(text.utf8)[...])
    }

    func tearDown() {
        engine.delegate = nil
        suite.tearDown()
    }
}

/// Records what an engine sends and reports. Acts on nothing: no pty, no
/// pasteboard, no beep.
@MainActor
final class EngineEventRecorder: TerminalEngineDelegate {
    private(set) var calls: [String] = []
    private(set) var sent: [UInt8] = []
    private(set) var programStatusPayloads: [[UInt8]] = []

    var summary: String {
        "calls \(calls), sent \(EngineTestSupport.describe(sent))"
    }

    func reset() {
        calls = []
        sent = []
        programStatusPayloads = []
    }

    func engine(_ e: any TerminalEngine, send data: ArraySlice<UInt8>) {
        calls.append("send")
        sent.append(contentsOf: data)
    }

    func engine(_ e: any TerminalEngine, sizeChanged cols: Int, rows: Int) {
        calls.append("sizeChanged")
    }

    func engineBell(_ e: any TerminalEngine) {
        calls.append("bell")
    }

    func engine(_ e: any TerminalEngine, clipboardCopy content: Data) {
        calls.append("clipboardCopy")
    }

    func engine(_ e: any TerminalEngine, openLink link: String, params: [String: String]) {
        calls.append("openLink")
    }

    func engine(_ e: any TerminalEngine, notification title: String, body: String) {
        calls.append("notification")
    }

    func engine(_ e: any TerminalEngine, programStatusPayload payload: [UInt8], observedAt: Date) {
        calls.append("programStatusPayload")
        programStatusPayloads.append(payload)
    }

    func engine(_ e: any TerminalEngine, filePathClicked path: String) {
        calls.append("filePathClicked")
    }

    func engineRequestsCloseTab(_ e: any TerminalEngine) {
        calls.append("requestsCloseTab")
    }

    func engineReady(_ e: any TerminalEngine) {
        calls.append("ready")
    }

    func engine(_ e: any TerminalEngine, focusChanged focused: Bool) {
        calls.append("focusChanged")
    }

    func engineMouseDownClaimsFocus(_ e: any TerminalEngine) -> Bool {
        calls.append("mouseDownClaimsFocus")
        return false
    }

    func engineMovedToWindow(_ e: any TerminalEngine) {
        calls.append("movedToWindow")
    }

    func engine(_ e: any TerminalEngine, controlModePaste data: Data) -> Bool {
        calls.append("controlModePaste")
        return false
    }
}

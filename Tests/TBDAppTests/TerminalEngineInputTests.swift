import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import TBDApp
@testable import TBDGhosttyTerminal
import TestSupport

/// Input that must reach the pty the same way whichever engine draws the
/// terminal: Option as Meta, and the wheel through the panel's scroll monitor.
///
/// **The wheel.** A holder panel's scroll monitor is an `NSEvent` local
/// monitor, which AppKit runs before it dispatches a wheel event to any view,
/// so a claimed event never reaches the engine's view, whichever view that is.
/// The monitor's decision is `Coordinator.consumeScrollWheel`, driven here
/// directly, because a local monitor sees only events the run loop dequeues.
/// The ghostty-only control then hands the same wheel to the view itself, to
/// show that the claim is what keeps its arrow-key fallback off the pty.
@MainActor
@Suite("Terminal engine input", .fastPassBounded)
struct TerminalEngineInputTests {

    // MARK: - Option as Meta

    /// Neither engine is told what Option does: SwiftTerm's `optionAsMetaKey`
    /// and `GhosttyTerminalView.optionAsMeta` both default to true, and this
    /// pins that the engines leave them there. The libghostty view reads keys
    /// through a fixed layout and an input method that commits what it is
    /// handed, because no input method runs in a test process and the
    /// machine's layout is not the test's business.
    @Test("Option-b sends ESC b", arguments: TerminalEngineFactory.availableKinds)
    func optionBSendsEscapeB(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineInput.OptionMeta")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let view = fixture.engine.view
        let window = EngineTestSupport.mount(view)
        defer { EngineTestSupport.unmount(window) }
        if let ghosttyView = view as? GhosttyTerminalView {
            ghosttyView.inputController.layout = optionBLayout
            ghosttyView.inputController.inputMethod = { event, view in
                view.insertText(event.characters ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        window.makeFirstResponder(view)
        await EngineTestSupport.settle()
        fixture.recorder.reset()

        let optionB = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "∫", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 0x0B))
        view.keyDown(with: optionB)
        let sent = await EngineTestSupport.waitUntil(
            "Option-b to reach send", observed: { fixture.recorder.summary }
        ) {
            !fixture.recorder.sent.isEmpty
        }
        guard sent else { return }
        await EngineTestSupport.settle()
        #expect(fixture.recorder.sent == [0x1B, UInt8(ascii: "b")],
                "\(kind): Option-b sent \(EngineTestSupport.describe(fixture.recorder.sent))")
    }

    // MARK: - Wheel

    @Test("On the alternate screen with mouse reporting off, the scroll monitor claims the wheel and nothing reaches the pty; with reporting on, it sends reports",
          arguments: TerminalEngineFactory.availableKinds)
    func alternateScreenWheelWithReportingOffSendsNothing(kind: TerminalEngineKind) async throws {
        let fixture = EngineUnderTest(kind: kind, label: "EngineInput.Wheel")
        defer { fixture.tearDown() }
        #expect(fixture.engine.kind == kind, "asked for \(kind), the factory built \(fixture.engine.kind)")
        let view = fixture.engine.view
        let window = EngineTestSupport.mount(view)
        defer { EngineTestSupport.unmount(window) }
        let coordinator = TerminalPanelRepresentable.Coordinator()

        fixture.feed("\u{1b}[?1049h")
        await EngineTestSupport.settle()
        fixture.recorder.reset()
        let modes = fixture.engine.withScreen { (alternate: $0.isAlternateScreen, reporting: $0.mouseReporting) }
        try #require(modes.alternate, "the fixture did not reach the alternate screen")
        try #require(!modes.reporting, "a new terminal reports the mouse, so this proves nothing")

        let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var claims: [Bool] = []
        for step in 0..<3 {
            let wheelDown = ScrollWheelAccumulator.Event(
                deltaY: -3, precise: false, phase: .unphased, timestamp: 1 + Double(step))
            claims.append(coordinator.consumeScrollWheel(wheelDown, atWindowLocation: location, on: fixture.engine))
        }
        await EngineTestSupport.settle()
        #expect(claims == [true, true, true], "\(kind): the monitor passed a wheel through to the view: \(claims)")
        #expect(fixture.recorder.sent.isEmpty,
                "\(kind): a claimed wheel reached the pty as \(EngineTestSupport.describe(fixture.recorder.sent))")

        if let ghosttyView = view as? GhosttyTerminalView {
            // Control: the view by itself turns the same wheel into an arrow
            // key, so the claim above is what kept one off the pty.
            let wheel = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: wheel))
            ghosttyView.scrollWheel(with: event)
            let typed = await EngineTestSupport.waitUntil(
                "the libghostty view's own wheel to type an arrow key", observed: { fixture.recorder.summary }
            ) {
                !fixture.recorder.sent.isEmpty
            }
            guard typed else { return }
            #expect(fixture.recorder.sent.first == 0x1B,
                    "the view's own wheel sent \(EngineTestSupport.describe(fixture.recorder.sent))")
            await EngineTestSupport.settle()
            fixture.recorder.reset()
        }

        // Control: with reporting on, the same path claims the wheel and sends
        // a wheel-down report through the engine's reader.
        fixture.feed("\u{1b}[?1000h\u{1b}[?1006h")
        await EngineTestSupport.settle()
        let reporting = fixture.engine.withScreen { $0.mouseReporting }
        try #require(reporting, "?1000h ?1006h did not turn mouse reporting on")
        let wheelDown = ScrollWheelAccumulator.Event(deltaY: -3, precise: false, phase: .unphased, timestamp: 10)
        let claimed = coordinator.consumeScrollWheel(wheelDown, atWindowLocation: location, on: fixture.engine)
        #expect(claimed, "\(kind): the monitor passed a wheel through with reporting on")
        let reported = await EngineTestSupport.waitUntil(
            "a wheel report to reach send", observed: { fixture.recorder.summary }
        ) {
            !fixture.recorder.sent.isEmpty
        }
        guard reported else { return }
        #expect(fixture.recorder.sent.starts(with: Array("\u{1b}[<65;".utf8)),
                "\(kind): with reporting on the wheel sent \(EngineTestSupport.describe(fixture.recorder.sent))")
    }
}

/// What a US layout types for the one key these tests press.
private let optionBLayout = KeyboardLayout { event, modifiers in
    guard event.keyCode == 0x0B else { return nil }
    return modifiers.contains(.option) ? "∫" : "b"
}

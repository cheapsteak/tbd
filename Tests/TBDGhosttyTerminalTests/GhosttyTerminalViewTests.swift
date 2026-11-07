import AppKit
import Foundation
import Metal
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a view's callbacks were handed. Main-actor isolated, so the `@MainActor` callbacks can
/// write to it without capturing a mutable local.
@MainActor
private final class ViewRecorder {
    var sent: [[UInt8]] = []
    /// What `onSizeChanged` reported, as `[cols, rows]`.
    var sizes: [[Int]] = []
    /// The terminal's own grid, read from inside `onSizeChanged`, as `[cols, rows]`.
    var terminalSizesSeen: [[Int]] = []
}

/// An 80×24 terminal and a view over it in a 13 pt monospaced font.
@MainActor
private struct ViewFixture {
    let terminal: GhosttyTerminal
    let view: GhosttyTerminalView
    let appearance: GhosttyAppearance

    init() throws {
        terminal = try GhosttyTerminal(cols: 80, rows: 24, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        appearance = GhosttyAppearance(
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .init(r: 0xDD, g: 0xDD, b: 0xDD),
            background: .init(r: 0x10, g: 0x10, b: 0x10),
            cursor: .init(r: 0xFF, g: 0xFF, b: 0xFF))
        view = try GhosttyTerminalView(terminal: terminal, appearance: appearance)
    }
}

/// An offscreen window the view can sit in. Never ordered front, so it is never on screen; the
/// tests replace `windowVisibility` to separate "hidden" from "occluded".
@MainActor
private func makeOffscreenWindow() -> NSWindow {
    // Enough of an application for AppKit to have an app object; `NSWindow` reaches for one.
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    return window
}

@Suite(.fastPassBounded)
@MainActor
struct GhosttyTerminalViewTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func typedKeyReachesOnSend() throws {
        let fixture = try ViewFixture()
        let recorder = ViewRecorder()
        fixture.view.onSend = { recorder.sent.append($0) }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
            keyCode: 0))
        fixture.view.keyDown(with: event)

        #expect(recorder.sent == [[0x61]], "an a key-down sent \(recorder.sent)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func resizeCallsTerminalBeforeOnSizeChanged() throws {
        let fixture = try ViewFixture()
        let recorder = ViewRecorder()
        let terminal = fixture.terminal
        fixture.view.onSizeChanged = { cols, rows in
            recorder.sizes.append([cols, rows])
            recorder.terminalSizesSeen.append(terminal.withLocked { [$0.cols, $0.rows] })
        }

        // Half a point over 40×10 cells, so rounding cannot land on 39 or 9.
        let cell = fixture.view.cellSize
        fixture.view.setFrameSize(NSSize(width: cell.width * 40 + 0.5, height: cell.height * 10 + 0.5))
        fixture.view.renderTick()

        #expect(recorder.sizes == [[40, 10]], "onSizeChanged reported \(recorder.sizes)")
        #expect(recorder.terminalSizesSeen == [[40, 10]],
                "inside onSizeChanged the terminal was \(recorder.terminalSizesSeen)")
        let grid = fixture.view.gridSize
        #expect(grid.cols == 40 && grid.rows == 10, "the view's grid is \(grid)")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func hiddenViewBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        let window = makeOffscreenWindow()
        defer { window.contentView = nil }
        let content = try #require(window.contentView)

        // A test window is never on screen; count it as visible so only `isHidden` keeps frames off.
        view.windowVisibility = { _ in true }
        view.setFrameSize(NSSize(width: 400, height: 200))
        view.isHidden = true
        content.addSubview(view)

        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(view.framesBuilt == 0, "a hidden view built \(view.framesBuilt) frames")
        #expect(!view.surface.isAttached, "a hidden view kept its surface attached")

        view.isHidden = false
        view.renderTick()
        #expect(view.framesBuilt >= 1, "a view shown again built no frame")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func windowlessViewBuildsNoFrames() throws {
        let fixture = try ViewFixture()
        let view = fixture.view
        view.setFrameSize(NSSize(width: 400, height: 200))

        for index in 0..<30 {
            fixture.terminal.feed(text: "line \(index)\r\n")
            view.renderTick()
        }
        #expect(view.framesBuilt == 0, "a windowless view built \(view.framesBuilt) frames")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func applyingAppearanceUpdatesPaletteAndCellSize() throws {
        let fixture = try ViewFixture()
        let custom = GhosttyAppearance.RGB(r: 0x12, g: 0x34, b: 0x56)
        let background = GhosttyAppearance.RGB(r: 0x20, g: 0x21, b: 0x22)
        var next = fixture.appearance
        next.palette[1] = custom
        next.background = background
        fixture.view.apply(next)

        let palette = fixture.terminal.withLocked { $0.palette }
        let backgroundInForce = fixture.terminal.withLocked { $0.backgroundColor }
        let entry = palette.count > 1 ? palette[1] : nil
        #expect(palette.count == 256, "the terminal reports \(palette.count) palette entries")
        #expect(entry == custom, "palette[1] reads back as \(String(describing: entry))")
        #expect(backgroundInForce == background, "the background reads back as \(String(describing: backgroundInForce))")

        let before = fixture.view.cellSize
        var larger = next
        larger.font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        fixture.view.apply(larger)
        let after = fixture.view.cellSize
        #expect(after.width > before.width && after.height > before.height,
                "a 26 pt font gave cells of \(after), against \(before) at 13 pt")
    }
}

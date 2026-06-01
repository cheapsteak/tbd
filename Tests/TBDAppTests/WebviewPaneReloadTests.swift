import AppKit
import Testing
import WebKit
@testable import TBDApp

@MainActor
struct WebviewPaneReloadTests {
    @Test("cmd+r triggers reload when host is in the first responder chain")
    func commandRTriggersReloadWhenHostIsInFirstResponderChain() {
        let recorder = RecordingReloadClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, reloadClient: recorder)
        let window = makeWindow(host: host)
        window.makeFirstResponder(host.webView)

        let handled = host.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: .command))

        #expect(handled)
        #expect(recorder.reloadCount == 1)
    }

    @Test("cmd+t does not trigger reload")
    func commandTDoesNotTriggerReload() {
        let recorder = RecordingReloadClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, reloadClient: recorder)
        let window = makeWindow(host: host)
        window.makeFirstResponder(host.webView)

        _ = host.performKeyEquivalent(with: keyEvent(characters: "t", modifiers: .command))

        #expect(recorder.reloadCount == 0)
    }

    @Test("cmd+shift+r does not trigger reload")
    func commandShiftRDoesNotTriggerReload() {
        let recorder = RecordingReloadClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, reloadClient: recorder)
        let window = makeWindow(host: host)
        window.makeFirstResponder(host.webView)

        _ = host.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: [.command, .shift]))

        #expect(recorder.reloadCount == 0)
    }

    @Test("cmd+r does not trigger reload when host is not in the first responder chain")
    func commandRDoesNotTriggerReloadWhenHostNotInFirstResponderChain() {
        let recorder = RecordingReloadClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, reloadClient: recorder)
        let other = FocusableTestView(frame: .zero)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        container.addSubview(host)
        container.addSubview(other)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeFirstResponder(other)

        let handled = host.performKeyEquivalent(with: keyEvent(characters: "r", modifiers: .command))

        #expect(!handled)
        #expect(recorder.reloadCount == 0)
    }

    private func makeWindow(host: WebviewPaneHostView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: 15
        )!
    }
}

@MainActor
private final class RecordingReloadClient: WebviewReloadClient {
    var reloadCount = 0

    func reload() {
        reloadCount += 1
    }
}

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

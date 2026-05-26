import AppKit
import Testing
@testable import TBDApp

@Suite("Terminal key equivalents")
struct TerminalKeyEquivalentTests {
    @Test("plain command-w closes the active tab")
    func commandWClosesActiveTab() {
        let event = keyEvent(characters: "w", modifiers: .command)

        #expect(TBDTerminalView.keyEquivalentAction(for: event) == .closeTab)
    }

    @Test("shift command-w is not claimed as close tab")
    func shiftCommandWDoesNotCloseTab() {
        let event = keyEvent(characters: "W", modifiers: [.command, .shift])

        #expect(TBDTerminalView.keyEquivalentAction(for: event) == nil)
    }

    @MainActor
    @Test("close tab action invokes external tab cleanup")
    func closeTabActionInvokesExternalTabCleanup() {
        let view = makeTerminalView()
        var closeCount = 0
        view.onCloseTab = { closeCount += 1 }

        view.performKeyEquivalentAction(.closeTab)

        #expect(closeCount == 1)
    }

    @MainActor
    private func makeTerminalView() -> TBDTerminalView {
        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: UserDefaults(suiteName: "TerminalKeyEquivalentTests.clearAction")!)
        )
        view.resize(cols: 10, rows: 5)
        return view
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
            keyCode: 40
        )!
    }
}

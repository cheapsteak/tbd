import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("PromptRailCommand")
struct PromptRailCommandTests {
    private struct Scene {
        let window: NSWindow
        let container: TranscriptContainerView
        let table: NSTableView
        let coordinator: TableTranscriptView.Coordinator
    }

    private func makeScene() -> Scene {
        let coordinator = TableTranscriptView.Coordinator(context: TranscriptCardContext(
            terminalID: nil,
            openTranscriptOverlay: nil,
            appState: nil,
            linkResolver: nil,
            onLinkClicked: nil))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        scroll.documentView = table
        let container = TranscriptContainerView(scrollView: scroll, leadingGutter: 20)
        container.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(container)
        return Scene(window: window, container: container, table: table, coordinator: coordinator)
    }

    @Test func tableResponderResolvesItsContainer() {
        let scene = makeScene()
        let found = PromptRailCommand.coordinator(
            forResponder: scene.table, composerViews: [:], transcriptViews: [:])
        #expect(found === scene.coordinator)
    }

    @Test func composerResolvesThroughRegistries() {
        let scene = makeScene()
        let composer = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        composer.addSubview(text)
        let key = ComposerKey.terminal(UUID())
        let found = PromptRailCommand.coordinator(
            forResponder: text, composerViews: [key: composer], transcriptViews: [key: scene.table])
        #expect(found === scene.coordinator)
    }

    @Test func unrelatedResponderResolvesNil() {
        let scene = makeScene()
        let composer = NSView()
        let key = ComposerKey.terminal(UUID())
        let stray = NSTextView()
        #expect(PromptRailCommand.coordinator(
            forResponder: stray, composerViews: [key: composer], transcriptViews: [key: scene.table]) == nil)
        #expect(PromptRailCommand.coordinator(
            forResponder: nil, composerViews: [:], transcriptViews: [:]) == nil)
    }
}

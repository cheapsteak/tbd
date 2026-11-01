import Foundation
import Testing

@testable import TBDApp
import TestSupport

/// Tier 1. The per-kind control state a tab row owns and hands to the leaf
/// (`PaneChromeState`), and the control values its button draws.
///
/// The copy checkmark's reset runs in virtual time on an
/// `EventDrivenTestClock`. `copyAddress` arms it through an unstructured
/// `Task` on the main actor, so the timer arms only once that task has had a
/// main-actor turn, and the reset needs another after the advance: every wait
/// takes `TestDeadlines.saturatedPass` (Tests/CLAUDE.md, "Clock and date
/// seams"). Each test costs at most two such guards.
@MainActor
@Suite("Pane chrome state", .clockDriven)
struct PaneChromeTests {
    /// The checkmark has cleared, read on the main actor where the reset
    /// writes it.
    private static func waitUntilCleared(_ state: PaneChromeState) async -> PollOutcome {
        await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { !state.didCopyAddress }
        }
    }

    @Test("copying an address writes it and shows the checkmark until the clock passes 1.5 s")
    func copyShowsTheCheckmarkForOneAndAHalfSeconds() async throws {
        let clock = EventDrivenTestClock()
        let written = FireRecorder<String>()
        let state = PaneChromeState(clock: clock, pasteboard: { written.record($0) })
        let url = try #require(URL(string: "https://example.com/docs/page?section=2"))

        state.copyAddress(url)
        #expect(written.values == [url.absoluteString])
        #expect(state.didCopyAddress)

        try await clock.requireAdvanceWhenArmed(
            by: .milliseconds(1400), timeout: TestDeadlines.saturatedPass)
        await settle()
        #expect(state.didCopyAddress, "1.4 s after the copy, the checkmark still shows")

        await clock.advance(by: .milliseconds(100))
        #expect(await Self.waitUntilCleared(state) == .satisfied)
        #expect(written.values == [url.absoluteString], "the reset writes nothing to the pasteboard")
    }

    @Test("a second copy while the checkmark shows restarts its 1.5 s")
    func aSecondCopyRestartsTheCheckmark() async throws {
        let clock = EventDrivenTestClock()
        let written = FireRecorder<String>()
        let state = PaneChromeState(clock: clock, pasteboard: { written.record($0) })
        let first = try #require(URL(string: "https://example.com/first"))
        let second = try #require(URL(string: "https://example.com/second"))

        state.copyAddress(first)
        try await clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: TestDeadlines.saturatedPass)
        // Cancels the first reset, whose sleeper leaves the ledger at once, so
        // the wait below is satisfied only by the second copy's reset.
        state.copyAddress(second)
        try await clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: TestDeadlines.saturatedPass)
        await settle()

        // 2 s after the first copy, past its 1.5 s, but 1 s after the second.
        #expect(state.didCopyAddress, "the first copy's reset must not clear the second copy's checkmark")
        let expectedWrites: [String] = [first.absoluteString, second.absoluteString]
        #expect(written.values == expectedWrites)
    }

    @Test("a fresh chrome state shows the rendered view and knows of no renderable content")
    func aFreshStateStartsRenderedWithNothingCopied() {
        let state = PaneChromeState(clock: EventDrivenTestClock(), pasteboard: { _ in })

        #expect(state.showSourceCode == false)
        #expect(state.hasRenderableContent == false)
        #expect(state.didCopyAddress == false)
        #expect(state.webviewState.currentURL == nil)
    }

    @Test("the transcript control fills and takes the accent colour only while on")
    func transcriptControlFollowsItsOnState() {
        let on = PaneChromeControl.transcript(isOn: true)
        let off = PaneChromeControl.transcript(isOn: false)

        #expect(on.systemImage == "text.bubble.fill")
        #expect(on.tint == .accent)
        #expect(on.help == "Hide the chat-style live transcript pane")
        #expect(off.systemImage == "text.bubble")
        #expect(off.tint == .primary)
        #expect(off.help == "Show the chat-style live transcript pane")
    }

    @Test("the render toggle is primary while showing source and secondary otherwise")
    func renderToggleFollowsWhatItShows() {
        let source = PaneChromeControl.renderToggle(showingSource: true)
        let rendered = PaneChromeControl.renderToggle(showingSource: false)

        #expect(source.systemImage == "chevron.left.forwardslash.chevron.right")
        #expect(source.tint == .primary)
        #expect(source.help == "Show rendered view")
        #expect(rendered.systemImage == "chevron.left.forwardslash.chevron.right")
        #expect(rendered.tint == .secondary)
        #expect(rendered.help == "Show source code")
    }

    @Test("copy-address shows a checkmark only after a copy")
    func copyAddressControlFollowsTheCopy() {
        let copied = PaneChromeControl.copyAddress(copied: true)
        let idle = PaneChromeControl.copyAddress(copied: false)

        #expect(copied.systemImage == "checkmark")
        #expect(idle.systemImage == "doc.on.doc")
        #expect(copied.tint == nil)
        #expect(idle.tint == nil)
        #expect(copied.help == "Copy URL")
        #expect(idle.help == "Copy URL")
    }
}

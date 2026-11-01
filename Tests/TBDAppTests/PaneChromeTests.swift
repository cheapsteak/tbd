import Clocks
import Foundation
import Testing

@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. The per-kind control state a tab row owns and hands to the leaf
/// (`PaneChromeState`), and the control values its button draws.
///
/// The copy checkmark's reset runs in virtual time on an
/// `EventDrivenTestClock`. `copyAddress` arms it through an unstructured
/// `Task` on the main actor, so the timer arms only once that task has had a
/// main-actor turn, and the reset needs another after the advance: every wait
/// takes `TestDeadlines.saturatedPass` (Tests/CLAUDE.md, "Clock and date
/// seams"). The restart test chains three such guards on paper, but its two
/// arming waits are strict and its one non-throwing wait comes last, so at
/// most one can elapse in a run; every other test chains at most two.
///
/// The control-action tests assert what a click writes, not when the
/// checkmark clears, so they run on an `ImmediateClock`: a copy's reset
/// returns from its sleep at once rather than wait on a clock nobody
/// advances. Their bodies never suspend, so the reset cannot run before
/// their assertions.
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
        let state = PaneChromeState(pasteboard: { written.record($0) }, clock: clock)
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
        let state = PaneChromeState(pasteboard: { written.record($0) }, clock: clock)
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

        // 2.5 s after the first copy, 1.5 s after the second: the restarted
        // wait has run out, so the checkmark clears.
        await clock.advance(by: .milliseconds(500))
        #expect(await Self.waitUntilCleared(state) == .satisfied)
        let expectedWrites: [String] = [first.absoluteString, second.absoluteString]
        #expect(written.values == expectedWrites)
    }

    @Test("a fresh chrome state shows the rendered view and knows of no renderable content")
    func aFreshStateStartsRenderedWithNothingCopied() {
        let state = PaneChromeState(pasteboard: { _ in }, clock: EventDrivenTestClock())

        #expect(state.showSourceCode == false)
        #expect(state.hasRenderableContent == false)
        #expect(state.didCopyAddress == false)
        #expect(state.webviewState.currentURL == nil)
    }

    @Test("the render toggle flips the file between its rendered view and its source, and copies nothing")
    func performingTheRenderToggleFlipsTheView() {
        let written = FireRecorder<String>()
        let state = PaneChromeState(pasteboard: { written.record($0) }, clock: ImmediateClock<Duration>())

        state.perform(.renderToggle(showingSource: false), contentURL: nil)
        #expect(state.showSourceCode, "a click on the rendered view shows the source")
        state.perform(.renderToggle(showingSource: true), contentURL: nil)
        #expect(!state.showSourceCode, "a second click shows the rendered view again")
        #expect(written.values.isEmpty)
        #expect(!state.didCopyAddress)
    }

    @Test("copy-address copies the content's address until the page reports its own, then the page's")
    func performingCopyAddressPrefersThePagesAddress() throws {
        let opened = try #require(URL(string: "https://example.com/opened"))
        let navigated = try #require(URL(string: "https://example.com/navigated"))
        let written = FireRecorder<String>()
        let state = PaneChromeState(pasteboard: { written.record($0) }, clock: ImmediateClock<Duration>())

        state.perform(.copyAddress(copied: false), contentURL: opened)
        state.webviewState.currentURL = navigated
        state.perform(.copyAddress(copied: true), contentURL: opened)

        let expected: [String] = [opened.absoluteString, navigated.absoluteString]
        #expect(written.values == expected)
        #expect(state.didCopyAddress)
        #expect(!state.showSourceCode, "a copy leaves the rendered/source toggle alone")
    }

    /// The transcript and Notes controls open or close a panel, which the
    /// view that draws each sends; the chrome state has nothing to do for
    /// them.
    @Test("copy-address with no address to copy, and the transcript and Notes controls, change nothing")
    func performingWithoutAnEffectChangesNothing() throws {
        let opened = try #require(URL(string: "https://example.com/opened"))
        let written = FireRecorder<String>()
        let state = PaneChromeState(pasteboard: { written.record($0) }, clock: ImmediateClock<Duration>())

        state.perform(.copyAddress(copied: false), contentURL: nil)
        state.perform(.transcript(isOn: false), contentURL: opened)
        state.perform(.transcript(isOn: true), contentURL: opened)
        state.perform(.notes(isOn: false), contentURL: opened)
        state.perform(.notes(isOn: true), contentURL: opened)

        #expect(written.values.isEmpty)
        #expect(!state.didCopyAddress)
        #expect(!state.showSourceCode)
    }

    @Test("a viewer kind's control: the render toggle for a file that can render, copy-address for a page")
    func viewerControlPerKind() {
        let showingSource: PaneChromeControl? = .renderToggle(showingSource: true)
        let showingRendered: PaneChromeControl? = .renderToggle(showingSource: false)
        let copied: PaneChromeControl? = .copyAddress(copied: true)
        let notCopied: PaneChromeControl? = .copyAddress(copied: false)

        #expect(PaneChromeControl.viewerControl(
            for: .file, canRender: true, showingSource: true, copied: false) == showingSource)
        #expect(PaneChromeControl.viewerControl(
            for: .file, canRender: true, showingSource: false, copied: true) == showingRendered)
        // A file that cannot render has none.
        #expect(PaneChromeControl.viewerControl(
            for: .file, canRender: false, showingSource: true, copied: true) == nil)
        // A web page's control is copy-address whether or not anything renders.
        #expect(PaneChromeControl.viewerControl(
            for: .web, canRender: false, showingSource: false, copied: true) == copied)
        #expect(PaneChromeControl.viewerControl(
            for: .web, canRender: true, showingSource: true, copied: false) == notCopied)
        // A note and a transcript have none, whatever the inputs say.
        let withoutControl: [PanelKind] = [.note, .transcript]
        for kind in withoutControl {
            #expect(PaneChromeControl.viewerControl(
                for: kind, canRender: true, showingSource: true, copied: true) == nil, "\(kind)")
        }
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

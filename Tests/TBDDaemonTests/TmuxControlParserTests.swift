import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxControlParser — notifications")
struct TmuxControlParserNotificationTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("parses %window-add")
    func windowAdd() {
        #expect(feed("%window-add @5\n") == [.windowAdd(windowID: "@5")])
    }

    @Test("parses %window-close")
    func windowClose() {
        #expect(feed("%window-close @7\n") == [.windowClose(windowID: "@7")])
    }

    @Test("parses %pause and %continue")
    func pauseContinue() {
        #expect(feed("%pause %3\n") == [.pause(paneID: "%3")])
        #expect(feed("%continue %3\n") == [.continue(paneID: "%3")])
    }

    @Test("parses %exit with and without a reason")
    func exit() {
        #expect(feed("%exit\n") == [.exit(reason: nil)])
        #expect(feed("%exit server exited\n") == [.exit(reason: "server exited")])
    }

    @Test("parses %layout-change keeping the layout string")
    func layoutChange() {
        let events = feed("%layout-change @1 bf2c,80x24,0,0 bf2c,80x24,0,0 1\n")
        #expect(events == [.layoutChange(windowID: "@1", layout: "bf2c,80x24,0,0")])
    }

    @Test("surfaces an unrecognized notification as .unhandled")
    func unknown() {
        #expect(feed("%sessions-changed\n") == [.unhandled(line: "%sessions-changed")])
    }

    @Test("buffers a partial line until its newline arrives")
    func partialLine() {
        let parser = TmuxControlParser()
        #expect(parser.feed(Data("%pause ".utf8)).isEmpty)
        #expect(parser.feed(Data("%3\n".utf8)) == [.pause(paneID: "%3")])
    }

    @Test("parses two notifications delivered in one chunk")
    func twoInOneChunk() {
        #expect(feed("%window-add @1\n%window-close @1\n") ==
                [.windowAdd(windowID: "@1"), .windowClose(windowID: "@1")])
    }
}

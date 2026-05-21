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

@Suite("TmuxControlParser — output")
struct TmuxControlParserOutputTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("parses %output with literal text")
    func plainOutput() {
        #expect(feed("%output %3 hello\n") == [.output(paneID: "%3", bytes: Data("hello".utf8))])
    }

    @Test("parses %output with an octal escape")
    func escapedOutput() {
        #expect(feed("%output %3 a\\012b\n") == [.output(paneID: "%3", bytes: Data([97, 10, 98]))])
    }

    @Test("parses %output whose payload contains literal spaces")
    func spacedOutput() {
        #expect(feed("%output %3 a b c\n") == [.output(paneID: "%3", bytes: Data("a b c".utf8))])
    }

    @Test("parses %output with an empty payload")
    func emptyOutput() {
        #expect(feed("%output %3 \n") == [.output(paneID: "%3", bytes: Data())])
    }

    @Test("parses %extended-output with age and payload")
    func extendedOutput() {
        let events = feed("%extended-output %3 150 : hello\n")
        #expect(events == [.extendedOutput(paneID: "%3", ageMillis: 150, bytes: Data("hello".utf8))])
    }
}

@Suite("TmuxControlParser — command blocks")
struct TmuxControlParserBlockTests {
    private func feed(_ string: String) -> [TmuxControlEvent] {
        TmuxControlParser().feed(Data(string.utf8))
    }

    @Test("collects a successful command block's lines")
    func successBlock() {
        let events = feed("%begin 123 7 0\nline one\nline two\n%end 123 7 0\n")
        #expect(events == [.commandSucceeded(number: 7, lines: ["line one", "line two"])])
    }

    @Test("reports a failed command block")
    func errorBlock() {
        let events = feed("%begin 1 2 0\nbad command\n%error 1 2 0\n")
        #expect(events == [.commandFailed(number: 2, lines: ["bad command"])])
    }

    @Test("handles an empty command block")
    func emptyBlock() {
        #expect(feed("%begin 1 3 0\n%end 1 3 0\n") == [.commandSucceeded(number: 3, lines: [])])
    }

    @Test("emits a notification that follows a block")
    func blockThenNotification() {
        let events = feed("%begin 1 4 0\nx\n%end 1 4 0\n%window-add @9\n")
        #expect(events == [.commandSucceeded(number: 4, lines: ["x"]),
                           .windowAdd(windowID: "@9")])
    }
}

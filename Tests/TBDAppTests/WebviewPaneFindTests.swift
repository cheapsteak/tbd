import AppKit
import Testing
import WebKit
@testable import TBDApp

@MainActor
struct WebviewPaneFindTests {
    @Test("webview host starts with hidden Chrome-style find bar")
    func webviewHostStartsWithHiddenFindBar() {
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!)

        #expect(host.findBar.isHidden)
    }

    @Test("text finder command locates enclosing webview host from focused descendant")
    func textFinderCommandLocatesEnclosingWebviewHost() {
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!)
        let focusedDescendant = NSView(frame: .zero)

        host.webView.addSubview(focusedDescendant)

        #expect(TextFinderCommand.webviewHost(from: focusedDescendant) === host)
    }

    @Test("typing in find bar searches immediately")
    func typingInFindBarSearchesImmediately() {
        let client = RecordingFindClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, findClient: client)

        host.showFindBar()
        host.findBar.searchField.stringValue = "needle"
        host.findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        #expect(client.requests == [FindRequest(query: "needle", backwards: false)])
    }

    @Test("enter advances and shift enter goes backward")
    func enterAdvancesAndShiftEnterGoesBackward() {
        let client = RecordingFindClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, findClient: client)

        host.showFindBar()
        host.findBar.searchField.stringValue = "needle"
        host.findBar.submit(backwards: false)
        host.findBar.submit(backwards: true)

        #expect(client.requests == [
            FindRequest(query: "needle", backwards: false),
            FindRequest(query: "needle", backwards: true),
        ])
    }

    @Test("search field return action advances to next result")
    func searchFieldReturnActionAdvancesToNextResult() {
        let client = RecordingFindClient()
        let host = WebviewPaneHostView(url: URL(string: "https://example.com")!, findClient: client)

        host.showFindBar()
        host.findBar.searchField.stringValue = "needle"
        host.findBar.searchField.sendAction(
            host.findBar.searchField.action,
            to: host.findBar.searchField.target
        )

        #expect(client.requests == [FindRequest(query: "needle", backwards: false)])
    }
}

private struct FindRequest: Equatable {
    let query: String
    let backwards: Bool
}

@MainActor
private final class RecordingFindClient: WebviewFindClient {
    var requests: [FindRequest] = []

    func find(_ string: String, backwards: Bool, completionHandler: @escaping (Bool) -> Void) {
        requests.append(FindRequest(query: string, backwards: backwards))
        completionHandler(true)
    }
}

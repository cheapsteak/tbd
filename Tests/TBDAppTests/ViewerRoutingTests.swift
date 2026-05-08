import Foundation
import Testing

@testable import TBDApp

@Suite("ViewerRouting")
struct ViewerRoutingTests {

    @Test func routeFileClick_splitsWhenNoExistingViewer() {
        let terminalID = UUID()
        let layout = LayoutNode.pane(.terminal(terminalID: terminalID))

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/a.md")

        guard case .split(let dir, let children, _) = result else {
            Issue.record("Expected split result"); return
        }
        #expect(dir == .horizontal)
        #expect(children.count == 2)
        #expect(children[0] == .pane(.terminal(terminalID: terminalID)))
        guard case .pane(.codeViewer(_, let path)) = children[1] else {
            Issue.record("Expected codeViewer leaf"); return
        }
        #expect(path == "/a.md")
    }

    @Test func routeFileClick_replacesPathOnExistingViewerKeepingID() {
        let terminalID = UUID()
        let viewerID = UUID()
        let layout = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.codeViewer(id: viewerID, path: "/old.md")),
            ],
            ratios: [0.6, 0.4]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/new.md")

        guard case .split(_, let children, let ratios) = result,
              case .pane(.codeViewer(let id, let path)) = children[1]
        else {
            Issue.record("Expected codeViewer in right child"); return
        }
        #expect(id == viewerID, "paneID must be preserved across path replacement")
        #expect(path == "/new.md")
        #expect(ratios == [0.6, 0.4], "split ratios must be preserved")
    }

    @Test func routeFileClick_findsAndReplacesNestedViewer() {
        let terminalID = UUID()
        let viewerID = UUID()
        let layout = LayoutNode.split(
            direction: .vertical,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .split(
                    direction: .horizontal,
                    children: [
                        .pane(.terminal(terminalID: UUID())),
                        .pane(.codeViewer(id: viewerID, path: "/old")),
                    ],
                    ratios: [0.5, 0.5]
                ),
            ],
            ratios: [0.7, 0.3]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/new")

        guard case .split(_, let topChildren, _) = result,
              case .split(_, let nested, _) = topChildren[1],
              case .pane(.codeViewer(let id, let path)) = nested[1]
        else {
            Issue.record("Expected nested codeViewer"); return
        }
        #expect(id == viewerID)
        #expect(path == "/new")
    }
}

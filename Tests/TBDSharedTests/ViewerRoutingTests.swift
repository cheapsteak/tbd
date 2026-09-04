import Foundation
import Testing

@testable import TBDShared

@Suite("ViewerRouting")
struct ViewerRoutingTests {

    @Test func routeFileClick_splitsWhenNoExistingViewer() {
        let terminalID = UUID()
        let layout = LayoutNode.pane(.terminal(terminalID: terminalID))

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/a.md")

        #expect(result.replaced == nil, "a split is not a replacement — no history push")
        guard case .split(_, let dir, let children, _) = result.layout else {
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
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.codeViewer(id: viewerID, path: "/old.md")),
            ],
            ratios: [0.6, 0.4]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/new.md")

        guard case .split(_, _, let children, let ratios) = result.layout,
              case .pane(.codeViewer(let id, let path)) = children[1]
        else {
            Issue.record("Expected codeViewer in right child"); return
        }
        #expect(id == viewerID, "paneID must be preserved across path replacement")
        #expect(path == "/new.md")
        #expect(ratios == [0.6, 0.4], "split ratios must be preserved")
        #expect(result.replaced == .init(
            paneID: viewerID,
            outgoing: .codeViewer(id: viewerID, path: "/old.md"),
            incoming: .codeViewer(id: viewerID, path: "/new.md")
        ))
    }

    @Test func routeFileClick_findsAndReplacesNestedViewer() {
        let terminalID = UUID()
        let viewerID = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .vertical,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .split(
                    id: UUID(), direction: .horizontal,
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

        guard case .split(_, _, let topChildren, _) = result.layout,
              case .split(_, _, let nested, _) = topChildren[1],
              case .pane(.codeViewer(let id, let path)) = nested[1]
        else {
            Issue.record("Expected nested codeViewer"); return
        }
        #expect(id == viewerID)
        #expect(path == "/new")
    }

    @Test func routeFileClick_reusesLiveTranscriptSlotKeepingID() {
        let terminalID = UUID()
        let slotID = UUID()
        let outgoing = PaneContent.liveTranscript(id: slotID, terminalID: terminalID)
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(outgoing),
            ],
            ratios: [0.5, 0.5]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/a.md")

        guard case .split(_, _, let children, _) = result.layout,
              case .pane(.codeViewer(let id, let path)) = children[1]
        else {
            Issue.record("Expected transcript slot replaced by codeViewer"); return
        }
        #expect(id == slotID, "slot UUID must be preserved")
        #expect(path == "/a.md")
        #expect(result.replaced == .init(
            paneID: slotID,
            outgoing: outgoing,
            incoming: .codeViewer(id: slotID, path: "/a.md")
        ))
    }

    @Test func routeFileClick_reusesWebviewSlotKeepingID() {
        let terminalID = UUID()
        let slotID = UUID()
        let outgoing = PaneContent.webview(id: slotID, url: URL(string: "https://example.com/x")!)
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(outgoing),
            ],
            ratios: [0.5, 0.5]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/a.md")

        guard case .split(_, _, let children, _) = result.layout,
              case .pane(.codeViewer(let id, _)) = children[1]
        else {
            Issue.record("Expected webview slot replaced by codeViewer"); return
        }
        #expect(id == slotID)
        #expect(result.replaced?.outgoing == outgoing)
    }

    @Test func routeFileClick_prefersCodeViewerOverOtherViewerClassPanes() {
        let terminalID = UUID()
        let transcriptID = UUID()
        let viewerID = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                // Transcript comes FIRST in traversal order — the code viewer
                // must still win.
                .pane(.liveTranscript(id: transcriptID, terminalID: terminalID)),
                .pane(.terminal(terminalID: terminalID)),
                .pane(.codeViewer(id: viewerID, path: "/old.md")),
            ],
            ratios: [0.3, 0.4, 0.3]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/new.md")

        #expect(result.replaced?.paneID == viewerID)
        guard case .split(_, _, let children, _) = result.layout,
              case .pane(.liveTranscript(let tid, _)) = children[0]
        else {
            Issue.record("Expected transcript untouched"); return
        }
        #expect(tid == transcriptID, "transcript must survive when a codeViewer exists")
    }

    @Test func routeFileClick_doesNotReuseNotePane() {
        let terminalID = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: terminalID)),
                .pane(.note(noteID: UUID())),
            ],
            ratios: [0.5, 0.5]
        )

        let result = routeFileClick(into: layout, terminalID: terminalID, path: "/a.md")

        #expect(result.replaced == nil, "note panes are not viewer-class — must split instead")
        #expect(result.layout.allPaneIDs().count == 3)
    }

    // MARK: - routeInPaneFileNavigation

    @Test func routeInPaneFileNavigation_swapsThatPaneKeepingItsID() {
        // The whole point of routing through the layout rather than the pane's
        // own state: the pane's `path` is what the header title, the header
        // context menu, the slot history and the persisted layout all read.
        let viewerID = UUID()
        let otherViewerID = UUID()
        let layout = LayoutNode.split(
            id: UUID(), direction: .horizontal,
            children: [
                .pane(.codeViewer(id: otherViewerID, path: "/other.md")),
                .pane(.codeViewer(id: viewerID, path: "/old.md")),
            ],
            ratios: [0.5, 0.5]
        )

        let result = routeInPaneFileNavigation(into: layout, paneID: viewerID, path: "/new.md")

        guard let result,
              case .split(_, _, let children, let ratios) = result.layout,
              case .pane(.codeViewer(let id, let path)) = children[1]
        else {
            Issue.record("Expected codeViewer in right child"); return
        }
        #expect(id == viewerID, "paneID must survive so the slot keeps its history and identity")
        #expect(path == "/new.md")
        #expect(ratios == [0.5, 0.5])
        // The OTHER viewer must not be the one that moved — that is the
        // difference from `routeFileClick`, which picks the first viewer it
        // finds anywhere in the layout.
        #expect(children[0] == .pane(.codeViewer(id: otherViewerID, path: "/other.md")))
        #expect(result.replaced == .init(
            paneID: viewerID,
            outgoing: .codeViewer(id: viewerID, path: "/old.md"),
            incoming: .codeViewer(id: viewerID, path: "/new.md")
        ))
    }

    @Test func routeInPaneFileNavigation_isNilWhenAlreadyShowingThatFile() {
        let viewerID = UUID()
        let layout = LayoutNode.pane(.codeViewer(id: viewerID, path: "/same.md"))

        #expect(routeInPaneFileNavigation(into: layout, paneID: viewerID, path: "/same.md") == nil,
                "a no-op navigation must not push a duplicate history entry")
    }

    @Test func routeInPaneFileNavigation_isNilForAPaneNotInTheLayout() {
        let layout = LayoutNode.pane(.codeViewer(id: UUID(), path: "/a.md"))

        #expect(routeInPaneFileNavigation(into: layout, paneID: UUID(), path: "/b.md") == nil)
    }
}

import Foundation
import Testing

@testable import TBDApp

@Suite("LayoutNode")
struct LayoutNodeTests {

    // MARK: - splitPane

    @Test func splitPane_replacesTargetWithSplit() {
        let id = UUID()
        let newContent = PaneContent.terminal(terminalID: UUID())
        let node = LayoutNode.pane(.terminal(terminalID: id))

        let result = node.splitPane(id: id, direction: .horizontal, newContent: newContent)

        if case .split(let dir, let children, let ratios) = result {
            #expect(dir == .horizontal)
            #expect(children.count == 2)
            #expect(ratios == [0.5, 0.5])
            #expect(children[0] == .pane(.terminal(terminalID: id)))
            #expect(children[1] == .pane(newContent))
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitPane_nonMatchingIDUnchanged() {
        let id = UUID()
        let otherId = UUID()
        let node = LayoutNode.pane(.terminal(terminalID: id))

        let result = node.splitPane(id: otherId, direction: .vertical, newContent: .terminal(terminalID: UUID()))
        #expect(result == node)
    }

    @Test func splitPane_recursesIntoSplit() {
        let id1 = UUID()
        let id2 = UUID()
        let newContent = PaneContent.webview(id: UUID(), url: URL(string: "https://example.com")!)
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [.pane(.terminal(terminalID: id1)), .pane(.terminal(terminalID: id2))],
            ratios: [0.5, 0.5]
        )

        let result = node.splitPane(id: id2, direction: .vertical, newContent: newContent)

        if case .split(_, let children, _) = result {
            #expect(children[0] == .pane(.terminal(terminalID: id1)))
            if case .split(let dir, let innerChildren, _) = children[1] {
                #expect(dir == .vertical)
                #expect(innerChildren.count == 2)
            } else {
                Issue.record("Expected nested split")
            }
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - removePane

    @Test func removePane_removesMatchingLeaf() {
        let id = UUID()
        let node = LayoutNode.pane(.terminal(terminalID: id))
        let result = node.removePane(id: id)
        #expect(result == nil)
    }

    @Test func removePane_keepsNonMatchingLeaf() {
        let id = UUID()
        let node = LayoutNode.pane(.terminal(terminalID: id))
        let result = node.removePane(id: UUID())
        #expect(result == node)
    }

    @Test func removePane_simplifiesSplitToSingleChild() {
        let id1 = UUID()
        let id2 = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [.pane(.terminal(terminalID: id1)), .pane(.terminal(terminalID: id2))],
            ratios: [0.5, 0.5]
        )

        let result = node.removePane(id: id1)
        #expect(result == .pane(.terminal(terminalID: id2)))
    }

    @Test func removePane_renormalizesRatios() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: id1)),
                .pane(.terminal(terminalID: id2)),
                .pane(.terminal(terminalID: id3)),
            ],
            ratios: [0.25, 0.25, 0.5]
        )

        let result = node.removePane(id: id1)
        if case .split(_, let children, let ratios) = result {
            #expect(children.count == 2)
            // 0.25/(0.25+0.5) ≈ 0.333, 0.5/(0.25+0.5) ≈ 0.667
            let sum = ratios.reduce(0, +)
            #expect(abs(sum - 1.0) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - allPaneIDs

    @Test func allPaneIDs_singlePane() {
        let id = UUID()
        let node = LayoutNode.pane(.terminal(terminalID: id))
        #expect(node.allPaneIDs() == [id])
    }

    @Test func allPaneIDs_mixedTypes() {
        let termID = UUID()
        let webID = UUID()
        let codeID = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: termID)),
                .split(
                    direction: .vertical,
                    children: [
                        .pane(.webview(id: webID, url: URL(string: "https://example.com")!)),
                        .pane(.codeViewer(id: codeID, path: "/tmp/file.swift")),
                    ],
                    ratios: [0.5, 0.5]
                ),
            ],
            ratios: [0.5, 0.5]
        )

        let ids = node.allPaneIDs()
        #expect(ids.count == 3)
        #expect(ids.contains(termID))
        #expect(ids.contains(webID))
        #expect(ids.contains(codeID))
    }

    @Test func allTerminalIDs_filtersNonTerminals() {
        let termID = UUID()
        let webID = UUID()
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: termID)),
                .pane(.webview(id: webID, url: URL(string: "https://example.com")!)),
            ],
            ratios: [0.5, 0.5]
        )

        let ids = node.allTerminalIDs()
        #expect(ids == [termID])
    }

    // MARK: - Codable backward compat

    @Test func codable_backwardCompat_oldTerminalFormat() throws {
        // Old format: {"type":"terminal","terminalID":"<uuid>"}
        let uuid = UUID()
        let json = """
        {"type":"terminal","terminalID":"\(uuid.uuidString)"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == .pane(.terminal(terminalID: uuid)))
    }

    @Test func codable_backwardCompat_oldSplitWithTerminals() throws {
        let id1 = UUID()
        let id2 = UUID()
        let json = """
        {
            "type": "split",
            "direction": "horizontal",
            "children": [
                {"type": "terminal", "terminalID": "\(id1.uuidString)"},
                {"type": "terminal", "terminalID": "\(id2.uuidString)"}
            ],
            "ratios": [0.5, 0.5]
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)

        let expected = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: id1)),
                .pane(.terminal(terminalID: id2)),
            ],
            ratios: [0.5, 0.5]
        )
        #expect(decoded == expected)
    }

    // MARK: - Codable roundtrip (new format)

    @Test func codable_roundtrip_paneTerminal() throws {
        let node = LayoutNode.pane(.terminal(terminalID: UUID()))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_roundtrip_paneWebview() throws {
        let node = LayoutNode.pane(.webview(id: UUID(), url: URL(string: "https://example.com")!))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_roundtrip_paneCodeViewer() throws {
        let node = LayoutNode.pane(.codeViewer(id: UUID(), path: "/tmp/test.swift"))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == node)
    }

    @Test func codable_roundtrip_complexTree() throws {
        let node = LayoutNode.split(
            direction: .horizontal,
            children: [
                .pane(.terminal(terminalID: UUID())),
                .split(
                    direction: .vertical,
                    children: [
                        .pane(.webview(id: UUID(), url: URL(string: "https://example.com")!)),
                        .pane(.codeViewer(id: UUID(), path: "/tmp/file.swift")),
                    ],
                    ratios: [0.4, 0.6]
                ),
            ],
            ratios: [0.3, 0.7]
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(LayoutNode.self, from: data)
        #expect(decoded == node)
    }
}

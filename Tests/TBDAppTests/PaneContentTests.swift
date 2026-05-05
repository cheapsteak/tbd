import Foundation
import Testing

@testable import TBDApp

@Suite("PaneContent")
struct PaneContentTests {
    @Test func paneID_terminal() {
        let id = UUID()
        let content = PaneContent.terminal(terminalID: id)
        #expect(content.paneID == id)
    }

    @Test func paneID_webview() {
        let id = UUID()
        let content = PaneContent.webview(id: id, url: URL(string: "https://example.com")!)
        #expect(content.paneID == id)
    }

    @Test func paneID_codeViewer() {
        let id = UUID()
        let content = PaneContent.codeViewer(id: id, path: "/tmp/file.swift")
        #expect(content.paneID == id)
    }

    @Test func codable_roundtrip_terminal() throws {
        let original = PaneContent.terminal(terminalID: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)
        #expect(decoded == original)
    }

    @Test func codable_roundtrip_webview() throws {
        let original = PaneContent.webview(id: UUID(), url: URL(string: "https://example.com/path")!)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)
        #expect(decoded == original)
    }

    @Test func codable_roundtrip_codeViewer() throws {
        let original = PaneContent.codeViewer(id: UUID(), path: "/Users/test/file.swift")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)
        #expect(decoded == original)
    }

    @Test func tab_codable_roundtrip() throws {
        let tab = Tab(
            id: UUID(),
            content: .terminal(terminalID: UUID()),
            label: "Main"
        )
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded == tab)
    }

    @Test func tab_codable_roundtrip_nil_label() throws {
        let tab = Tab(
            id: UUID(),
            content: .webview(id: UUID(), url: URL(string: "https://example.com")!),
            label: nil
        )
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded == tab)
        #expect(decoded.label == nil)
    }

    @Test func paneID_liveTranscript() {
        let paneID = UUID()
        let terminalID = UUID()
        let content = PaneContent.liveTranscript(id: paneID, terminalID: terminalID)
        #expect(content.paneID == paneID)
        #expect(content.paneID != terminalID, "pane ID must be distinct from terminal ID")
    }

    @Test func codable_roundtrip_liveTranscript() throws {
        let original = PaneContent.liveTranscript(id: UUID(), terminalID: UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneContent.self, from: data)
        #expect(decoded == original)
    }

    @Test func liveTranscript_distinct_from_terminal_with_same_uuid() throws {
        let id = UUID()
        let terminal = PaneContent.terminal(terminalID: id)
        let transcript = PaneContent.liveTranscript(id: UUID(), terminalID: id)
        #expect(terminal != transcript)
    }
}

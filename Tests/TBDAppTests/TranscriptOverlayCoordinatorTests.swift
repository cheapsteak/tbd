// Tests/TBDAppTests/TranscriptOverlayCoordinatorTests.swift
import Testing
import Foundation
@testable import TBDApp

@MainActor
struct TranscriptOverlayCoordinatorTests {
    private let t1 = UUID()
    private let t2 = UUID()

    private func itemFrame(_ tid: UUID?, _ id: String, _ session: String? = nil) -> OverlayFrame {
        .item(ItemFrame(terminalID: tid, itemID: id, historySessionID: session))
    }

    @Test func open_fromEmpty_setsCurrent() {
        let c = TranscriptOverlayCoordinator()
        #expect(c.current == nil)
        c.open(terminalID: t1, itemID: "a")
        #expect(c.current == itemFrame(t1, "a"))
        #expect(!c.hasBack)
    }

    @Test func open_sameItem_togglesClosed() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t1, itemID: "a")
        #expect(c.current == nil)
        #expect(!c.isOpen)
    }

    @Test func open_differentItem_swapsStack() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t1, itemID: "b")
        #expect(c.current == itemFrame(t1, "b"))
        #expect(!c.hasBack) // open always resets the stack
    }

    @Test func open_differentTerminal_swapsStack() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t2, itemID: "a")
        #expect(c.current == itemFrame(t2, "a"))
    }

    @Test func pushItem_appendsWithSameTerminal() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushItem(itemID: "child")
        #expect(c.current == itemFrame(t1, "child"))
        #expect(c.hasBack)
    }

    @Test func pushItem_withoutCurrent_isNoOp() {
        let c = TranscriptOverlayCoordinator()
        c.pushItem(itemID: "child")
        #expect(c.current == nil)
    }

    @Test func pop_oneLevel_restoresPrevious() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushItem(itemID: "child")
        c.pop()
        #expect(c.current == itemFrame(t1, "parent"))
        #expect(!c.hasBack)
    }

    @Test func pop_lastFrame_closesOverlay() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.pop()
        #expect(c.current == nil)
        #expect(!c.isOpen)
    }

    @Test func close_clearsStack() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.pushItem(itemID: "b")
        c.close()
        #expect(c.current == nil)
        #expect(!c.isOpen)
    }

    @Test func open_resetsExistingStack() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushItem(itemID: "child")
        c.open(terminalID: t1, itemID: "other")
        #expect(c.current == itemFrame(t1, "other"))
        #expect(!c.hasBack)
    }

    // History-pane branch

    @Test func open_withHistorySessionID_storesIt() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        #expect(c.current == itemFrame(nil, "a", "sess-1"))
    }

    @Test func pushItem_propagatesHistorySessionID() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "parent", historySessionID: "sess-1")
        c.pushItem(itemID: "child")
        #expect(c.current == itemFrame(nil, "child", "sess-1"))
    }

    @Test func open_sameItemDifferentHistorySession_swaps() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-2")
        #expect(c.current == itemFrame(nil, "a", "sess-2"))
    }

    // File frames

    @Test func pushFile_appendsFileFrame() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.pushFile(path: "/tmp/foo.md")
        #expect(c.current == .file(path: "/tmp/foo.md"))
        #expect(c.hasBack)
    }

    @Test func pushFile_withoutOpenOverlay_isNoOp() {
        let c = TranscriptOverlayCoordinator()
        c.pushFile(path: "/tmp/foo.md")
        #expect(c.current == nil)
    }

    @Test func pop_fromFile_returnsToItem() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "agent")
        c.pushFile(path: "/tmp/foo.md")
        c.pop()
        #expect(c.current == itemFrame(t1, "agent"))
        #expect(!c.hasBack)
    }

    @Test func pushFile_thenPushFile_thenPopTwice_returnsToItem() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "agent")
        c.pushFile(path: "/tmp/a.md")
        c.pushFile(path: "/tmp/b.md")
        #expect(c.current == .file(path: "/tmp/b.md"))
        #expect(c.hasBack)
        c.pop()
        #expect(c.current == .file(path: "/tmp/a.md"))
        #expect(c.hasBack)
        c.pop()
        #expect(c.current == itemFrame(t1, "agent"))
        #expect(!c.hasBack)
    }

    @Test func mixedSequence_itemThenFileThenItem_popsCorrectly() {
        // agent → subagent-item → file → back → back → back
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "agent")
        c.pushItem(itemID: "subitem")
        c.pushFile(path: "/tmp/foo.md")
        #expect(c.hasBack)
        c.pop()
        #expect(c.current == itemFrame(t1, "subitem"))
        c.pop()
        #expect(c.current == itemFrame(t1, "agent"))
        c.pop()
        #expect(c.current == nil)
    }
}

// Tests/TBDAppTests/TranscriptOverlayCoordinatorTests.swift
import Testing
import Foundation
@testable import TBDApp

@MainActor
struct TranscriptOverlayCoordinatorTests {
    private let t1 = UUID()
    private let t2 = UUID()

    @Test func open_fromNil_setsOpenOverlay() {
        let c = TranscriptOverlayCoordinator()
        #expect(c.openOverlay == nil)
        c.open(terminalID: t1, itemID: "a")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t1, itemID: "a"))
        #expect(c.parentFrame == nil)
    }

    @Test func open_sameFrame_togglesClosed() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t1, itemID: "a")
        #expect(c.openOverlay == nil)
        #expect(c.parentFrame == nil)
    }

    @Test func open_differentItem_swapsContent_keepsOpen() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t1, itemID: "b")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t1, itemID: "b"))
        #expect(c.parentFrame == nil)
    }

    @Test func open_differentTerminal_swapsContent_keepsOpen() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.open(terminalID: t2, itemID: "a")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t2, itemID: "a"))
        #expect(c.parentFrame == nil)
    }

    @Test func pushAndOpen_savesParent_replacesCurrent() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushAndOpen(itemID: "child")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t1, itemID: "child"))
        #expect(c.parentFrame == TranscriptOverlayFrame(terminalID: t1, itemID: "parent"))
    }

    @Test func pushAndOpen_withoutCurrent_isNoOp() {
        let c = TranscriptOverlayCoordinator()
        c.pushAndOpen(itemID: "child")
        #expect(c.openOverlay == nil)
        #expect(c.parentFrame == nil)
    }

    @Test func popOverlay_withParent_restoresParent() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushAndOpen(itemID: "child")
        c.popOverlay()
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t1, itemID: "parent"))
        #expect(c.parentFrame == nil)
    }

    @Test func popOverlay_withoutParent_closes() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.popOverlay()
        #expect(c.openOverlay == nil)
        #expect(c.parentFrame == nil)
    }

    @Test func close_clearsAll() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        c.pushAndOpen(itemID: "b")
        c.close()
        #expect(c.openOverlay == nil)
        #expect(c.parentFrame == nil)
    }

    @Test func open_whileParentFrameSet_clearsBackStack() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "parent")
        c.pushAndOpen(itemID: "child")          // parentFrame is now set
        c.open(terminalID: t1, itemID: "other") // swap — should clear parentFrame
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: t1, itemID: "other"))
        #expect(c.parentFrame == nil)
    }

    // The historySessionID branch — set when the History pane opens an
    // overlay so the lookup can resolve via AppState.sessionTranscripts
    // without depending on SwiftUI environment scope (#129 follow-up).

    @Test func open_withHistorySessionID_storesIt() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: nil, itemID: "a", historySessionID: "sess-1"))
    }

    @Test func open_terminalBound_defaultsHistorySessionIDToNil() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: t1, itemID: "a")
        #expect(c.openOverlay?.historySessionID == nil)
    }

    @Test func pushAndOpen_propagatesHistorySessionID() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "parent", historySessionID: "sess-1")
        c.pushAndOpen(itemID: "child")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: nil, itemID: "child", historySessionID: "sess-1"))
        #expect(c.parentFrame == TranscriptOverlayFrame(terminalID: nil, itemID: "parent", historySessionID: "sess-1"))
    }

    @Test func open_sameHistoryFrame_togglesClosed() {
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        #expect(c.openOverlay == nil)
    }

    @Test func open_sameItemDifferentHistorySession_swapsContent() {
        // Same itemID across different sessions must NOT be treated as the
        // same frame — Equatable now includes historySessionID, so this
        // opens (swaps) rather than toggling closed.
        let c = TranscriptOverlayCoordinator()
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-1")
        c.open(terminalID: nil, itemID: "a", historySessionID: "sess-2")
        #expect(c.openOverlay == TranscriptOverlayFrame(terminalID: nil, itemID: "a", historySessionID: "sess-2"))
    }
}

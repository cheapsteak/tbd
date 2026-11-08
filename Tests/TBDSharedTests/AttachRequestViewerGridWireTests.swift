import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The viewer's grid on `attach.request`, which a holder session is
/// reshaped to before its snapshot is written. Optional on the wire both ways:
/// an older app sends none and its attach still decodes in a newer daemon, and
/// an older daemon ignores the two keys.
@Suite("attach.request viewer grid wire")
struct AttachRequestViewerGridWireTests {
    private let worktreeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let attachID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    private let terminalID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!

    @Test func anAttachRequestWithoutAGridDecodesToNone() throws {
        let json = """
            {"worktreeID":"\(worktreeID.uuidString)","paneID":"","windowID":"",\
            "attachID":"\(attachID.uuidString)","terminalID":"\(terminalID.uuidString)",\
            "attachSeq":3}
            """
        let old = try JSONDecoder().decode(AttachRequestParams.self, from: Data(json.utf8))
        #expect(old.cols == nil)
        #expect(old.rows == nil)
        #expect(old.attachSeq == 3)
    }

    @Test func aGridSurvivesARoundTrip() throws {
        let params = AttachRequestParams(
            worktreeID: worktreeID, paneID: "", windowID: "", attachID: attachID,
            terminalID: terminalID, attachSeq: 3, cols: 120, rows: 53)
        let decoded = try JSONDecoder().decode(
            AttachRequestParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.cols == 120)
        #expect(decoded.rows == 53)
        #expect(decoded.attachSeq == 3)
        #expect(decoded.terminalID == terminalID)
    }

    /// The initializer's new parameters default to nil, so every existing call
    /// site keeps compiling and names no grid.
    @Test func theGridDefaultsToNone() {
        let params = AttachRequestParams(
            worktreeID: worktreeID, paneID: "%0", windowID: "@0", attachID: attachID)
        #expect(params.cols == nil)
        #expect(params.rows == nil)
    }
}

import Foundation
import Testing
@testable import TBDShared

/// Tier 1. The wire half of the holder viewer-claim sweep
/// (docs/specs/2026-10-25-holder-claim-reconcile-design.md): the app-minted
/// `attachSeq` on `attach.request`, and the `holder.reconcileClaims` params and
/// result. `attachSeq` is optional so an older app's attach still decodes in a
/// newer daemon, where a claim without one is never swept.
@Suite("holder.reconcileClaims wire")
struct HolderReconcileClaimsWireTests {
    private let worktreeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let attachID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    private let terminalID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!

    /// An older app's `attach.request` carries no `attachSeq` and must still
    /// decode, to nil; a newer app's seq survives a round trip.
    @Test func attachRequestParamsDecodesWithoutAttachSeq() throws {
        let json = """
            {"worktreeID":"\(worktreeID.uuidString)","paneID":"","windowID":"",\
            "attachID":"\(attachID.uuidString)","terminalID":"\(terminalID.uuidString)"}
            """
        let old = try JSONDecoder().decode(AttachRequestParams.self, from: Data(json.utf8))
        #expect(old.attachSeq == nil)
        #expect(old.terminalID == terminalID)

        let params = AttachRequestParams(
            worktreeID: worktreeID, paneID: "", windowID: "", attachID: attachID,
            terminalID: terminalID, attachSeq: 42)
        let decoded = try JSONDecoder().decode(
            AttachRequestParams.self, from: JSONEncoder().encode(params))
        #expect(decoded.attachSeq == 42)
        #expect(decoded.terminalID == terminalID)
        #expect(decoded.attachID == attachID)
    }

    /// The initializer's new parameter defaults to nil, so every existing call
    /// site keeps compiling and sends no seq.
    @Test func attachSeqDefaultsToNil() {
        let params = AttachRequestParams(
            worktreeID: worktreeID, paneID: "%0", windowID: "@0", attachID: attachID)
        #expect(params.attachSeq == nil)
    }

    @Test func reconcileParamsRoundTrip() throws {
        let other = UUID()
        let params = HolderReconcileClaimsParams(
            appPID: 4242, held: [terminalID, other], throughSeq: 7)
        let decoded = try JSONDecoder().decode(
            HolderReconcileClaimsParams.self, from: JSONEncoder().encode(params))
        #expect(decoded == params)
        #expect(decoded.appPID == 4242)
        #expect(decoded.held == [terminalID, other])
        #expect(decoded.throughSeq == 7)
    }

    @Test func reconcileResultRoundTripsBothLists() throws {
        let taken = HolderReconcileClaimsResult(takenBack: [terminalID])
        let decodedTaken = try JSONDecoder().decode(
            HolderReconcileClaimsResult.self, from: JSONEncoder().encode(taken))
        #expect(decodedTaken.takenBack == [terminalID])
        #expect(decodedTaken.wouldTakeBack.isEmpty)

        let would = HolderReconcileClaimsResult(wouldTakeBack: [terminalID])
        let decodedWould = try JSONDecoder().decode(
            HolderReconcileClaimsResult.self, from: JSONEncoder().encode(would))
        #expect(decodedWould.takenBack.isEmpty)
        #expect(decodedWould.wouldTakeBack == [terminalID])
    }

    @Test func methodNames() {
        #expect(RPCMethod.holderReconcileClaims == "holder.reconcileClaims")
        #expect(RPCMethod.configSetHolderClaimReconcileEnabled
            == "config.setHolderClaimReconcileEnabled")
    }
}

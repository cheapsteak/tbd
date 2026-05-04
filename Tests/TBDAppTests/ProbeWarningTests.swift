import Foundation
import Testing
@testable import TBDApp

@Test("nil detail returns generic warning")
func probeWarningNilDetail() {
    #expect(probeWarningMessage(for: nil) == "Could not verify reachability. Saving anyway.")
}

@Test("empty detail returns generic warning")
func probeWarningEmptyDetail() {
    #expect(probeWarningMessage(for: "") == "Could not verify reachability. Saving anyway.")
}

@Test("real failure detail returns formatted unreachable warning")
func probeWarningRealFailure() {
    #expect(probeWarningMessage(for: "Connection refused") == "Unreachable — Connection refused. Saving anyway.")
}

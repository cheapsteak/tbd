import Foundation
import Testing
@testable import TBDCLI

@Suite struct SessionEventCommandTests {
    @Test("valid terminal incarnation environment is forwarded")
    func validIncarnation() {
        let incarnationID = UUID()

        #expect(SessionEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": incarnationID.uuidString,
        ]) == incarnationID)
    }

    @Test("absent and invalid terminal incarnation environment remains legacy")
    func legacyIncarnation() {
        #expect(SessionEventCommand.sessionIncarnationID(environment: [:]) == nil)
        #expect(SessionEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": "",
        ]) == nil)
        #expect(SessionEventCommand.sessionIncarnationID(environment: [
            "TBD_TERMINAL_INCARNATION_ID": "not-a-uuid",
        ]) == nil)
    }
}

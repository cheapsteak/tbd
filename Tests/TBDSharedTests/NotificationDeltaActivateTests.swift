import Testing
import Foundation
@testable import TBDShared

@Suite("NotificationDelta.activate")
struct NotificationDeltaActivateTests {
    @Test func defaultsToFalse() {
        let delta = NotificationDelta(
            notificationID: UUID(), worktreeID: UUID(),
            type: .focusRequest, message: nil, terminalID: UUID()
        )
        #expect(delta.activate == false)
    }

    @Test func roundTripsThroughJSON() throws {
        let original = NotificationDelta(
            notificationID: UUID(), worktreeID: UUID(),
            type: .focusRequest, message: "hi", terminalID: UUID(), activate: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationDelta.self, from: data)
        #expect(decoded.activate == true)
        #expect(decoded.type == .focusRequest)
    }

    @Test func missingActivateDecodesToFalse() throws {
        // Simulate an older daemon that didn't send `activate`.
        let json = #"{"notificationID":"\#(UUID().uuidString)","worktreeID":"\#(UUID().uuidString)","type":"focus_request"}"#
        let decoded = try JSONDecoder().decode(NotificationDelta.self, from: Data(json.utf8))
        #expect(decoded.activate == false)
    }
}

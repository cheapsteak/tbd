import Foundation
import Testing
import TBDShared

@Suite("Watch Desk role compatibility")
struct WatchDeskRoleTests {
    @Test("older terminal JSON without a role remains ordinary")
    func absentRoleDefaultsToOrdinary() throws {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(terminal))
                as? [String: Any])
        object.removeValue(forKey: "watchDeskRole")

        let decoded = try JSONDecoder().decode(
            Terminal.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.watchDeskRole == nil)
    }

    @Test("an unknown future role fails closed as read-only")
    func unknownRoleIsReadOnly() throws {
        let data = try JSONSerialization.data(withJSONObject: "future_observer")
        #expect(try JSONDecoder().decode(WatchDeskRole.self, from: data) == .readOnlyCoordinator)
    }
}

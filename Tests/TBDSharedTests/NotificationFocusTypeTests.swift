import Testing
@testable import TBDShared

@Suite("NotificationType.focusRequest")
struct NotificationFocusTypeTests {
    @Test func rawValueIsFocusRequest() {
        #expect(NotificationType.focusRequest.rawValue == "focus_request")
    }

    @Test func decodesFromRawValue() {
        #expect(NotificationType(rawValue: "focus_request") == .focusRequest)
    }

    @Test func severityMatchesAttentionNeeded() {
        #expect(NotificationType.focusRequest.severity == NotificationType.attentionNeeded.severity)
        #expect(NotificationType.focusRequest.severity == 3)
    }
}

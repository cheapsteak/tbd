import Foundation
import Testing
@testable import TBDShared

@Suite struct TransientErrorDetectionTests {
    private let connectionClosed =
        "API Error: Connection closed mid-response. The response above may be incomplete."

    @Test func connectionClosedIsTransient() {
        let d = TransientErrorDetection.detect(messageText: connectionClosed, errorField: "server_error")
        #expect(d == DetectedTransientError(errorClass: "connection_closed", rawMessage: connectionClosed))
    }

    @Test func textAbsentServerErrorClassIsTransient() {
        let d = TransientErrorDetection.detect(messageText: nil, errorField: "server_error")
        #expect(d == DetectedTransientError(errorClass: "server_error", rawMessage: "API error (server_error)"))
    }

    @Test func transient429TextIsTransient() {
        let text = "API Error: 429 {\"error\":{\"message\":\"We're temporarily limiting requests (not your usage limit).\"}}"
        #expect(TransientErrorDetection.detect(messageText: text, errorField: "rate_limit")?.errorClass == "transient_429")
    }

    @Test func serverFiveHundredTextIsTransient() {
        #expect(TransientErrorDetection.detect(messageText: "API Error: 529 Overloaded", errorField: nil)?.errorClass == "server_5xx")
    }

    @Test func hardLimitTextIsNeverTransient() {
        let text = "You've hit your session limit · resets 1pm (America/Toronto)"
        #expect(TransientErrorDetection.detect(messageText: text, errorField: "rate_limit") == nil)
    }

    @Test func rateLimitClassWithoutTransientTextIsNotRetried() {
        #expect(TransientErrorDetection.detect(messageText: nil, errorField: "rate_limit") == nil)
        #expect(TransientErrorDetection.detect(messageText: "", errorField: "rate_limit") == nil)
    }

    @Test func oauthErrorIsExcludedEvenWithServerErrorClass() {
        let text = "API Error: 401 OAuth token has expired. Please run /login."
        #expect(TransientErrorDetection.detect(messageText: text, errorField: "server_error") == nil)
    }

    @Test func creditBalanceIsExcluded() {
        #expect(TransientErrorDetection.detect(messageText: "Your credit balance is too low to access the API.", errorField: nil) == nil)
    }

    @Test func unknownErrorClassWithoutTextIsNotRetried() {
        #expect(TransientErrorDetection.detect(messageText: nil, errorField: "unknown") == nil)
        #expect(TransientErrorDetection.detect(messageText: nil, errorField: nil) == nil)
    }

    @Test func timeoutWordingIsTransient() {
        #expect(TransientErrorDetection.detect(messageText: "API Error: Request timed out.", errorField: nil)?.errorClass == "timeout")
    }

    @Test func unmatchedTextWithServerErrorClassFallsBackToClassRetry() {
        let text = "API Error: something novel went sideways"
        let d = TransientErrorDetection.detect(messageText: text, errorField: "server_error")
        #expect(d == DetectedTransientError(errorClass: "server_error", rawMessage: text))
    }
}

import Foundation
import Testing

@testable import TBDShared

@Suite("FableProbeClassifier")
struct FableProbeClassifierTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func classify(_ json: String) -> FableAvailability {
        FableProbeClassifier.classify(resultJSON: Data(json.utf8), now: now)
    }

    @Test func success_isAvailable() {
        let r = classify(#"{"type":"result","is_error":false,"result":"ok","total_cost_usd":0.001}"#)
        #expect(r.state == .available)
        #expect(r.source == .probe)
        #expect(r.checkedAt == now)
    }

    @Test func outOfCredits_byApiErrorCode_isOut() {
        let r = classify(#"{"is_error":true,"api_error_status":429,"api_error":"model_requires_usage_credits","result":"You're out of usage credits. Switch to another model","total_cost_usd":0}"#)
        #expect(r.state == .out)
        #expect(r.reason == "model_requires_usage_credits")
    }

    @Test func outOfCredits_byResultTextAlone_isOut() {
        let r = classify(#"{"is_error":true,"result":"You’re out of usage credits."}"#)
        #expect(r.state == .out)
    }

    @Test func usageLimitReached_isNeverOut() {
        let r = classify(#"{"is_error":true,"api_error_status":429,"api_error":"usage_limit_reached","result":"You've hit your 5-hour limit · resets 3am (America/Los_Angeles)"}"#)
        #expect(r.state == .unknown)
        #expect(r.reason == "usage_limit_reached")
    }

    @Test func usageLimitReached_withCreditsWordsInText_isStillNotOut() {
        let r = classify(#"{"is_error":true,"api_error":"usage_limit_reached","result":"out of usage credits"}"#)
        #expect(r.state == .unknown)
    }

    @Test func hostileInputs_areUnknown_neverAvailable() {
        let cases: [String] = [
            "",                                            // empty
            "   ",                                         // whitespace
            "not json",
            #"{"is_error":false,"result":"ok""#,           // truncated
            "[]",
            #"[{"is_error":false,"result":"ok"}]"#,        // array, not object
            "null",
            "true",
            #"{}"#,
            #"{"result":"ok"}"#,                           // is_error missing
            #"{"is_error":null,"result":"ok"}"#,
            #"{"is_error":"false","result":"ok"}"#,        // string
            #"{"is_error":0,"result":"ok"}"#,              // number, not a bool
            #"{"is_error":false}"#,                        // no result
            #"{"is_error":false,"result":null}"#,
            #"{"is_error":false,"result":""}"#,
            #"{"is_error":false,"result":"   "}"#,
            #"{"is_error":false,"result":42}"#,
            #"{"is_error":false,"result":"ok","api_error":"overloaded"}"#,  // success + error code
            #"{"is_error":true,"api_error":7,"result":"out of usage credits"}"#,
            #"{"is_error":true,"api_error":["model_requires_usage_credits"]}"#,
            #"{"is_error":true}"#,
            #"{"is_error":true,"api_error":"authentication_error","result":"Invalid API key"}"#,
            #"{"is_error":true,"result":"ECONNREFUSED"}"#,
        ]
        for json in cases {
            let r = classify(json)
            #expect(r.state == .unknown, "input: \(json)")
            #expect(r.reason != nil, "input: \(json)")
        }
    }

    @Test func extraAndMistypedUnrelatedFields_doNotChangeTheVerdict() {
        let ok = classify(#"{"is_error":false,"result":"ok","total_cost_usd":"free","usage":[1,2],"extra":{"a":null}}"#)
        #expect(ok.state == .available)
        let out = classify(#"{"is_error":true,"api_error":"model_requires_usage_credits","total_cost_usd":{},"result":7}"#)
        #expect(out.state == .out)
    }

    @Test func reasonNeverCarriesReplyText() {
        let r = classify(#"{"is_error":true,"api_error":"x y: secret sk-ant-123","result":"hi"}"#)
        #expect(r.state == .unknown)
        #expect(r.reason == "unrecognized_error")
        let long = classify(#"{"is_error":true,"api_error":""# + String(repeating: "a", count: 200) + #""}"#)
        #expect(long.reason == "unrecognized_error")
    }

    @Test func screenText() {
        let line = "You're out of usage credits. Run /usage-credits to keep using Fable 5.2 or /model to switch models."
        let r = FableProbeClassifier.classify(screenText: line, now: now)
        #expect(r?.state == .out)
        #expect(r?.source == .session)
        #expect(FableProbeClassifier.classify(screenText: "You've hit your 5-hour limit", now: now) == nil)
        #expect(FableProbeClassifier.classify(screenText: "", now: now) == nil)
    }
}

@Suite("FableAvailability")
struct FableAvailabilityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ state: FableAvailability.State, at: Date) -> FableAvailability {
        FableAvailability(state: state, checkedAt: at, source: .probe)
    }

    @Test func ttls() {
        #expect(reading(.out, at: t0).ttl == 30 * 60)
        #expect(reading(.available, at: t0).ttl == 6 * 3600)
        #expect(reading(.unknown, at: t0).ttl == 10 * 60)
    }

    @Test func freshness_boundaries() {
        let out = reading(.out, at: t0)
        #expect(out.isFresh(now: t0.addingTimeInterval(30 * 60 - 1)))
        #expect(!out.isFresh(now: t0.addingTimeInterval(30 * 60)))
        #expect(!out.isFresh(now: t0.addingTimeInterval(-5)))   // future-stamped
        #expect(out.isOut(now: t0.addingTimeInterval(60)))
        #expect(!out.isOut(now: t0.addingTimeInterval(31 * 60)))
        #expect(!reading(.available, at: t0).isOut(now: t0))
        #expect(!reading(.unknown, at: t0).isOut(now: t0))
    }

    @Test func codableRoundTrip_andOptionalFieldOnProfileList() throws {
        let value = FableAvailability(state: .out, reason: "model_requires_usage_credits", checkedAt: t0, source: .session)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(FableAvailability.self, from: data) == value)
    }

    @Test func isFableModel() {
        #expect(FableModel.isFable("fable"))
        #expect(FableModel.isFable("claude-fable-5-2"))
        #expect(FableModel.isFable("Fable[1m]"))
        #expect(!FableModel.isFable("opus"))
        #expect(!FableModel.isFable(""))
        #expect(!FableModel.isFable(nil))
    }
}

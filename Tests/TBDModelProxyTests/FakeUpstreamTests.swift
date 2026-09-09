import Foundation
import NIOHTTP1
import Testing

/// The fake upstream's own smoke test. It holds the target open and pins the
/// one thing every later proxy test rests on: a scripted turn arrives at a real
/// HTTP client as the event sequence the script named, in order, and the fake
/// kept the request verbatim.
@Suite("Fake upstream")
struct FakeUpstreamTests {
    @Test("serves a scripted SSE answer over loopback and records the request")
    func servesScript() async throws {
        let script = sseTextAnswer(messageID: "msg_fake_1", deltas: ["Hel", "lo"])
        let upstream = FakeUpstream { _, _ in script }
        // Registered before the start, not after it: `stop()` is idempotent and
        // safe on an unstarted server, and a bind that throws would otherwise
        // leave the event-loop group running for the rest of the test process.
        defer { upstream.stop() }
        let port = try await upstream.start()

        let requestBody = Data(#"{"model":"claude-stub","stream":true}"#.utf8)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/messages")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = requestBody

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        var names: [String] = []
        for try await line in bytes.lines where line.hasPrefix("event: ") {
            names.append(String(line.dropFirst("event: ".count)))
        }

        // Asserted as the whole sequence rather than a count: the count alone
        // would pass on a script that emitted the right number of the wrong
        // events, and the tee reads this order.
        #expect(
            names == [
                "message_start",
                "content_block_start",
                "content_block_delta",
                "content_block_delta",
                "content_block_stop",
                "message_delta",
                "message_stop",
            ])

        let received = upstream.requests
        #expect(received.count == 1)
        #expect(received.first?.head.method == .POST)
        #expect(received.first?.head.uri == "/v1/messages")
        #expect(received.first.map { Data($0.body) } == requestBody)
    }
}

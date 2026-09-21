import Foundation
import TestSupport
import Testing

@testable import TBDModelProxy
@testable import TBDShared

extension ModelProxySuites {
    /// The once-per-route check that a proxied session runs in first-party
    /// mode (`docs/specs/2026-09-21-model-proxy-tool-search-design.md`,
    /// "The probe").
    ///
    /// The verdict is a pure function of the method, the URI and the header
    /// names, so it is pinned here without a logger or a server. The latch is
    /// pinned through its return value: whether a call was the one that
    /// examined the route.
    @Suite("First-party probe")
    struct FirstPartyProbeTests {
        static let messages = "/r/t/v1/messages"

        // MARK: Verdict

        @Test("a messages POST with the header is honored")
        func messagesPostWithHeaderIsHonored() {
            let verdict = FirstPartyProbe.verdict(
                method: "POST", uri: Self.messages,
                headerNames: ["content-type", "x-client-request-id"])
            #expect(verdict == .honored)
        }

        @Test("a messages POST without the header is not honored")
        func messagesPostWithoutHeaderIsNotHonored() {
            let verdict = FirstPartyProbe.verdict(
                method: "POST", uri: Self.messages,
                headerNames: ["content-type", "anthropic-version"])
            #expect(verdict == .notHonored)
        }

        @Test("the query string is stripped before the path is matched")
        func queryStringIsStripped() {
            let uri = Self.messages + "?beta=true"
            #expect(
                FirstPartyProbe.verdict(
                    method: "POST", uri: uri, headerNames: ["x-client-request-id"]) == .honored)
            #expect(
                FirstPartyProbe.verdict(
                    method: "POST", uri: uri, headerNames: ["content-type"]) == .notHonored)
        }

        @Test("the header name matches case-insensitively")
        func headerNameIsCaseInsensitive() {
            let verdict = FirstPartyProbe.verdict(
                method: "POST", uri: Self.messages, headerNames: ["X-Client-Request-Id"])
            #expect(verdict == .honored)
        }

        @Test(
            "requests other than a messages POST say nothing",
            arguments: [
                ("GET", "/r/t/v1/messages"),
                ("POST", "/r/t/v1/messages/count_tokens"),
                ("POST", "/r/t/v1/messages/count_tokens?beta=true"),
                ("HEAD", "/r/t/api/hello"),
            ])
        func otherRequestsAreNotApplicable(method: String, uri: String) {
            // Header or no header: these carry no promise about it either way.
            #expect(
                FirstPartyProbe.verdict(method: method, uri: uri, headerNames: []) == .notApplicable)
            #expect(
                FirstPartyProbe.verdict(
                    method: method, uri: uri, headerNames: ["x-client-request-id"])
                    == .notApplicable)
        }

        // MARK: Latch

        @Test("only the first applicable request per route is examined")
        func latchExaminesFirstApplicableRequestOnly() async {
            let probe = FirstPartyProbe()
            let token = ModelProxyRoute.mintToken()
            let terminalID = UUID()

            // An inapplicable request neither examines nor latches.
            #expect(
                await probe.examine(token: token, terminalID: terminalID, verdict: .notApplicable)
                    == false)
            #expect(
                await probe.examine(token: token, terminalID: terminalID, verdict: .honored))
            #expect(
                await probe.examine(token: token, terminalID: terminalID, verdict: .notHonored)
                    == false)
            #expect(
                await probe.examine(token: token, terminalID: terminalID, verdict: .honored)
                    == false)

            // Latches are per route.
            let other = ModelProxyRoute.mintToken()
            #expect(
                await probe.examine(token: other, terminalID: UUID(), verdict: .honored))
        }

        @Test("forgetting a route resets its latch")
        func forgetResetsLatch() async {
            let probe = FirstPartyProbe()
            let token = ModelProxyRoute.mintToken()
            let terminalID = UUID()

            #expect(await probe.examine(token: token, terminalID: terminalID, verdict: .honored))
            await probe.forget(token: token)
            #expect(await probe.examine(token: token, terminalID: terminalID, verdict: .honored))
        }

        @Test("dropping a route from the table forgets its latch")
        func routeRemovalForgetsLatch() async throws {
            let root = proxyScratchRoot(prefix: "pxfp")
            let routesDir = root.appendingPathComponent("proxy/routes")
            let streamsDir = root.appendingPathComponent("streams")
            try FileManager.default.createDirectory(at: routesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: streamsDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let token = ModelProxyRoute.mintToken()
            let terminalID = UUID()
            let route = ModelProxyRoute(
                token: token, terminalID: terminalID, upstream: "https://api.anthropic.com",
                streamingEnabled: false)
            try route.encodedForRouteFile().write(
                to: routesDir.appendingPathComponent(
                    TBDConstants.modelProxyRouteFileName(token: token)))

            let table = RouteTable(routesDir: routesDir, streamsDir: streamsDir)
            try await table.add(token: token)
            let probe = table.firstPartyProbe

            #expect(await probe.examine(token: token, terminalID: terminalID, verdict: .notHonored))
            #expect(
                await probe.examine(token: token, terminalID: terminalID, verdict: .notHonored)
                    == false)

            await table.remove(token: token)
            #expect(await table.route(for: token) == nil)
            #expect(await probe.examine(token: token, terminalID: terminalID, verdict: .notHonored))
        }
    }
}

import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("ModelProfileHealthProbe")
struct ModelProfileHealthProbeTests {
    @Test("invalid URL returns unreachable with detail")
    func invalidURL() async {
        let r = await ModelProfileHealthProbe.probe(baseURL: "not a url")
        #expect(r.reachable == false)
        #expect(r.detail == "Invalid URL")
        #expect(r.statusCode == nil)
    }

    @Test("URL without host returns unreachable")
    func missingHost() async {
        let r = await ModelProfileHealthProbe.probe(baseURL: "http://")
        #expect(r.reachable == false)
        #expect(r.detail == "Invalid URL")
    }

    @Test("non-http scheme returns unreachable")
    func badScheme() async {
        let r = await ModelProfileHealthProbe.probe(baseURL: "ftp://example.com/")
        #expect(r.reachable == false)
        #expect(r.detail == "Invalid URL")
    }

    @Test("connection refused returns unreachable")
    func refused() async {
        // Port 1 is conventionally closed on macOS dev boxes — TCP RST is fast.
        let r = await ModelProfileHealthProbe.probe(baseURL: "http://127.0.0.1:1", timeout: 2.0)
        #expect(r.reachable == false)
        #expect(r.statusCode == nil)
        #expect(r.detail != nil)
    }
}

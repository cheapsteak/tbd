import Testing
import Foundation
@testable import TBDShared

@Suite struct ModelProxyRouteTests {
    @Test func tokenIs32LowercaseHex() {
        let t = ModelProxyRoute.mintToken()
        #expect(t.count == 32)
        #expect(ModelProxyRoute.isValidToken(t))
        #expect(!ModelProxyRoute.isValidToken(t.uppercased()))
        #expect(!ModelProxyRoute.isValidToken(String(t.dropLast())))
        #expect(!ModelProxyRoute.isValidToken("../etc/passwd"))
    }

    @Test func roundTripsThroughJSON() throws {
        let r = ModelProxyRoute(token: ModelProxyRoute.mintToken(), terminalID: UUID(),
                                upstream: "https://api.anthropic.com", streamingEnabled: true)
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ModelProxyRoute.self, from: data)
        #expect(back == r)
        #expect(back.version == ModelProxyRoute.schemaVersion)
    }

    @Test func pathsDeriveFromTBDHome() {
        let env = ["TBD_HOME": "/tmp/x"]
        #expect(TBDConstants.modelProxyDir(environment: env).path == "/tmp/x/proxy")
        #expect(TBDConstants.modelProxyRoutesDir(environment: env).path == "/tmp/x/proxy/routes")
        #expect(TBDConstants.streamsDir(environment: env).path == "/tmp/x/streams")
        let id = UUID()
        #expect(TBDConstants.streamFilePath(terminalID: id, environment: env) == "/tmp/x/streams/\(id.uuidString).jsonl")
    }
}

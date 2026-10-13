import Foundation
import Testing
@testable import TBDShared

@Suite("Dev server RPC coding")
struct DevServerRPCCodingTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }

    @Test func aListResultRoundTrips() throws {
        let result = DevServerListResult(
            worktreeID: UUID(),
            servers: [DevServerInfo(
                name: "web", label: "Web app", source: "tbd.toml", state: .running,
                exitCode: nil, endpoints: [DevServerEndpoint(name: "app", url: "https://localhost:24123")],
                terminalID: UUID(), pid: 81234, hasStopCommand: false)],
            parseErrors: [DevServerParseError(path: "/tmp/acme/tbd.toml", message: "bad")],
            runningFileDiagnostics: [])
        #expect(try roundTrip(result) == result)
        #expect(result.servers[0].mainURL == "https://localhost:24123")
    }

    @Test func aSavedLastOutputSurvivesTheWire() throws {
        let output = UUID()
        let info = DevServerInfo(
            name: "web", label: "Web app", source: "tbd.toml", state: .exited, exitCode: 3,
            endpoints: [], terminalID: nil, pid: nil, hasStopCommand: false, lastOutputID: output)
        #expect(try roundTrip(info).lastOutputID == output)
    }

    /// An older daemon sends no `lastOutputID`; the app must still decode.
    @Test func aServerWithoutTheLastOutputKeyDecodesNil() throws {
        let info = DevServerInfo(
            name: "web", label: "Web app", source: nil, state: .stopped, exitCode: nil,
            endpoints: [], terminalID: nil, pid: nil, hasStopCommand: false)
        var object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(info)) as? [String: Any])
        object.removeValue(forKey: "lastOutputID")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DevServerInfo.self, from: data).lastOutputID == nil)
    }

    /// An older daemon sends neither status-command key; both decode nil.
    @Test func aServerWithoutTheStatusCommandKeysDecodesNil() throws {
        let info = DevServerInfo(
            name: "db", label: "db", source: "tbd.toml", state: .running, exitCode: nil,
            endpoints: [], terminalID: nil, pid: nil, hasStopCommand: false,
            stateFromStatusCommand: true, hasStatusCommand: true)
        #expect(try roundTrip(info) == info)
        var object = try #require(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(info)) as? [String: Any])
        object.removeValue(forKey: "stateFromStatusCommand")
        object.removeValue(forKey: "hasStatusCommand")
        let decoded = try JSONDecoder().decode(
            DevServerInfo.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.stateFromStatusCommand == nil)
        #expect(decoded.hasStatusCommand == nil)
    }

    /// A newer daemon's state must not fail an older app's whole decode.
    @Test func anUnknownStateDecodesAsUnknown() throws {
        let state = try JSONDecoder().decode(DevServerStateKind.self, from: Data(#""warming""#.utf8))
        #expect(state == .unknown)
    }

    @Test func anUnknownActionStatusDecodesAsFailed() throws {
        let status = try JSONDecoder().decode(DevServerActionStatus.self, from: Data(#""queued""#.utf8))
        #expect(status == .failed)
    }

    @Test func theDeltaRoundTrips() throws {
        let decoded = try JSONDecoder().decode(
            StateDelta.self, from: try JSONEncoder().encode(StateDelta.devServersChanged))
        guard case .devServersChanged = decoded else {
            Issue.record("decoded \(decoded)"); return
        }
    }

    @Test func methodNamesAreStable() {
        #expect(RPCMethod.serverList == "server.list")
        #expect(RPCMethod.serverStart == "server.start")
        #expect(RPCMethod.serverStop == "server.stop")
        #expect(RPCMethod.serverSummary == "server.summary")
    }
}

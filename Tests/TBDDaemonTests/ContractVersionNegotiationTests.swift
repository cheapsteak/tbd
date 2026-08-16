import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// `describeProvider` used to hard-require that `contract_versions` contained
/// `1`, so a `[2]`-only provider was refused outright with "no common contract
/// version". The compiled `claude-cloud` provider declares `[2]` alone — it
/// cannot implement `stop`, which major 1 requires — so the guard has to become
/// an intersection with TBD's own supported set.
///
/// Tier 1: `FakeProviderInvoker` is the only provider, nothing is spawned and
/// nothing touches `~/tbd`.
@Suite("ContractVersionNegotiation")
struct ContractVersionNegotiationTests {

    private func describeJSON(_ versions: [Int]) -> String {
        let list = versions.map(String.init).joined(separator: ",")
        return """
        {"contract_versions":[\(list)],"name":"p","capabilities":["send"],"create_params":[]}
        """
    }

    // MARK: - The pure rule, one case per branch

    @Test func negotiatesTheHighestCommonMajor() {
        #expect(RemoteProviderManager.negotiate(declared: [1, 2]) == 2)
        #expect(RemoteProviderManager.negotiate(declared: [1]) == 1)
        #expect(RemoteProviderManager.negotiate(declared: [2]) == 2)
        #expect(RemoteProviderManager.negotiate(declared: [2, 1]) == 2)
    }

    @Test func refusesOnAnEmptyIntersection() {
        #expect(RemoteProviderManager.negotiate(declared: [3]) == nil)
        #expect(RemoteProviderManager.negotiate(declared: []) == nil)
    }

    // MARK: - The negotiated value reaches the runner

    private func makeManager(
        _ invoker: FakeProviderInvoker
    ) throws -> (RemoteProviderManager, URL) {
        let registry = FileManager.default.temporaryDirectory
            .appendingPathComponent("providers-\(UUID().uuidString).json")
        try Data(#"[{"name":"p","exec":"/bin/true"}]"#.utf8).write(to: registry)
        let db = try TBDDatabase(inMemory: true)
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: invoker, registryURL: registry)
        return (manager, registry)
    }

    @Test func aV2OnlyProviderIsDescribedAndItsVerbsAnnounceTwo() async throws {
        let invoker = FakeProviderInvoker(script: [
            providerOK(describeJSON([2])),
            providerOK(#"{"sessions":[]}"#)
        ])
        let (manager, registry) = try makeManager(invoker)
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.describeAllForTests()
        #expect(await manager.negotiatedContractMajor(for: "p") == 2)

        await manager.pollOnce(provider: RemoteProviderConfig(name: "p", exec: "/bin/true"))
        let versions = invoker.contractVersionsSnapshot()
        #expect(versions.count == 2)
        // The first call is `describe` itself, before anything is negotiated —
        // conservative fallback. The second is `list`, which must carry 2.
        #expect(versions[0] == 1)
        #expect(versions[1] == 2)
    }

    @Test func aV1OnlyProviderStillNegotiatesOne() async throws {
        let invoker = FakeProviderInvoker(script: [providerOK(describeJSON([1]))])
        let (manager, registry) = try makeManager(invoker)
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.describeAllForTests()
        #expect(await manager.negotiatedContractMajor(for: "p") == 1)
    }

    @Test func aProviderWithNoCommonMajorIsRefusedWithAClearError() async throws {
        let invoker = FakeProviderInvoker(script: [providerOK(describeJSON([3]))])
        let (manager, registry) = try makeManager(invoker)
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.describeAllForTests()
        #expect(await manager.negotiatedContractMajor(for: "p") == nil)
        let status = try #require(await manager.providerStatuses().first { $0.config.name == "p" })
        #expect(status.health == .error)
        #expect(status.errorMessage?.contains("no common contract version") == true)
        #expect(status.describe == nil)
    }

    // MARK: - The negotiated value reaches the wire DTO

    /// The path that crosses a process boundary. The app spawns `attach`
    /// itself, directly on the pane's PTY, and never passes through
    /// `RemoteProviderInvoking` — so unless the negotiated major rides
    /// `remote.providers`, the app has no way to learn it and goes on
    /// announcing `1` forever.
    @Test func theNegotiatedMajorReachesTheProviderStatus() async throws {
        let invoker = FakeProviderInvoker(script: [providerOK(describeJSON([1, 2]))])
        let (manager, registry) = try makeManager(invoker)
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.describeAllForTests()
        let status = try #require(await manager.providerStatuses().first { $0.config.name == "p" })
        #expect(status.contractVersion == 2)
    }

    /// Before `describe` lands there is nothing negotiated, and saying so is
    /// what lets the app apply its own conservative fallback rather than
    /// trusting a fabricated number.
    @Test func statusCarriesNoMajorBeforeDescribeSucceeds() async throws {
        let invoker = FakeProviderInvoker(script: [providerOK(describeJSON([3]))])
        let (manager, registry) = try makeManager(invoker)
        defer { try? FileManager.default.removeItem(at: registry) }

        await manager.describeAllForTests()
        let status = try #require(await manager.providerStatuses().first { $0.config.name == "p" })
        #expect(status.contractVersion == nil)
    }

    /// A status encoded by a daemon that predates the field decodes with nil
    /// rather than failing the whole payload.
    @Test func statusFromAnOlderDaemonDecodesWithNoMajor() throws {
        let json = """
        {"config":{"name":"p","exec":"/bin/true"},"health":"ok","freshnessUnreadable":false}
        """
        let decoded = try JSONDecoder().decode(RemoteProviderStatus.self, from: Data(json.utf8))
        #expect(decoded.contractVersion == nil)
        #expect(decoded.config.name == "p")
    }
}

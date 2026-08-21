import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The contract requires `TBD_CONTRACT_VERSION` on every invocation, and the
/// daemon has two emitters of it. Both must announce the major the daemon
/// negotiated for that provider rather than a constant, or a provider that
/// branches on the version sees a different answer per verb.
///
/// Tier 2: the one spawn here is `/bin/sh -c env`, a short-lived child this
/// suite fully controls.
@Suite("ProviderContractEnvironment")
struct ProviderContractEnvironmentTests {

    @Test func runnerEnvironmentCarriesTheNegotiatedMajor() {
        let env = ProviderRunner.invocationEnvironment(
            base: ["PATH": "/usr/bin"], contractVersion: 2)
        #expect(env["TBD_CONTRACT_VERSION"] == "2")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func runnerEnvironmentStillEmitsOneForAV1Provider() {
        let env = ProviderRunner.invocationEnvironment(base: [:], contractVersion: 1)
        #expect(env["TBD_CONTRACT_VERSION"] == "1")
    }

    /// End to end through a real spawn: the variable the child actually sees is
    /// the negotiated major, not the constant the runner used to hardcode.
    @Test func spawnedProviderSeesTheNegotiatedMajor() async throws {
        let config = RemoteProviderConfig(name: "probe", exec: "/bin/sh", args: ["-c", "env"])
        let result = try await ProviderRunner().run(
            config, verb: ["describe"], stdin: nil, timeout: 10, contractVersion: 2)
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        #expect(text.contains("TBD_CONTRACT_VERSION=2"))
        #expect(!text.contains("TBD_CONTRACT_VERSION=1"))
    }

    /// The second daemon-side emitter. It hardcoded `"1"` alongside the
    /// runner's, so the two would disagree for any provider that negotiated
    /// anything else — and the events stream is a long-lived process, so the
    /// disagreement would persist for the provider's whole lifetime.
    @Test func eventsStreamEnvironmentCarriesTheNegotiatedMajor() {
        let env = ProviderEventsSupervisor.streamEnvironment(
            base: ["PATH": "/usr/bin"], contractVersion: 2)
        #expect(env["TBD_CONTRACT_VERSION"] == "2")
        #expect(env["PATH"] == "/usr/bin")
    }

    /// Both emitters agree for a given major — the property that matters, since
    /// they are two independent code paths spawning the same provider.
    @Test func bothDaemonEmittersAgree() {
        for major in [1, 2] {
            let runner = ProviderRunner.invocationEnvironment(base: [:], contractVersion: major)
            let stream = ProviderEventsSupervisor.streamEnvironment(base: [:], contractVersion: major)
            #expect(runner["TBD_CONTRACT_VERSION"] == stream["TBD_CONTRACT_VERSION"])
            #expect(runner["TBD_CONTRACT_VERSION"] == String(major))
        }
    }
}

import Foundation
import Testing
@testable import TBDShared

@Suite("describe.identity")
struct ProviderIdentityTests {
    private func decodeDescribe(_ json: String) throws -> ProviderDescribe {
        try JSONDecoder().decode(ProviderDescribe.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    @Test("identity pairs decode and order well-known keys first")
    func decodesAndOrders() throws {
        let describe = try decodeDescribe("""
        {"contract_versions":[1],"name":"agentbox",
         "identity":{"zone":"a","environment":"staging","account":"acme-1234","box":"i-0abc"}}
        """)

        let pairs = try #require(describe.identity).displayPairs
        #expect(pairs.map(\.key) == ["account", "environment", "box", "zone"])
        #expect(pairs.map(\.value) == ["acme-1234", "staging", "i-0abc", "a"])
    }

    @Test("a provider that sends no identity decodes to nil, not to an empty map")
    func absentIdentityIsNil() throws {
        // Every provider written before the field existed. The distinction
        // matters: nil is what makes the UI say "this provider reports no
        // backend identity" rather than silently showing nothing.
        let describe = try decodeDescribe("""
        {"contract_versions":[1],"name":"agentbox"}
        """)

        #expect(describe.identity == nil)
    }

    @Test("scalars are coerced and unrenderable values cost only their own key")
    func coercesScalarsAndDropsStructures() throws {
        let describe = try decodeDescribe("""
        {"contract_versions":[1],"name":"agentbox",
         "identity":{"account":1234,"multi_tenant":true,"ratio":1.5,
                     "nested":{"a":1},"list":[1],"nothing":null,"environment":"prod"}}
        """)

        let identity = try #require(describe.identity)
        #expect(identity.pairs["account"] == "1234")
        #expect(identity.pairs["multi_tenant"] == "true")
        #expect(identity.pairs["ratio"] == "1.5")
        #expect(identity.pairs["environment"] == "prod")
        #expect(identity.pairs["nested"] == nil)
        #expect(identity.pairs["list"] == nil)
        #expect(identity.pairs["nothing"] == nil)
    }

    @Test("an identity that is not an object costs the map, never the provider")
    func malformedIdentityNeverFailsDescribe() throws {
        // A provider whose identity block is garbage must still register:
        // losing the display pairs costs context, losing `describe` costs the
        // provider.
        let describe = try decodeDescribe("""
        {"contract_versions":[1],"name":"agentbox","capabilities":["attach"],
         "identity":"acme-prod"}
        """)

        #expect(describe.identity == nil)
        #expect(describe.name == "agentbox")
        #expect(describe.capabilities == ["attach"])
    }

    @Test("identity round-trips through the daemon-to-app encode")
    func roundTripsOverTheWire() throws {
        // The app never invokes a provider; it reads `describe` off
        // `RemoteProviderStatus`, which the daemon re-encodes. A field that
        // decodes but doesn't encode would be invisible in the only place it
        // is rendered.
        let describe = try decodeDescribe("""
        {"contract_versions":[1],"name":"agentbox","identity":{"environment":"staging"}}
        """)
        let status = RemoteProviderStatus(
            config: RemoteProviderConfig(name: "agentbox-staging", exec: "/opt/agentbox/bin/agentbox"),
            describe: describe, health: .ok, errorMessage: nil,
            remediationLabel: nil, remediationCommand: nil)

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(RemoteProviderStatus.self, from: data)

        #expect(decoded.describe?.identity?.pairs["environment"] == "staging")
    }

    // MARK: - Redaction

    @Test("secret-named keys are dropped rather than shown")
    func dropsSecretKeys() {
        let identity = ProviderIdentity(pairs: [
            "account": "acme-1234",
            "session_token": "AQoDYXdz…",
            "api_key": "sk-live-1",
            "aws_secret_access_key": "x",
            "password": "hunter2",
            "authorization": "Bearer abc",
            "signature": "sig",
            "cookie": "c",
        ])

        #expect(identity.displayPairs.map(\.key) == ["account"])
    }

    @Test("'session' alone is not treated as secret")
    func sessionIsNotASecretWord() {
        // This domain calls its ordinary unit of work a session; a filter
        // that dropped every key containing the word would redact the
        // identity it exists to show.
        let identity = ProviderIdentity(pairs: ["session_host": "box-4", "session_token": "s3cr3t"])

        #expect(identity.displayPairs.map(\.key) == ["session_host"])
    }

    @Test("long values are truncated and empty ones dropped")
    func boundsValues() {
        let long = String(repeating: "x", count: 200)
        let identity = ProviderIdentity(pairs: ["account": long, "environment": "   "])

        let pairs = identity.displayPairs
        #expect(pairs.count == 1)
        #expect(pairs[0].key == "account")
        #expect(pairs[0].value.count == ProviderIdentityRedaction.maximumValueLength + 1)
        #expect(pairs[0].value.hasSuffix("…"))
    }

    @Test("nothing displayable is reported as nothing displayable")
    func reportsWhenEverythingWasRedacted() {
        #expect(ProviderIdentity(pairs: ["api_key": "sk-1"]).hasDisplayablePairs == false)
        #expect(ProviderIdentity(pairs: ["account": "a"]).hasDisplayablePairs == true)
    }

    @Test("secret-looking command arguments are redacted in both shapes")
    func redactsRegistryArguments() {
        // The registry file is user-authored and outside the contract's
        // reach, so its argv gets the same filter as a provider's identity.
        let redacted = ProviderIdentityRedaction.redactArguments(
            ["--profile", "acme-staging", "--token=abc123", "--api-key", "sk-live", "--verbose"])

        #expect(redacted == [
            "--profile", "acme-staging",
            "--token=\(ProviderIdentityRedaction.redactedPlaceholder)",
            "--api-key", ProviderIdentityRedaction.redactedPlaceholder,
            "--verbose",
        ])
    }

    @Test("a flag following a secret flag is not mistaken for its value")
    func doesNotSwallowTheNextFlag() {
        let redacted = ProviderIdentityRedaction.redactArguments(["--token", "--staging"])

        #expect(redacted == ["--token", "--staging"])
    }
}

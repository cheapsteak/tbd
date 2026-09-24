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

    // MARK: - Command-line redaction

    private let placeholder = ProviderIdentityRedaction.redactedPlaceholder

    @Test("every argument after the first is redacted, one marker each")
    func redactsEveryArgumentAfterTheFirst() {
        #expect(ProviderIdentityRedaction.redactArguments(
            ["--control-plane", "staging", "--region", "us-east-1", "main"])
            == ["--control-plane", placeholder, placeholder, placeholder, placeholder])
    }

    @Test("no arguments render as none")
    func emptyArgumentsStayEmpty() {
        #expect(ProviderIdentityRedaction.redactArguments([]) == [])
    }

    @Test("a bare first argument is shown verbatim")
    func bareFirstArgumentIsShown() {
        #expect(ProviderIdentityRedaction.redactArguments(["serve"]) == ["serve"])
        #expect(ProviderIdentityRedaction.redactArguments(["--verbose"]) == ["--verbose"])
        #expect(ProviderIdentityRedaction.redactArguments(["-v"]) == ["-v"])
    }

    @Test("a first argument carrying an = keeps its name and hides its value")
    func firstArgumentEqualsShapeHidesValue() {
        // Unconditional: the name decides nothing, so an unrecognised flag
        // such as `--bearer=` hides its value exactly like `--token=`.
        #expect(ProviderIdentityRedaction.redactArguments(["--token=abc"]) == ["--token=\(placeholder)"])
        #expect(ProviderIdentityRedaction.redactArguments(["--bearer=abc=def"]) == ["--bearer=\(placeholder)"])
        #expect(ProviderIdentityRedaction.redactArguments(["-Dkey=value"]) == ["-Dkey=\(placeholder)"])
        #expect(ProviderIdentityRedaction.redactArguments(["TOKEN=abc123"]) == ["TOKEN=\(placeholder)"])
    }

    @Test("a first argument with a glued short-flag value keeps the flag and hides the value")
    func firstArgumentGluedShortFlagHidesValue() {
        #expect(ProviderIdentityRedaction.redactArguments(["-tabc"]) == ["-t\(placeholder)"])
        #expect(ProviderIdentityRedaction.redactArguments(["-uuser:pass"]) == ["-u\(placeholder)"])
        #expect(ProviderIdentityRedaction.redactArguments(["-p8080"]) == ["-p\(placeholder)"])
    }

    @Test("a dash-prefixed value after a secret flag never goes out verbatim")
    func dashPrefixedValueAfterSecretFlagIsRedacted() {
        // Position, not shape: the argument after the first is hidden whether
        // or not it starts with a dash, so a token that happens to begin with
        // `-` cannot be mistaken for a harmless flag.
        #expect(ProviderIdentityRedaction.redactArguments(["--token", "-Xk3mZ9qL2vNaB7wQ2"])
            == ["--token", placeholder])
        #expect(ProviderIdentityRedaction.redactArguments(["-t", "--k3mZ9qL2vNaB7wQ2"])
            == ["-t", placeholder])
    }

    @Test("no secret shape survives past the first argument")
    func noShapeSurvivesPastTheFirstArgument() {
        let secrets = [
            "hunter2", "12345678", "sk-live-1", "ghp_abcdef0123456789", "abcdefghijklmnop",
            "--password=hunter2", "-pMyPassword123", "TOKEN=abc", "user:pass",
        ]
        for secret in secrets {
            let redacted = ProviderIdentityRedaction.redactArguments(["serve", secret])
            #expect(redacted == ["serve", placeholder])
            #expect(redacted.joined(separator: " ").contains(secret) == false)
        }
    }
}

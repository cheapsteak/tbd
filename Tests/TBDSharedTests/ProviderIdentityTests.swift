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

    /// Review catch: `isSecretKey`'s substring table can never match a
    /// single-letter flag — `t`/`p`/`k` alone can't contain a five-letter
    /// word like `token`. Before this fix, a short-flag secret like
    /// `-t mypassword1` fell through to the bare-positional heuristic, which
    /// only redacts values >=20 characters, so an ordinary short password
    /// rode straight through. All three of the review's named short flags
    /// (token, password, key) must now redact their value unconditionally,
    /// the same as their long-form spellings do.
    @Test("short-flag credential aliases redact their value even when short")
    func redactsShortFlagAliasValues() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "-t", "mypassword1",
            "-p", "mypassword1",
            "-k", "mypassword1",
        ])

        #expect(redacted == [
            "-t", ProviderIdentityRedaction.redactedPlaceholder,
            "-p", ProviderIdentityRedaction.redactedPlaceholder,
            "-k", ProviderIdentityRedaction.redactedPlaceholder,
        ])
    }

    /// The narrowness of the fix above: an ordinary short flag NOT in the
    /// reviewer-named set must not start swallowing its value. This is the
    /// regression guard against widening `shortSecretFlagAliases` too far.
    @Test("ordinary short flags outside the credential set still pass their value through")
    func doesNotRedactOrdinaryShortFlagValues() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "-n", "myworktree",
            "-e", "staging",
            "-v",
        ])

        #expect(redacted == ["-n", "myworktree", "-e", "staging", "-v"])
    }

    /// Review catch: `--flag=value` only redacted when the FLAG name matched
    /// a secret-key substring, unlike the bare-positional and
    /// space-separated shapes, which both judge an unrecognized value on its
    /// own merits. `--bearer=` and `--pat=` are neither in
    /// `secretKeySubstrings`, so a secret-shaped value riding either flag
    /// name used to reach the screen verbatim — exactly the gap this PR's
    /// redaction fix exists to close.
    @Test("an unrecognized flag's = value is still judged on its own merits")
    func redactsSecretShapedValueBehindUnrecognizedFlagName() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "--bearer=eyJhbGciOiJIUzI1NiJ9.xxx.yyy",
            "--pat=ghp_abcdefghijklmnopqrstuvwxyz",
        ])

        #expect(redacted == [
            "--bearer=\(ProviderIdentityRedaction.redactedPlaceholder)",
            "--pat=\(ProviderIdentityRedaction.redactedPlaceholder)",
        ])
    }

    /// The other half: an unrecognized flag's `=` value that does NOT look
    /// like a secret must still pass through untouched — this shape must not
    /// become as aggressive as blanket-redacting every `=`-joined argument
    /// whose flag name is merely unrecognized.
    @Test("an unrecognized flag's = value that is not secret-shaped is not redacted")
    func doesNotRedactOrdinaryEqualsValue() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "--size=large",
            "--region=us-east-1",
        ])

        #expect(redacted == ["--size=large", "--region=us-east-1"])
    }

    @Test("bare positional secrets with known prefixes are redacted")
    func redactsBarePositionalWithKnownPrefix() {
        // The reported gap: a bare positional secret like `sk-live-…` was
        // not being redacted. This test covers the fix.
        let redacted = ProviderIdentityRedaction.redactArguments(
            ["login", "sk-live-abcdef1234567890"])

        #expect(redacted == [
            "login",
            ProviderIdentityRedaction.redactedPlaceholder,
        ])
    }

    @Test("multiple known secret prefixes are recognized")
    func redactsBarePositionalMultiplePrefixes() {
        // Test coverage of distinct well-known prefixes
        let inputs = [
            ["sk_test_abcdef1234567890"],      // Stripe test
            ["github_pat_abc123xyz789abc"],    // GitHub PAT
            ["ghp_abc123xyz789"],              // GitHub personal
            ["gho_abc123"],                    // GitHub OAuth
            ["xoxb-1234567890-1234567890"],   // Slack bot
            ["xoxp-user-token"],               // Slack user
            ["AKIA1234567890EXAMPLE"],         // AWS access key
            ["eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"], // JWT
        ]

        for input in inputs {
            let redacted = ProviderIdentityRedaction.redactArguments(input)
            #expect(redacted == [ProviderIdentityRedaction.redactedPlaceholder])
        }
    }

    @Test("high-entropy bare positional arguments are redacted even without known prefix")
    func redactsBarePositionalHighEntropy() {
        // A long, random-looking string with mixed letters and digits,
        // no known prefix, but high entropy characteristics
        let redacted = ProviderIdentityRedaction.redactArguments(
            ["api", "Hj8kL2mN9pQrS5tUvW3xYz4AbCdEfG6hIjKl"])

        #expect(redacted == [
            "api",
            ProviderIdentityRedaction.redactedPlaceholder,
        ])
    }

    @Test("ordinary positional arguments are not redacted")
    func doesNotRedactOrdinaryPositionals() {
        // Regression guard: short words, paths, numbers, semver, etc.
        let redacted = ProviderIdentityRedaction.redactArguments([
            "login",              // Short word
            "acme-1234",          // Benign identifier
            "staging",            // Environment name
            "main",               // Branch name
            "1234",               // Port or ID number
            "1.2.3",              // Semver-like version
            "/path/to/repo",      // Path
            "~/config",           // Home path
            "aaaaa",              // Short repetitive
        ])

        #expect(redacted == [
            "login",
            "acme-1234",
            "staging",
            "main",
            "1234",
            "1.2.3",
            "/path/to/repo",
            "~/config",
            "aaaaa",
        ])
    }

    @Test("arguments with excessive repetition are not redacted")
    func doesNotRedactExcessiveRepetition() {
        // Both fixtures clear the 20-character floor on their own (21 and 22
        // chars) so this actually exercises the repetition guard rather than
        // being vacuously true because the length check alone excludes them —
        // dropping the guard would make both of these redact.
        let redacted = ProviderIdentityRedaction.redactArguments([
            "abc1111111111abcdefgh", // 10 consecutive digits
            "xxxxxxxxxxxxxxx1234abc", // 15 consecutive letters
        ])

        #expect(redacted == [
            "abc1111111111abcdefgh",
            "xxxxxxxxxxxxxxx1234abc",
        ])
    }

    @Test("UUIDs are not redacted even though they are long and high-entropy")
    func doesNotRedactUUIDs() {
        // UUIDs have high entropy (mix of hex digits and dashes) but are
        // legitimate identifiers, not credentials. They should not be redacted
        // even when bare positional, because they are not secrets by nature.
        let redacted = ProviderIdentityRedaction.redactArguments([
            "list",
            "550e8400-e29b-41d4-a716-446655440000",
            "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        ])

        #expect(redacted == [
            "list",
            "550e8400-e29b-41d4-a716-446655440000",
            "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        ])
    }

    /// Review catch: the bare-positional heuristic didn't check for a
    /// leading `-`, so a long, digit-bearing, unrecognized FLAG (not a
    /// value) could be redacted right along with a real secret value. This
    /// flag clears every other gate the heuristic applies (24 chars, has a
    /// digit, no excessive repetition, no dots) and must still survive,
    /// because it never reaches the value position the heuristic exists to
    /// judge.
    @Test("a long unrecognized flag is not mistaken for a bare positional secret")
    func doesNotRedactLongFlags() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "--use-http2-multiplexing",
        ])

        #expect(redacted == ["--use-http2-multiplexing"])
    }

    /// Review catch: the original semver carve-out fired on dot COUNT alone
    /// (`>= 2` dots), so any dotted, letter-bearing token format with no
    /// known prefix rode the same exemption real version strings get — the
    /// exact failure mode this whole heuristic exists to close. Both
    /// fixtures below mimic real dot-segmented token shapes (a Discord bot
    /// token's `id.timestamp.hmac`, a PASETO token's `v2.purpose.payload`)
    /// and must be redacted despite their dots.
    @Test("dot-segmented tokens with no known prefix are redacted, not exempted as semver")
    func redactsDottedTokensDespiteSemverShapedDots() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "86274815234787328.1234567890.ABCDEFGHIJKLMNOPQRSTUV",
            "v2.local.AbCdEfGhIjKlMnOpQrStUvWxYz1234567890AbCd",
        ])

        #expect(redacted == [
            ProviderIdentityRedaction.redactedPlaceholder,
            ProviderIdentityRedaction.redactedPlaceholder,
        ])
    }

    /// The other half of the same fix: a genuine version string, long
    /// enough to actually reach the version-shape check (a plain "1.2.3"
    /// is short-circuited by the length floor before ever exercising it —
    /// see `doesNotRedactOrdinaryPositionals`), must still be recognized
    /// and left alone. The leading "v" is what gives this fixture a letter,
    /// which is what clears the entropy gate and reaches the check at all.
    @Test("a long v-prefixed version string is recognized as version-like, not a secret")
    func doesNotRedactLongVersionString() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "v10.2000.30000.400000",
        ])

        #expect(redacted == ["v10.2000.30000.400000"])
    }
}

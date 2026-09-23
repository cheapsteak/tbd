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

    /// A secret flag that directly follows another secret flag must still arm
    /// redaction for its own value; skipping the checks for it leaked
    /// `hunter2` here.
    @Test("a secret flag following a secret flag still redacts its own value")
    func secretFlagAfterSecretFlagRedactsItsValue() {
        let redacted = ProviderIdentityRedaction.redactArguments(["--token", "--password", "hunter2"])

        #expect(redacted == ["--token", "--password", ProviderIdentityRedaction.redactedPlaceholder])
    }

    @Test("an = secret flag following a secret flag is still redacted")
    func equalsSecretFlagAfterSecretFlagIsRedacted() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "--token", "--secret=eyJhbGciOiJIUzI1NiJ9.payload.signature",
        ])

        #expect(redacted == ["--token", "--secret=\(ProviderIdentityRedaction.redactedPlaceholder)"])
    }

    @Test("a chain of valueless secret flags redacts the value that finally follows")
    func chainOfSecretFlagsRedactsTheFinalValue() {
        let redacted = ProviderIdentityRedaction.redactArguments([
            "--token", "--api-key", "--password", "pw",
        ])

        #expect(redacted == [
            "--token", "--api-key", "--password", ProviderIdentityRedaction.redactedPlaceholder,
        ])
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

    @Test("a short credential flag with its value glued on redacts the value")
    func redactsGluedShortFlagValues() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments([
            "-tXk3mZ9qL2vNaB7", "-pMyPassword123", "-uuser:pass", "-kabc",
        ])

        #expect(redacted == [
            "-t\(placeholder)", "-p\(placeholder)", "-u\(placeholder)", "-k\(placeholder)",
        ])
    }

    @Test("a glued short-flag secret does not arm redaction of the next argument")
    func gluedShortFlagDoesNotArmTheNextArgument() {
        let redacted = ProviderIdentityRedaction.redactArguments(["-pMyPassword123", "myworktree"])

        #expect(redacted == ["-p\(ProviderIdentityRedaction.redactedPlaceholder)", "myworktree"])
    }

    @Test("a bare short credential flag still arms redaction of the next argument")
    func bareShortFlagStillArmsTheNextArgument() {
        let redacted = ProviderIdentityRedaction.redactArguments(["-t", "abc", "-u", "user:pass"])

        #expect(redacted == [
            "-t", ProviderIdentityRedaction.redactedPlaceholder,
            "-u", ProviderIdentityRedaction.redactedPlaceholder,
        ])
    }

    @Test("a glued short flag outside the credential set stays verbatim")
    func nonSecretGluedShortFlagIsVerbatim() {
        let redacted = ProviderIdentityRedaction.redactArguments(["-v2", "-n4", "--port", "8080"])

        #expect(redacted == ["-v2", "-n4", "--port", "8080"])
    }

    /// `-AghSecretValue` is letters only and names a secret, so it is also
    /// read as a Go-style long flag (`-Token value`) and redacts the next
    /// argument too — a deliberate over-redaction. `-oMyApiToken123` has a
    /// digit, so it is only a glued flag and leaves the next argument alone.
    @Test("a glued flag outside the aliases whose argument names a secret redacts itself and may redact the next argument")
    func gluedNonAliasSecretRedactsItselfAndMayRedactTheNext() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder

        #expect(ProviderIdentityRedaction.redactArguments(["-oMyApiToken123", "main"])
            == ["-o\(placeholder)", "main"])
        #expect(ProviderIdentityRedaction.redactArguments(["-AghSecretValue", "main"])
            == ["-A\(placeholder)", placeholder])
    }

    @Test("a glued flag with a plain value stays verbatim")
    func gluedFlagWithPlainValueIsVerbatim() {
        let redacted = ProviderIdentityRedaction.redactArguments(["-ofile.txt", "main", "--use-http2-multiplexing"])

        #expect(redacted == ["-ofile.txt", "main", "--use-http2-multiplexing"])
    }

    @Test("a glued flag carrying a secret-shaped value is redacted")
    func gluedFlagWithSecretShapedValueIsRedacted() {
        let redacted = ProviderIdentityRedaction.redactArguments(["-Hghp_abcdef0123456789", "main"])

        #expect(redacted == ["-H\(ProviderIdentityRedaction.redactedPlaceholder)", "main"])
    }

    @Test("an alias glued flag hides everything after its letter, = included")
    func aliasGluedFlagWithEqualsHidesEverything() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments(["-pfoo=bar", "-uuser=pass", "main"])

        #expect(redacted == ["-p\(placeholder)", "-u\(placeholder)", "main"])
    }

    @Test("a non-alias single-dash key=value is judged by its key and value")
    func nonAliasSingleDashEqualsIsJudgedByKeyAndValue() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments([
            "-Dapi.key=secretvalue",
            "-Ddb.url=ghp_abcdef0123456789",
            "-Dfile.encoding=UTF-8",
            "main",
        ])

        #expect(redacted == [
            "-Dapi.key=\(placeholder)",
            "-Ddb.url=\(placeholder)",
            "-Dfile.encoding=UTF-8",
            "main",
        ])
    }

    /// `-token abc` is how Go's flag package spells a long flag, so an
    /// letters-only secret-vocabulary name redacts both its own remainder
    /// and the next argument.
    @Test("a Go-style single-dash secret flag still redacts its next argument")
    func goStyleSingleDashSecretFlagRedactsTheNext() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments(["-token", "abc", "-api-key", "xyz", "main"])

        #expect(redacted == ["-t\(placeholder)", placeholder, "-a\(placeholder)", placeholder, "main"])
    }

    /// The Go-style reading ignores case, as `isSecretKey` does: a
    /// capitalised single-dash secret flag must still redact the argument
    /// after it, not only its own remainder.
    @Test("a capitalised Go-style single-dash secret flag still redacts its next argument")
    func capitalisedGoStyleSingleDashSecretFlagRedactsTheNext() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments([
            "-Token", "abc", "-API-KEY", "xyz", "-Api_Key", "qrs", "main",
        ])

        #expect(redacted == [
            "-T\(placeholder)", placeholder,
            "-A\(placeholder)", placeholder,
            "-A\(placeholder)", placeholder,
            "main",
        ])
    }

    /// A dash-less `KEY=value` is judged like `--flag=value`: a secret-named
    /// key hides even a short value, and a plain key keeps a plain value.
    @Test("a bare KEY=value positional is judged by its key and value")
    func barePositionalKeyValueIsJudgedByKeyAndValue() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let redacted = ProviderIdentityRedaction.redactArguments([
            "TOKEN=abc123",
            "API_KEY=hunter2",
            "db_url=ghp_abcdef0123456789",
            "MODE=fast",
            "main",
        ])

        #expect(redacted == [
            "TOKEN=\(placeholder)",
            "API_KEY=\(placeholder)",
            "db_url=\(placeholder)",
            "MODE=fast",
            "main",
        ])
    }

    /// Every secret-bearing shape from the doc comment, checked both as the
    /// first argument and right after one or more valueless secret flags.
    /// No secret text may survive in any position, and the ordinary trailing
    /// argument must always survive.
    @Test("every secret shape is redacted first and after a secret flag")
    func everySecretShapeInBothPositions() {
        let secret = "hunter2"
        let shapes: [[String]] = [
            ["--token=\(secret)"],
            ["--bearer=ghp_\(secret)abcdefghij"],
            ["-t\(secret)"],
            ["-u\(secret)"],
            ["-oMyApiToken\(secret)"],
            ["-Hghp_\(secret)abcdefghij"],
            ["--token", secret],
            ["--password", secret],
            ["-t", secret],
            ["-k", secret],
            ["-token", secret],
            ["-Token", secret],
            ["-API-KEY", secret],
            ["-Api_Key", secret],
            ["sk-\(secret)"],
            ["x9Kq2mVn8Lp4Rt6Wz1\(secret)"],
            ["-p\(secret)=x"],
            ["-pfoo=\(secret)"],
            ["-t=\(secret)"],
            ["-Dapi.key=\(secret)"],
            ["-Dservice.password=\(secret)"],
            ["TOKEN=\(secret)"],
            ["API_KEY=\(secret)"],
            ["-Ddb.url=ghp_\(secret)abcdefghij"],
        ]
        let prefixes: [[String]] = [[], ["--token"], ["-t"], ["--api-key", "--password"]]
        for shape in shapes {
            for prefix in prefixes {
                let input = prefix + shape + ["main"]
                let redacted = ProviderIdentityRedaction.redactArguments(input)
                #expect(
                    !redacted.contains { $0.contains(secret) },
                    "leaked \(secret) from \(input) as \(redacted)"
                )
                #expect(redacted.last == "main", "swallowed main in \(input) as \(redacted)")
                #expect(redacted.count == input.count)
            }
        }
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

    /// The heuristic's documented limits, pinned both ways: an unprefixed
    /// secret that is all letters, all digits, under 20 characters, or over
    /// 500 characters shows verbatim behind an unrecognized flag or as a bare
    /// positional, and the same value is still redacted behind a
    /// secret-named flag. A change to either side of this boundary must be a
    /// deliberate edit to this test and to the spec.
    @Test("the positional heuristic's documented limits pass through unless a secret-named flag carries them")
    func documentedHeuristicLimitsArePinned() {
        let placeholder = ProviderIdentityRedaction.redactedPlaceholder
        let longValue = String(repeating: "a1b2c3d4e5", count: 51)
        let limits = [
            "xJkLpQmZrTsWnYbHcVfDg",   // all letters, 21 characters
            "4817290356128473",        // all digits
            "k3yQ9zL",                 // under 20 characters
            longValue,                 // over 500 characters
        ]
        #expect(longValue.count > 500)
        for value in limits {
            #expect(ProviderIdentityRedaction.redactArguments(["--webhook", value]) == ["--webhook", value])
            #expect(ProviderIdentityRedaction.redactArguments([value]) == [value])
            #expect(ProviderIdentityRedaction.redactArguments(["--token", value]) == ["--token", placeholder])
            #expect(ProviderIdentityRedaction.redactArguments(["--api-key=\(value)"]) == ["--api-key=\(placeholder)"])
        }
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

import Foundation
import Testing

@testable import TBDDaemonLib

/// `ProfileUsageCredential.token` carries a `claude setup-token` verbatim, and
/// the fetchers that take one log around it. Omitting `CustomStringConvertible`
/// would NOT keep the secret out of those logs: Swift's default reflection
/// renders an enum with an associated value as `token("sk-ant-oat01-…")`, so
/// any `String(describing:)`, any `"\(credential)"`, any `%@` bridge would have
/// printed the whole token. The redacting conformance is what actually enforces
/// the invariant, and these pin it.
@Suite struct ProfileUsageCredentialRedactionTests {
    static let secret = "sk-ant-oat01-supersecrettokenvalue"

    @Test func tokenDescriptionHidesTheSecret() {
        let credential = ProfileUsageCredential.token(Self.secret)
        #expect(credential.description == "token(<redacted>)")
        #expect(!credential.description.contains(Self.secret))
    }

    /// The interpolation and reflection paths, not just the property — those
    /// are the ones a careless log line would actually take.
    @Test func interpolationAndReflectionHideTheSecret() {
        let credential = ProfileUsageCredential.token(Self.secret)
        #expect(!String(describing: credential).contains(Self.secret))
        #expect(!"\(credential)".contains(Self.secret))
        #expect(String(describing: credential) == "token(<redacted>)")
    }

    /// Two different tokens render identically — nothing about the secret leaks
    /// through the rendering, not even a distinguishing tail.
    @Test func differentTokensRenderIdentically() {
        #expect(ProfileUsageCredential.token("aaaa").description
            == ProfileUsageCredential.token("bbbb").description)
    }

    /// The config-dir path is not a secret, and it is the only thing that makes
    /// a `.configDir` failure diagnosable, so it stays visible.
    @Test func configDirKeepsItsPath() {
        let credential = ProfileUsageCredential.configDir("/tmp/profiles/abc/claude")
        #expect(credential.description == "configDir(/tmp/profiles/abc/claude)")
    }

    /// Redacting the rendering must not weaken identity comparison — the poller
    /// dispatches on `Equatable`.
    @Test func equalityStillComparesTheRealValue() {
        #expect(ProfileUsageCredential.token("aaaa") == ProfileUsageCredential.token("aaaa"))
        #expect(ProfileUsageCredential.token("aaaa") != ProfileUsageCredential.token("bbbb"))
    }
}

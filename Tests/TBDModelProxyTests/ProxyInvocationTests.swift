import Foundation
import Testing
@testable import TBDModelProxy
@testable import TBDShared

/// What the daemon is allowed to put on a proxy's command line, and what it is
/// not.
///
/// Every branch of `ProxyArguments.parse` is exercised here rather than through
/// a spawned binary, which is the whole reason `Proxy.swift` exists as a
/// sibling of `main.swift`. The parser is also the one piece of this target
/// another part builds a contract on: the supervisor composes these flags, so a
/// silently-widened parser would be discovered in the field rather than here.
///
/// The environment is passed explicitly on every call. `parse` defaults it to
/// the process environment, and a test that let it — or that reached for
/// `setenv` — would read the developer's real `TBD_HOME` and make the
/// fallback's answer depend on the machine.
@Suite("Proxy invocation")
struct ProxyInvocationTests {
    /// A home no machine has, so a passing assertion cannot be the accident of
    /// a real `~/tbd` existing.
    private static let fencedEnvironment = ["TBD_HOME": "/tmp/tbd-proxy-invocation-fixture"]

    @Test("a full command line parses into its three values")
    func acceptsEveryFlag() throws {
        let parsed = try ProxyArguments.parse(
            ["--port", "8123", "--home", "/tmp/tbd-home", "--lock-fd", "9"],
            environment: Self.fencedEnvironment)

        #expect(parsed == ProxyArguments(port: 8123, home: "/tmp/tbd-home", lockDescriptor: 9))
    }

    /// Zero is the kernel-assigns-one case the first proxy on a home is started
    /// with, so it has to sit inside the accepted range rather than read as
    /// "unset and therefore invalid".
    @Test("port 0 and port 65535 are both inside the range")
    func acceptsThePortBoundaries() throws {
        #expect(try ProxyArguments.parse(["--port", "0"], environment: Self.fencedEnvironment).port == 0)
        #expect(try ProxyArguments.parse(["--port", "65535"], environment: Self.fencedEnvironment).port == 65535)
    }

    /// A port outside the range would reach `bind` and fail there, at which
    /// point the supervisor's address-in-use branch would be handed a failure
    /// that retrying cannot fix. Refusing it here keeps `bindFailed` meaning
    /// only what it says.
    @Test("a port outside 0-65535 is refused rather than passed to bind")
    func refusesAnOutOfRangePort() {
        for text in ["65536", "-1", "not-a-number"] {
            #expect(throws: ProxyStartupError.invalidPort(text)) {
                try ProxyArguments.parse(["--port", text], environment: Self.fencedEnvironment)
            }
        }
    }

    /// The lock descriptor is proof of ownership, not a hint: a negative number
    /// is not a descriptor the spawner could have inherited down, so accepting
    /// it would let a proxy claim a home it never locked.
    @Test("a negative lock descriptor is refused")
    func refusesANegativeLockDescriptor() {
        #expect(throws: ProxyStartupError.invalidLockDescriptor("-1")) {
            try ProxyArguments.parse(["--lock-fd", "-1"], environment: Self.fencedEnvironment)
        }
        #expect(throws: ProxyStartupError.invalidLockDescriptor("nine")) {
            try ProxyArguments.parse(["--lock-fd", "nine"], environment: Self.fencedEnvironment)
        }
    }

    /// No `--lock-fd` at all is a different thing from a bad one: a proxy
    /// started by hand for diagnosis has no lock to inherit, and must still
    /// parse.
    @Test("an absent lock descriptor stays nil")
    func acceptsAnAbsentLockDescriptor() throws {
        let parsed = try ProxyArguments.parse([], environment: Self.fencedEnvironment)
        #expect(parsed.lockDescriptor == nil)
    }

    /// Absent and empty both fall back, and both fall back to the same place
    /// the rest of TBD resolves a home from. An empty `--home` is what a
    /// spawner interpolating an unset shell variable produces, and taking it
    /// literally would point the proxy's `streams/` at the root of the volume.
    @Test("an absent or empty --home falls back to the environment's TBD home")
    func fallsBackToTheEnvironmentHome() throws {
        let expected = TBDConstants.configDir(environment: Self.fencedEnvironment).path

        #expect(try ProxyArguments.parse([], environment: Self.fencedEnvironment).home == expected)
        #expect(
            try ProxyArguments.parse(["--home", ""], environment: Self.fencedEnvironment).home == expected)
        // Discriminating: the fallback has to follow the environment it was
        // handed, not a constant baked at compile time.
        #expect(expected == "/tmp/tbd-proxy-invocation-fixture")
        #expect(
            try ProxyArguments.parse([], environment: ["TBD_HOME": "/tmp/tbd-other-home"]).home
                == "/tmp/tbd-other-home")
    }

    /// Refused, not ignored. The holder tolerates a flag it has never heard of
    /// because a session keeps the holder binary it was born with; a proxy is
    /// replaced whenever its version differs from the daemon's, so an unknown
    /// flag there is a bug and silently dropping it would ship a proxy running
    /// on defaults nobody asked for.
    @Test("an unknown flag, and a bare word, are refused")
    func refusesAnUnknownArgument() {
        #expect(throws: ProxyStartupError.unknownArgument("--stream-dir")) {
            try ProxyArguments.parse(["--stream-dir", "/tmp"], environment: Self.fencedEnvironment)
        }
        #expect(throws: ProxyStartupError.unknownArgument("8123")) {
            try ProxyArguments.parse(["8123"], environment: Self.fencedEnvironment)
        }
    }

    /// A flag whose value fell off the end. Without this branch the trailing
    /// `--port` would parse as "no port given" and the proxy would bind a
    /// kernel-assigned one, quietly abandoning the port its route file names.
    @Test("a flag with no value is refused")
    func refusesAMissingValue() {
        #expect(throws: ProxyStartupError.missingValue("--port")) {
            try ProxyArguments.parse(["--port"], environment: Self.fencedEnvironment)
        }
        #expect(throws: ProxyStartupError.missingValue("--home")) {
            try ProxyArguments.parse(["--port", "0", "--home"], environment: Self.fencedEnvironment)
        }
    }

    /// Every refusal reaches stderr through `errorDescription`, and the two
    /// that name a flag carry the usage line — the only thing a human running
    /// the binary by hand has to go on.
    @Test("argument errors describe themselves with a usage line")
    func errorsCarryTheUsage() {
        #expect(
            ProxyStartupError.unknownArgument("--nope").errorDescription?.contains(ProxyArguments.usage)
                == true)
        #expect(
            ProxyStartupError.missingValue("--home").errorDescription?.contains(ProxyArguments.usage)
                == true)
        #expect(ProxyArguments.usage.contains("--lock-fd"))
    }
}

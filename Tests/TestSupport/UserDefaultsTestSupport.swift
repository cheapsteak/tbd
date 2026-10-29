import Foundation
import Testing

// MARK: - Why this file exists

/// Isolated `UserDefaults` for tests, with a backing file that does not leak.
///
/// TBDApp is an unbundled SPM executable, so `UserDefaults.standard` is the
/// running developer's real `TBDApp.plist`, and every test that touches
/// defaults mints a domain of its own. Tearing that domain down with
/// `removePersistentDomain(forName:)` alone is not enough: on one developer
/// machine the files it leaves behind had reached ~520,000 (~2.1 GB of
/// allocation) in `~/Library/Preferences`.
///
/// # What was measured
///
/// All of the following was established empirically against `cfprefsd` on
/// macOS 15, by checking one exact path at a time (never by enumerating
/// `~/Library/Preferences`, which is far too large to walk):
///
/// 1. A suite's backing store is `<home>/Library/Preferences/<suite>.plist`.
///    Not `ByHost/`.
/// 2. `<home>` is the **real** user home. `scripts/test.sh` points `HOME` and
///    `CFFIXED_USER_HOME` at a scratch directory, but `cfprefsd` resolves
///    preferences over XPC and honours neither — which is precisely why the
///    test fence cannot contain this leak.
/// 3. `removePersistentDomain(forName:)` clears the domain's *values* and
///    leaves the file behind: a 42-byte `bplist00` + empty dict, forever.
/// 4. **No in-process teardown order can win.** Six orderings were tried, ten
///    trials each — remove-then-sync-then-unlink; unlink-then-remove-then-
///    unlink; polling until the empty write lands before unlinking;
///    `removeSuite(named:)` first; per-key `removeObject` first; and an
///    `atexit`-registered second unlink. **All 60 files were present again
///    after the process exited**, and a sweeper started the instant the
///    process exited still lost 1 trial in 10. Which writer puts the file back
///    was not established — CF's own synchronization at exit and `cfprefsd`
///    flushing the domain when its client disconnects both fit. The unlink
///    does take effect (the file is gone the instant teardown returns, which
///    is what `UserDefaultsTestSupportTests` asserts); it simply cannot be the
///    last word.
///
/// # The fix: containment
///
/// A suite name containing `/` makes `cfprefsd` write to a *subdirectory* of
/// `~/Library/Preferences`, creating it if absent (also measured). So every
/// test domain is named `TBDTests.suites/<label>.<uuid>` and every backing file
/// — including one written back after the process exits — lands under the
/// single directory `~/Library/Preferences/TBDTests.suites/`.
///
/// That turns an unbounded population scattered through a directory nobody can
/// safely walk into one exact path that can be reclaimed wholesale. Three
/// things then bound the leak:
///
/// - **Per-suite unlink at teardown** (`TestDefaultsSuite.tearDown`), which
///   removes the file immediately.
/// - **A once-per-process reclaim** of the whole container directory, run
///   before the first suite is minted, which sweeps up whatever was written
///   back after an earlier process had already exited.
/// - **`scripts/test.sh`**, which removes the container before and after each
///   run. Its after-run removal can lose the same race the in-process unlink
///   does, so a file written back late survives until the next reclaim — the
///   population stays bounded by the one directory, not driven to zero.
///
/// Wiping the directory while *other* processes hold live domains in it is
/// safe and was verified: `cfprefsd` serves a live domain from memory, so reads
/// and writes keep working after its file is deleted underneath it.
///
/// # Only the container is ever unlinked from
///
/// The unlink composes a path out of a caller-supplied suite name, so a name
/// such as `../foo` or `TBDTests.suites/../../x` would otherwise delete a file
/// outside the container. Every unlink therefore goes through
/// ``TestDefaults/validatedBackingPlistPath(forSuiteNamed:inHome:)``, which
/// accepts only `TBDTests.suites/<one component>` built from the characters
/// ``TestDefaults/makeSuiteName(label:)`` can produce. A refused name unlinks
/// nothing, leaves the domain untouched, and fails the calling test through
/// `Issue.record` rather than crashing the shared test process.
///
/// # Isolation
///
/// Every suite still gets a fresh UUID. All test targets compile into one
/// process and Swift Testing runs suites in parallel, so a stable shared name
/// would risk cross-talk. Correctness of isolation beats file count: the
/// container directory is what bounds the population, and it bounds it by
/// concurrency rather than by history.

// MARK: - TestDefaults

/// Paths and names for the isolated-`UserDefaults` scheme.
///
/// The one number worth knowing from outside: every file this scheme can
/// create lives under ``containerDirectory``. A run-level guard that wants to
/// count or reclaim test preference files needs that one path and nothing else.
public enum TestDefaults {
    /// The single directory under `~/Library/Preferences` that holds every
    /// test suite's backing plist. Reclaiming the leak is `rm -rf` on this.
    public static let containerName = "TBDTests.suites"

    /// The real user home, as `cfprefsd` sees it.
    ///
    /// Deliberately **not** `NSHomeDirectory()` and **not** `$HOME`: under
    /// `scripts/test.sh` both point at the scratch home, while `cfprefsd`
    /// resolves over XPC against the account database and ignores them. An
    /// unlink aimed at the scratch home would silently target nothing.
    ///
    /// The `no_passwd_home_lookup` SwiftLint rule exists to stop exactly this
    /// call — because code that resolves the real home *escapes* the test
    /// fence. Here that is the point: the file we must delete is outside the
    /// fence whether we like it or not. The rule is scoped to `Sources/` and
    /// does not reach this file; the reasoning is recorded anyway so nobody
    /// "fixes" it later.
    public static let realHomeDirectory: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let home = String(cString: dir)
            if !home.isEmpty { return home }
        }
        return NSHomeDirectory()
    }()

    /// Every home under which a backing file might plausibly have been written.
    ///
    /// The real home is the one that matters. `NSHomeDirectory()` is included
    /// as belt and braces for a host where the two differ in the other
    /// direction; unlinking a path that was never written is a no-op.
    static var candidateHomeDirectories: [String] {
        let ns = NSHomeDirectory()
        return ns == realHomeDirectory ? [realHomeDirectory] : [realHomeDirectory, ns]
    }

    /// `<real home>/Library/Preferences/TBDTests.suites`.
    public static var containerDirectory: String {
        containerDirectory(inHome: realHomeDirectory)
    }

    /// `<home>/Library/Preferences/TBDTests.suites`.
    public static func containerDirectory(inHome home: String) -> String {
        "\(home)/Library/Preferences/\(containerName)"
    }

    /// A fresh, collision-proof suite name for `label`.
    ///
    /// Shaped `TBDTests.suites/<label>.<uuid>` so the backing file lands inside
    /// ``containerDirectory``. `label` only has to make a failure attributable
    /// to the suite that produced it, so it is sanitised rather than rejected.
    public static func makeSuiteName(label: String) -> String {
        reclaimLeftoversOnce()
        return "\(containerName)/\(sanitize(label)).\(UUID().uuidString)"
    }

    /// Allow only characters that are safe in a single path component, so a
    /// label can never escape the container directory or invent a nested one.
    static func sanitize(_ label: String) -> String {
        let mapped = String(label.map { labelCharacters.contains($0) ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unlabeled" : trimmed
    }

    /// What ``sanitize(_:)`` lets through.
    private static let labelCharacters =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// What ``makeSuiteName(label:)`` can put in the component after the
    /// container: a sanitised label, a `.`, and an uppercase UUID string.
    private static let componentCharacters = labelCharacters.union(["." as Character])

    /// The backing plist path `cfprefsd` writes for `suiteName` under `home`,
    /// or `nil` when the name could make an unlink escape the container.
    ///
    /// The single gate every unlink in this file goes through. Accepted, and
    /// only accepted: `TBDTests.suites/<component>` where `<component>` is
    /// non-empty, contains no `/`, is neither `.` nor `..`, and is built only
    /// from characters ``makeSuiteName(label:)`` can produce. As a second,
    /// independent check, the lexically standardised path's parent must be the
    /// standardised container, so no spelling of `home` or of the name that the
    /// component rule somehow let through can land the path anywhere else.
    ///
    /// Takes `home` explicitly so its tests can drive it against a scratch
    /// directory instead of the real `~/Library`.
    public static func validatedBackingPlistPath(
        forSuiteNamed suiteName: String,
        inHome home: String
    ) -> String? {
        let prefix = containerName + "/"
        guard suiteName.hasPrefix(prefix) else { return nil }
        let component = suiteName.dropFirst(prefix.count)
        guard !component.isEmpty,
              component != ".", component != "..",
              component.allSatisfy({ componentCharacters.contains($0) })
        else { return nil }

        let container = containerDirectory(inHome: home)
        let path = "\(container)/\(component).plist"
        // `URL.standardized` resolves `.` and `..` lexically and never consults
        // the file system, so the comparison cannot depend on what exists —
        // unlike `NSString.standardizingPath`, which strips `/private` only
        // when the shortened path happens to exist.
        let standardizedPath = URL(fileURLWithPath: path).standardized
        let standardizedContainer = URL(fileURLWithPath: container).standardized
        guard standardizedPath.deletingLastPathComponent().path == standardizedContainer.path
        else { return nil }
        return standardizedPath.path
    }

    /// Unlink `suiteName`'s backing plist under `home`.
    ///
    /// Goes through ``validatedBackingPlistPath(forSuiteNamed:inHome:)``; a
    /// refused name unlinks nothing. A file that was never written is not an
    /// error.
    ///
    /// - Returns: `false` when the name was refused, `true` otherwise.
    @discardableResult
    public static func removeBackingPlist(forSuiteNamed suiteName: String, inHome home: String) -> Bool {
        guard let path = validatedBackingPlistPath(forSuiteNamed: suiteName, inHome: home) else {
            return false
        }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    /// Delete the container directory, and with it every backing file this
    /// scheme has ever written — including any written back after an earlier
    /// process exited.
    ///
    /// One `removeItem` on one exact path: `~/Library/Preferences` itself is
    /// never enumerated. Safe to call while other processes hold live domains
    /// in the directory (measured: `cfprefsd` serves those from memory).
    public static func reclaimContainerDirectory() {
        for home in candidateHomeDirectories {
            try? FileManager.default.removeItem(atPath: containerDirectory(inHome: home))
        }
    }

    /// Runs ``reclaimContainerDirectory()`` exactly once per process, before
    /// the first suite is minted. `static let` gives us the once-only
    /// semantics and the thread safety for free.
    private static let reclaimOncePerProcess: Void = {
        reclaimContainerDirectory()
    }()

    static func reclaimLeftoversOnce() {
        _ = reclaimOncePerProcess
    }

    /// Why ``tearDown(suiteName:defaults:sourceLocation:)`` refused a name.
    public struct RefusedSuiteName: Error, LocalizedError, CustomStringConvertible {
        public let suiteName: String

        public var description: String {
            "TestDefaults.tearDown refused suite name \"\(suiteName)\": only "
                + "\"\(TestDefaults.containerName)/<label>.<uuid>\" names from "
                + "TestDefaults.makeSuiteName(label:) are torn down, so nothing was "
                + "removed and nothing was unlinked"
        }

        public var errorDescription: String? { description }
    }

    /// Clear `suiteName`'s domain and unlink its backing file.
    ///
    /// The primitive behind ``TestDefaultsSuite/tearDown(sourceLocation:)``, exposed for the
    /// rare site that cannot use the suite object — a `UserDefaults` *subclass*
    /// it has to construct itself, for instance. Pair it with
    /// ``makeSuiteName(label:)``.
    ///
    /// A name ``validatedBackingPlistPath(forSuiteNamed:inHome:)`` refuses is
    /// recorded as a test failure at `sourceLocation`, and nothing else
    /// happens: the domain is not cleared (clearing it would make `cfprefsd`
    /// write the refused path itself) and nothing is unlinked.
    ///
    /// Order matters: `removePersistentDomain` writes the now-empty domain
    /// back out, so unlinking *before* it simply invites the file straight
    /// back. Remove, force the flush, then unlink. A suite that was never
    /// written to has no file, and the unlink tolerates that.
    ///
    /// The unlink is not the last word — the file was measured to reappear
    /// once the process exits, which is why the whole container directory is
    /// also reclaimed once per process. See this file's header.
    public static func tearDown(
        suiteName: String,
        defaults: UserDefaults,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let homes = candidateHomeDirectories
        guard homes.allSatisfy({ validatedBackingPlistPath(forSuiteNamed: suiteName, inHome: $0) != nil })
        else {
            Issue.record(RefusedSuiteName(suiteName: suiteName), sourceLocation: sourceLocation)
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)

        for home in homes {
            removeBackingPlist(forSuiteNamed: suiteName, inHome: home)
        }
    }
}

// MARK: - TestDefaultsSuite

/// An isolated `UserDefaults` suite that cleans up after itself.
///
/// The lifecycle-object form, for suites that hold the defaults across several
/// test methods (a stored property torn down in `deinit` or a teardown hook)
/// and for the common `defer` shape:
///
/// ```swift
/// let suite = TestDefaultsSuite("SelectionPersistence")
/// defer { suite.tearDown() }
/// let state = AppState(userDefaults: suite.defaults)
/// ```
///
/// Bind the suite to a local that lives to the end of the scope, as above.
/// `TestDefaultsSuite("x").defaults` drops the suite at the end of the
/// statement, and `deinit` tears the domain down there and then.
///
/// ``tearDown(sourceLocation:)`` is idempotent, and `deinit` calls it as a safety net so a
/// suite that is dropped without an explicit teardown still unlinks its file.
///
/// `@unchecked Sendable` because tests capture a suite in `@Sendable` closures
/// and `Task {}`s, and its stored state is safe to share: `name` is an
/// immutable `String`, `UserDefaults` is documented thread-safe, and the one
/// mutable field, the torn-down flag, is only read or written under `lock`.
public final class TestDefaultsSuite: @unchecked Sendable {
    /// The full domain name, e.g. `TBDTests.suites/SelectionPersistence.<uuid>`.
    public let name: String

    /// The isolated defaults. Never `UserDefaults.standard`.
    public let defaults: UserDefaults

    private let lock = NSLock()
    private var isTornDown = false

    /// Mint a fresh suite. `label` names the calling test so a stray file can
    /// be traced back to it; it does not need to be unique.
    public init(_ label: String) {
        let name = TestDefaults.makeSuiteName(label: label)
        self.name = name
        self.defaults = TestDefaultsSuite.open(name)
    }

    /// A second, independent `UserDefaults` on this same domain — what a
    /// relaunched app would construct. Values written through either instance
    /// are visible through the other. ``tearDown(sourceLocation:)`` covers both, because it
    /// clears and unlinks the domain rather than an instance.
    public func reopen() -> UserDefaults {
        TestDefaultsSuite.open(name)
    }

    private static func open(_ name: String) -> UserDefaults {
        // `UserDefaults(suiteName:)` only returns nil for a name that collides
        // with the global or registration domain, which a UUID-suffixed name
        // under our own container cannot.
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults(suiteName: \(name)) returned nil")
        }
        return defaults
    }

    /// Clear the domain and unlink its backing file. Idempotent.
    ///
    /// See ``TestDefaults/tearDown(suiteName:defaults:sourceLocation:)`` for
    /// the ordering and for why the unlink cannot be the last word.
    /// `sourceLocation` defaults to the caller's, so anything teardown has to
    /// report lands on the test that tore down rather than on this file;
    /// `deinit`, which has no caller to name, takes the default.
    public func tearDown(sourceLocation: SourceLocation = #_sourceLocation) {
        let isFirst = lock.withLock { () -> Bool in
            defer { isTornDown = true }
            return !isTornDown
        }
        guard isFirst else { return }
        TestDefaults.tearDown(suiteName: name, defaults: defaults, sourceLocation: sourceLocation)
    }

    deinit {
        tearDown()
    }
}

// MARK: - Scoped form

/// Run `body` with an isolated `UserDefaults`, torn down on the way out.
///
/// ```swift
/// withTestDefaults("AppStateIsolation") { defaults in
///     let state = AppState(userDefaults: defaults)
///     …
/// }
/// ```
public func withTestDefaults<T>(
    _ label: String,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (UserDefaults) throws -> T
) rethrows -> T {
    let suite = TestDefaultsSuite(label)
    defer { suite.tearDown() }
    return try body(suite.defaults)
}

/// `async` counterpart of ``withTestDefaults(_:isolation:_:)``.
public func withTestDefaults<T>(
    _ label: String,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (UserDefaults) async throws -> T
) async rethrows -> T {
    let suite = TestDefaultsSuite(label)
    defer { suite.tearDown() }
    return try await body(suite.defaults)
}

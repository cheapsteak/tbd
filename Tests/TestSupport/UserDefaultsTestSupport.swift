import Foundation

// MARK: - Why this file exists

/// Isolated `UserDefaults` for tests, with a backing file that does not leak.
///
/// TBDApp is an unbundled SPM executable, so `UserDefaults.standard` is the
/// running developer's real `TBDApp.plist`. Every suite that touches defaults
/// therefore mints its own domain — and, until this helper existed, tore it
/// down with `removePersistentDomain(forName:)` alone. That is not enough, and
/// the gap cost ~520,000 orphaned files (~2.1 GB) in `~/Library/Preferences`.
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
///    test fence never contained this leak.
/// 3. `removePersistentDomain(forName:)` clears the domain's *values* and
///    leaves the file behind: a 42-byte `bplist00` + empty dict, forever.
/// 4. **No in-process teardown order can win.** Six orderings were tried, ten
///    trials each — remove-then-sync-then-unlink; unlink-then-remove-then-
///    unlink; polling until the empty write lands before unlinking;
///    `removeSuite(named:)` first; per-key `removeObject` first; and an
///    `atexit`-registered second unlink. **All 60 files were present again
///    after the process exited.** `cfprefsd` keeps the domain cached and
///    flushes it to disk when the client disconnects, which is strictly after
///    every `atexit` handler the process can run. The unlink does take effect
///    (the file is gone the instant teardown returns, which is what
///    `UserDefaultsTestSupportTests` asserts); it simply cannot be the last
///    word.
///
/// # The fix: containment
///
/// A suite name containing `/` makes `cfprefsd` write to a *subdirectory* of
/// `~/Library/Preferences`, creating it if absent (also measured). So every
/// test domain is named `TBDTests.suites/<label>.<uuid>` and every backing file
/// — including any that `cfprefsd` resurrects after we exit — lands under the
/// single directory `~/Library/Preferences/TBDTests.suites/`.
///
/// The container is named with a dot rather than a bare `TBDTests` so that a
/// flat `~/Library/Preferences/TBDTests.*` glob — what `scripts/test.sh`'s
/// preferences fingerprint arm matches — is not vacuous: it sees the
/// container. Counting the entries *inside* the container is the cheaper and
/// exact form of the same question, and does not glob a directory with
/// hundreds of thousands of entries in it.
///
/// That turns an unbounded population scattered through a directory nobody can
/// safely walk into one exact path that can be reclaimed wholesale. Two things
/// then bound the leak:
///
/// - **Per-suite unlink at teardown** (`TestDefaultsSuite.tearDown`), which
///   removes the file immediately.
/// - **A once-per-process reclaim** of the whole container directory, run
///   before the first suite is minted, which sweeps up whatever the previous
///   run's `cfprefsd` wrote after that run had already exited.
///
/// Wiping the directory while *other* runs hold live domains in it is safe and
/// was verified: `cfprefsd` serves a live domain from memory, so reads and
/// writes keep working after its file is deleted underneath it.
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

    static func containerDirectory(inHome home: String) -> String {
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

    /// The backing plist path for `suiteName` under `home`.
    static func backingPlistPath(forSuiteNamed suiteName: String, inHome home: String) -> String {
        "\(home)/Library/Preferences/\(suiteName).plist"
    }

    /// The backing plist path `cfprefsd` writes for `suiteName`.
    public static func backingPlistPath(forSuiteNamed suiteName: String) -> String {
        backingPlistPath(forSuiteNamed: suiteName, inHome: realHomeDirectory)
    }

    /// Allow only characters that are safe in a single path component, so a
    /// label can never escape the container directory or invent a nested one.
    static func sanitize(_ label: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = String(label.map { allowed.contains($0) ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unlabeled" : trimmed
    }

    /// Delete the container directory, and with it every backing file this
    /// scheme has ever written — including the ones `cfprefsd` resurrected
    /// after a previous run exited.
    ///
    /// One `removeItem` on one exact path: `~/Library/Preferences` itself is
    /// never enumerated. Safe to call while other runs hold live domains in
    /// the directory (measured: `cfprefsd` serves those from memory).
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

    /// Clear `suiteName`'s domain and unlink its backing file.
    ///
    /// The primitive behind ``TestDefaultsSuite/tearDown()``, exposed for the
    /// rare site that cannot use the suite object — a `UserDefaults` *subclass*
    /// it has to construct itself, for instance. Pair it with
    /// ``makeSuiteName(label:)``.
    ///
    /// Order matters and was measured: `removePersistentDomain` writes the
    /// now-empty domain back out, so unlinking *before* it simply invites the
    /// file straight back. Remove, force the flush, then unlink. A suite that
    /// was never written to has no file, and the unlink tolerates that.
    ///
    /// The unlink is not the last word — `cfprefsd` may re-flush this domain
    /// once the process exits, which is why the whole container directory is
    /// also reclaimed once per process. See this file's header.
    public static func tearDown(suiteName: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)

        for home in candidateHomeDirectories {
            let path = backingPlistPath(forSuiteNamed: suiteName, inHome: home)
            try? FileManager.default.removeItem(atPath: path)
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
/// ``tearDown()`` is idempotent, and `deinit` calls it as a safety net so a
/// suite that is dropped without an explicit teardown still unlinks its file.
public final class TestDefaultsSuite {
    /// The full domain name, e.g. `TBDTests.suites/SelectionPersistence.<uuid>`.
    public let name: String

    /// The isolated defaults. Never `UserDefaults.standard`.
    public let defaults: UserDefaults

    private var isTornDown = false

    /// The exact path `cfprefsd` writes this suite to.
    public var backingPlistPath: String {
        TestDefaults.backingPlistPath(forSuiteNamed: name)
    }

    /// Mint a fresh suite. `label` names the calling test so a stray file can
    /// be traced back to it; it does not need to be unique.
    public init(_ label: String) {
        let name = TestDefaults.makeSuiteName(label: label)
        self.name = name
        // `UserDefaults(suiteName:)` only returns nil for a name that collides
        // with the global or registration domain, which a UUID-suffixed name
        // under our own container cannot.
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults(suiteName: \(name)) returned nil")
        }
        self.defaults = defaults
    }

    /// Clear the domain and unlink its backing file.
    ///
    /// Order matters and was measured: `removePersistentDomain` writes the
    /// now-empty domain back out, so unlinking *before* it simply invites the
    /// file straight back. Remove, force the flush, then unlink. A suite that
    /// was never written to has no file, and the unlink tolerates that.
    ///
    /// The unlink is not the last word — `cfprefsd` may re-flush this domain
    /// once the process exits, which is why `TestDefaults` also reclaims the
    /// whole container directory once per process. See this file's header.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        TestDefaults.tearDown(suiteName: name, defaults: defaults)
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

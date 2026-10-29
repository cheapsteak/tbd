import Foundation
import Testing
import TestSupport

/// Coverage for the helper every defaults-touching test goes through —
/// `Tests/TestSupport/UserDefaultsTestSupport.swift`.
///
/// The invariant under test is **file** state, not domain state, and the
/// distinction is the whole point. `removePersistentDomain(forName:)` clears
/// the values and leaves a 42-byte husk behind forever; a test that asserted
/// "the domain reads empty afterwards" would pass just as happily against the
/// behaviour that leaked ~520,000 files into `~/Library/Preferences`. Only an
/// exact-path `file is gone` assertion can fail without the unlink, so that is
/// what the teardown cases assert.
///
/// Nothing below enumerates `~/Library/Preferences`. It is far too large to
/// walk — a bare `ls -f` does not complete — and walking it would add exactly
/// the churn under investigation. Each case composes one exact path and stats
/// that. The path-validation cases never touch the real `~/Library` at all:
/// they plant their files under a scratch home and drive the validator there.
@Suite("UserDefaults test support")
struct UserDefaultsTestSupportTests {

    /// The path this scheme claims it will write, composed here from literals
    /// rather than by calling the helper's own path builder, so the assertion
    /// is on composed output rather than on the helper agreeing with itself.
    private static func expectedPath(forSuiteNamed name: String, inHome home: String) -> String {
        "\(home)/Library/Preferences/\(name).plist"
    }

    /// A bounded wait on `cfprefsd` landing (or not re-landing) a file, with
    /// the observed state in the diagnostic.
    private struct BackingFileTimeout: Error, CustomStringConvertible {
        let path: String
        let expectedToExist: Bool
        var description: String {
            "backing plist \(expectedToExist ? "never appeared" : "never went away") within "
                + "\(TestDeadlines.saturatedPass): \(path)"
        }
    }

    /// Wait until `path`'s existence equals `expected`. Returns as soon as it
    /// does, so the passing path costs one stat. Records a diagnostic on a
    /// timeout and nothing on a cancellation; returns whether the state held.
    private static func settle(_ path: String, toExist expected: Bool) async -> Bool {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            FileManager.default.fileExists(atPath: path) == expected
        }
        if outcome == .timedOut {
            Issue.record(BackingFileTimeout(path: path, expectedToExist: expected))
        }
        return outcome == .satisfied
    }

    // MARK: - Teardown unlinks the backing file

    @Test("the backing file is gone after teardown")
    func backingFileIsUnlinkedOnTearDown() async {
        let suite = TestDefaultsSuite("ProvesTheUnlink")
        defer { suite.tearDown() }
        let path = Self.expectedPath(forSuiteNamed: suite.name, inHome: TestDefaults.realHomeDirectory)

        // The helper's own answer must equal the independently composed one.
        #expect(
            TestDefaults.validatedBackingPlistPath(
                forSuiteNamed: suite.name, inHome: TestDefaults.realHomeDirectory) == path
        )

        suite.defaults.set("written", forKey: "probe")
        suite.defaults.synchronize()

        // Guard against a vacuous pass: if the write never produced a file,
        // "gone after teardown" would hold no matter what teardown did.
        guard await Self.settle(path, toExist: true) else { return }

        suite.tearDown()

        // The assertion that fails if the unlink is removed from `tearDown`.
        // `removePersistentDomain` alone leaves the file behind.
        #expect(
            FileManager.default.fileExists(atPath: path) == false,
            "backing plist survived teardown: \(path)"
        )
    }

    @Test("a suite that was never written to tears down without error")
    func neverWrittenSuiteTearsDownCleanly() throws {
        let suite = TestDefaultsSuite("NeverWritten")
        let path = try #require(
            TestDefaults.validatedBackingPlistPath(
                forSuiteNamed: suite.name, inHome: TestDefaults.realHomeDirectory)
        )

        #expect(FileManager.default.fileExists(atPath: path) == false)
        suite.tearDown()
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("teardown is idempotent")
    func tearDownIsIdempotent() async throws {
        let suite = TestDefaultsSuite("Idempotent")
        let path = try #require(
            TestDefaults.validatedBackingPlistPath(
                forSuiteNamed: suite.name, inHome: TestDefaults.realHomeDirectory)
        )
        suite.defaults.set(1, forKey: "probe")
        suite.defaults.synchronize()
        guard await Self.settle(path, toExist: true) else {
            suite.tearDown()
            return
        }

        suite.tearDown()
        suite.tearDown()

        #expect(FileManager.default.fileExists(atPath: path) == false, "backing plist survived: \(path)")
    }

    @Test("the scoped form unlinks the backing file on the way out")
    func scopedFormUnlinksOnExit() async {
        // A label unique to this run, so the lookup below cannot pick up a
        // sibling suite's file. Listing the *container* directory is fine —
        // it is small and ours; `~/Library/Preferences` itself is never walked.
        let label = "ScopedForm-\(UUID().uuidString)"

        let written: [String] = await withTestDefaults(label) { (defaults: UserDefaults) async -> [String] in
            defaults.set("written", forKey: "probe")
            defaults.synchronize()
            let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
                Self.containerFiles(labelled: label).count == 1
            }
            let files = Self.containerFiles(labelled: label)
            if outcome == .timedOut {
                Issue.record(BackingFileTimeout(
                    path: "\(TestDefaults.containerDirectory)/\(label).*.plist (saw \(files))",
                    expectedToExist: true))
            }
            return files
        }

        #expect(written.count == 1, "expected one backing file for \(label), saw \(written)")
        for path in written {
            #expect(FileManager.default.fileExists(atPath: path) == false, "scoped form leaked: \(path)")
        }
    }

    /// Paths inside the container directory whose name starts with `label`.
    private static func containerFiles(labelled label: String) -> [String] {
        let dir = TestDefaults.containerDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix(label + ".") }.map { "\(dir)/\($0)" }
    }

    // MARK: - Names and containment

    /// Every backing file this scheme can create — including one `cfprefsd`
    /// resurrects after the process exits, which no in-process unlink can
    /// prevent — lives inside one directory. That containment is what makes
    /// the leak reclaimable at all, so it is asserted rather than assumed.
    @Test("every suite's backing file is inside the container directory")
    func backingFilesAreContained() throws {
        let container =
            "\(TestDefaults.realHomeDirectory)/Library/Preferences/\(TestDefaults.containerName)"
        #expect(TestDefaults.containerDirectory == container)

        for label in ["Alpha", "beta-two", "com.tbd.tests.gamma", "../escape", "a/b", ".", ".."] {
            let suite = TestDefaultsSuite(label)
            defer { suite.tearDown() }

            let path = try #require(
                TestDefaults.validatedBackingPlistPath(
                    forSuiteNamed: suite.name, inHome: TestDefaults.realHomeDirectory),
                "makeSuiteName produced a name the validator refuses: \(suite.name)"
            )
            #expect(path.hasPrefix(container + "/"), "escaped the container: \(path)")
            // One path component inside the container — no nesting, no `..`.
            let remainder = path.dropFirst(container.count + 1)
            #expect(remainder.contains("/") == false, "nested: \(remainder)")
            #expect(remainder.hasSuffix(".plist"))
        }
    }

    @Test("an empty label still yields a contained, attributable name")
    func emptyLabelIsContained() {
        let suite = TestDefaultsSuite("")
        defer { suite.tearDown() }
        #expect(suite.name.hasPrefix("\(TestDefaults.containerName)/unlabeled."))
    }

    @Test("the suite name carries the label and a fresh UUID")
    func suiteNamesAreLabelledAndUnique() {
        let first = TestDefaultsSuite("Labelled")
        defer { first.tearDown() }
        let second = TestDefaultsSuite("Labelled")
        defer { second.tearDown() }

        #expect(first.name.hasPrefix("\(TestDefaults.containerName)/Labelled."))
        #expect(second.name.hasPrefix("\(TestDefaults.containerName)/Labelled."))
        #expect(first.name != second.name)

        let uuid = first.name.dropFirst("\(TestDefaults.containerName)/Labelled.".count)
        #expect(UUID(uuidString: String(uuid)) != nil)
    }

    @Test("a reopened instance reads and writes the same domain")
    func reopenSharesTheDomain() {
        let suite = TestDefaultsSuite("Reopen")
        defer { suite.tearDown() }

        suite.defaults.set("first", forKey: "probe")
        let relaunched = suite.reopen()
        #expect(relaunched.string(forKey: "probe") == "first")
        relaunched.set("second", forKey: "probe")
        #expect(suite.defaults.string(forKey: "probe") == "second")
    }

    // MARK: - The unlink never escapes the container

    /// A scratch home under the temporary directory, so these cases plant and
    /// stat files without ever touching the real `~/Library`.
    private static func makeScratchHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-userdefaults-validator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    /// Create a sentinel file at `path` (and any missing parents).
    private static func plant(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardized
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: url)
    }

    /// Each of these names would, composed naively as
    /// `<home>/Library/Preferences/<name>.plist`, point the unlink somewhere
    /// other than one file directly inside the container. A sentinel is
    /// planted at exactly that naive path, so a validator that let the name
    /// through would delete it.
    @Test("names that could escape or nest are refused and unlink nothing", arguments: [
        "../escape",
        "TBDTests.suites/../escape",
        "TBDTests.suites/../../escape",
        "TBDTests.suites/a/b",
        "Other/x",
        "TBDTests.suites/",
        "TBDTests.suites/..",
        "TBDTests.suites/.",
        "TBDTests.suites",
        "TBDTests.suitesX/y",
        "TBDTests.suites/has space",
        "/TBDTests.suites/x",
    ])
    func refusedNamesUnlinkNothing(name: String) throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let naive = URL(fileURLWithPath: Self.expectedPath(forSuiteNamed: name, inHome: home))
            .standardized.path
        try Self.plant(naive)

        #expect(TestDefaults.validatedBackingPlistPath(forSuiteNamed: name, inHome: home) == nil)
        #expect(TestDefaults.removeBackingPlist(forSuiteNamed: name, inHome: home) == false)
        #expect(FileManager.default.fileExists(atPath: naive), "a refused name unlinked \(naive)")
    }

    @Test("a name from makeSuiteName is accepted and only its own file is removed")
    func acceptedNameRemovesOnlyItsFile() throws {
        let home = try Self.makeScratchHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let name = TestDefaults.makeSuiteName(label: "Accepted")
        let sibling = TestDefaults.makeSuiteName(label: "Sibling")
        let path = Self.expectedPath(forSuiteNamed: name, inHome: home)
        let siblingPath = Self.expectedPath(forSuiteNamed: sibling, inHome: home)
        try Self.plant(path)
        try Self.plant(siblingPath)

        #expect(TestDefaults.validatedBackingPlistPath(forSuiteNamed: name, inHome: home) == path)
        #expect(TestDefaults.removeBackingPlist(forSuiteNamed: name, inHome: home))
        #expect(FileManager.default.fileExists(atPath: path) == false, "accepted name's file survived: \(path)")
        #expect(FileManager.default.fileExists(atPath: siblingPath), "a sibling's file was removed: \(siblingPath)")
    }

    /// The public teardown must make a refused name a test failure, not a
    /// silent no-op and not a crash. The name nests inside the container, so
    /// even a validator that wrongly let it through could only reach a path
    /// the container reclaim already owns.
    @Test("teardown records a refused name as a failure and leaves the suite alone")
    func tearDownRecordsARefusedName() {
        let suite = TestDefaultsSuite("RefusedTearDown")
        defer { suite.tearDown() }
        suite.defaults.set("kept", forKey: "probe")

        let refused = "\(TestDefaults.containerName)/nested/\(UUID().uuidString)"
        withKnownIssue("a nested suite name must be refused") {
            TestDefaults.tearDown(suiteName: refused, defaults: suite.defaults)
        } matching: { issue in
            issue.error is TestDefaults.RefusedSuiteName
        }

        #expect(suite.defaults.string(forKey: "probe") == "kept")
    }
}

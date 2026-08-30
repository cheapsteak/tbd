import Foundation
import Testing
import TestSupport

/// Coverage for the helper every defaults-touching suite in this target now
/// goes through — `Tests/TestSupport/UserDefaultsTestSupport.swift`.
///
/// The invariant under test is **file** state, not domain state, and the
/// distinction is the whole point. `removePersistentDomain(forName:)` clears
/// the values and leaves a 42-byte husk behind forever; a test that asserted
/// "the domain reads empty afterwards" would pass just as happily against the
/// broken behaviour that leaked ~520,000 files into `~/Library/Preferences`.
/// Only an exact-path `file is gone` assertion can fail without the unlink, so
/// that is what every case here asserts.
///
/// Nothing below enumerates `~/Library/Preferences`. It is far too large to
/// walk — a bare `ls -f` does not complete — and walking it would add exactly
/// the churn under investigation. Each case composes one exact path and stats
/// that.
@Suite("UserDefaults test support")
struct UserDefaultsTestSupportTests {

    /// The path this scheme claims it will write, composed here from literals
    /// rather than by calling the helper's own path builder, so the assertion
    /// is on composed output rather than on the helper agreeing with itself.
    private func expectedPath(forSuiteNamed name: String) -> String {
        "\(TestDefaults.realHomeDirectory)/Library/Preferences/\(name).plist"
    }

    /// Stat one exact path, waiting briefly for `cfprefsd` to land a write.
    /// Returns as soon as the answer matches `expected`, so the passing path
    /// costs nothing.
    private func fileExists(_ path: String, settlingTo expected: Bool) -> Bool {
        var observed = FileManager.default.fileExists(atPath: path)
        var waited = 0
        while observed != expected && waited < 200 {
            usleep(10_000)
            waited += 1
            observed = FileManager.default.fileExists(atPath: path)
        }
        return observed
    }

    @Test("the backing file is gone after teardown")
    func backingFileIsUnlinkedOnTearDown() {
        let suite = TestDefaultsSuite("ProvesTheUnlink")
        let path = expectedPath(forSuiteNamed: suite.name)

        // The helper's own answer must equal the independently composed one.
        #expect(suite.backingPlistPath == path)

        suite.defaults.set("written", forKey: "probe")
        suite.defaults.synchronize()

        // Guard against a vacuous pass: if the write never produced a file,
        // "gone after teardown" would hold no matter what teardown did.
        #expect(
            fileExists(path, settlingTo: true),
            "cfprefsd wrote no backing file, so this case cannot discriminate: \(path)"
        )

        suite.tearDown()

        // The assertion that fails if the unlink is removed from `tearDown`.
        // `removePersistentDomain` alone leaves the file behind.
        #expect(
            fileExists(path, settlingTo: false) == false,
            "backing plist survived teardown: \(path)"
        )
    }

    @Test("a suite that was never written to tears down without error")
    func neverWrittenSuiteTearsDownCleanly() {
        let suite = TestDefaultsSuite("NeverWritten")
        let path = suite.backingPlistPath

        #expect(FileManager.default.fileExists(atPath: path) == false)
        suite.tearDown()
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test("teardown is idempotent")
    func tearDownIsIdempotent() {
        let suite = TestDefaultsSuite("Idempotent")
        suite.defaults.set(1, forKey: "probe")
        suite.defaults.synchronize()

        suite.tearDown()
        suite.tearDown()

        #expect(fileExists(suite.backingPlistPath, settlingTo: false) == false)
    }

    @Test("the scoped form unlinks the backing file on the way out")
    func scopedFormUnlinksOnExit() {
        // A label unique to this run, so the lookup below cannot pick up a
        // sibling suite's file. Listing the *container* directory is fine —
        // it is small and ours; `~/Library/Preferences` itself is never walked.
        let label = "ScopedForm-\(UUID().uuidString)"
        var written: [String] = []

        withTestDefaults(label) { defaults in
            defaults.set("written", forKey: "probe")
            defaults.synchronize()
            written = Self.containerFiles(labelled: label)
            #expect(written.count == 1, "expected one backing file for \(label), saw \(written)")
        }

        #expect(written.isEmpty == false)
        for path in written {
            #expect(fileExists(path, settlingTo: false) == false, "scoped form leaked: \(path)")
        }
    }

    /// Paths inside the container directory whose name starts with `label`.
    private static func containerFiles(labelled label: String) -> [String] {
        let dir = TestDefaults.containerDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix(label + ".") }.map { "\(dir)/\($0)" }
    }

    /// Every backing file this scheme can create — including one `cfprefsd`
    /// resurrects after the process exits, which no in-process unlink can
    /// prevent — lives inside one directory. That containment is what makes
    /// the leak reclaimable at all, so it is asserted rather than assumed.
    @Test("every suite's backing file is inside the container directory")
    func backingFilesAreContained() {
        let container =
            "\(TestDefaults.realHomeDirectory)/Library/Preferences/\(TestDefaults.containerName)"
        #expect(TestDefaults.containerDirectory == container)

        for label in ["Alpha", "beta-two", "com.tbd.tests.gamma", "../escape", ""] {
            let suite = TestDefaultsSuite(label)
            defer { suite.tearDown() }

            #expect(
                suite.backingPlistPath.hasPrefix(container + "/"),
                "escaped the container: \(suite.backingPlistPath)"
            )
            // One path component inside the container — no nesting, no `..`.
            let remainder = suite.backingPlistPath.dropFirst(container.count + 1)
            #expect(remainder.contains("/") == false, "nested: \(remainder)")
            #expect(remainder.hasSuffix(".plist"))
        }
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
}

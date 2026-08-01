import Testing
@testable import TBDDaemonLib

@Suite
struct ToolPathAugmenterTests {
    // MARK: - Nil/Empty PATH

    @Test
    func augmentPathWithNilPath() {
        let result = ToolPathAugmenter.augmentPath(nil)
        #expect(result.contains("/opt/homebrew/bin"))
        #expect(result.contains("/opt/homebrew/sbin"))
        #expect(result.contains("/usr/local/bin"))
        #expect(result.contains("/usr/local/sbin"))
        // Verify no trailing colon
        #expect(!result.hasSuffix(":"))
    }

    @Test
    func augmentPathWithEmptyPath() {
        let result = ToolPathAugmenter.augmentPath("")
        #expect(result.contains("/opt/homebrew/bin"))
        #expect(result.contains("/opt/homebrew/sbin"))
        #expect(result.contains("/usr/local/bin"))
        #expect(result.contains("/usr/local/sbin"))
        // Verify no trailing colon
        #expect(!result.hasSuffix(":"))
    }

    @Test
    func augmentPathWithNilExactOutput() {
        let result = ToolPathAugmenter.augmentPath(nil)
        let expected = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
        #expect(result == expected)
    }

    @Test
    func augmentPathWithEmptyExactOutput() {
        let result = ToolPathAugmenter.augmentPath("")
        let expected = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"
        #expect(result == expected)
    }

    // MARK: - Existing PATH preservation

    @Test
    func augmentPathPreservesExistingEntries() {
        let input = "/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Both existing entries and all homebrew dirs should be present
        #expect(result.contains("/opt/homebrew/bin"))
        #expect(result.contains("/usr/bin"))
        #expect(result.contains("/bin"))
    }

    @Test
    func augmentPathMaintainsOrder() {
        let input = "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Homebrew dirs should come first, then the original entries in order
        let parts = result.split(separator: ":", omittingEmptySubsequences: true)
        #expect(parts[0] == "/opt/homebrew/bin")
        #expect(parts[1] == "/opt/homebrew/sbin")
        #expect(parts[2] == "/usr/local/bin")
        #expect(parts[3] == "/usr/local/sbin")
    }

    // MARK: - Duplicate avoidance

    @Test
    func augmentPathNoDuplicateWhenHomebrewAlreadyPresent() {
        let input = "/opt/homebrew/bin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        let parts = result.split(separator: ":")
        let homebrewBinCount = parts.filter { $0 == "/opt/homebrew/bin" }.count
        #expect(homebrewBinCount == 1)
    }

    @Test
    func augmentPathHandlesPartialDuplicates() {
        let input = "/opt/homebrew/bin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should add the other homebrew dirs but not duplicate the existing one
        #expect(result.contains("/opt/homebrew/sbin"))
        #expect(result.contains("/usr/local/bin"))
        #expect(result.contains("/usr/local/sbin"))
    }

    // MARK: - Complete Homebrew already present

    @Test
    func augmentPathWithCompleteHomebrewPath() {
        let input = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should return unchanged
        #expect(result == input)
    }

    // MARK: - Minimal launchd PATH (the main use case)

    @Test
    func augmentPathWithLaunchServicesMinimalPath() {
        let input = "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should prepend all four homebrew directories
        #expect(result.hasPrefix("/opt/homebrew/bin"))
        #expect(result.contains("/opt/homebrew/sbin"))
        #expect(result.contains("/usr/local/bin"))
        #expect(result.contains("/usr/local/sbin"))
        // And preserve the original entries
        #expect(result.contains("/usr/bin"))
        #expect(result.contains("/bin"))
    }
}

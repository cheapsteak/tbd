import XCTest
@testable import TBDDaemonLib

final class ToolPathAugmenterTests: XCTestCase {
    // MARK: - Nil/Empty PATH

    func testAugmentPathWithNilPath() {
        let result = ToolPathAugmenter.augmentPath(nil)
        XCTAssertTrue(result.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/opt/homebrew/sbin"))
        XCTAssertTrue(result.contains("/usr/local/bin"))
        XCTAssertTrue(result.contains("/usr/local/sbin"))
    }

    func testAugmentPathWithEmptyPath() {
        let result = ToolPathAugmenter.augmentPath("")
        XCTAssertTrue(result.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/opt/homebrew/sbin"))
        XCTAssertTrue(result.contains("/usr/local/bin"))
        XCTAssertTrue(result.contains("/usr/local/sbin"))
    }

    // MARK: - Existing PATH preservation

    func testAugmentPathPreservesExistingEntries() {
        let input = "/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Both existing entries and all homebrew dirs should be present
        XCTAssertTrue(result.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/usr/bin"))
        XCTAssertTrue(result.contains("/bin"))
    }

    func testAugmentPathMaintainsOrder() {
        let input = "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Homebrew dirs should come first, then the original entries in order
        let parts = result.split(separator: ":", omittingEmptySubsequences: false)
        XCTAssertEqual(parts[0], "/opt/homebrew/bin")
        XCTAssertEqual(parts[1], "/opt/homebrew/sbin")
        XCTAssertEqual(parts[2], "/usr/local/bin")
        XCTAssertEqual(parts[3], "/usr/local/sbin")
    }

    // MARK: - Duplicate avoidance

    func testAugmentPathNoDuplicateWhenHomebrewAlreadyPresent() {
        let input = "/opt/homebrew/bin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        let parts = result.split(separator: ":")
        let homebrewBinCount = parts.filter { $0 == "/opt/homebrew/bin" }.count
        XCTAssertEqual(homebrewBinCount, 1, "Should not duplicate /opt/homebrew/bin")
    }

    func testAugmentPathHandlesPartialDuplicates() {
        let input = "/opt/homebrew/bin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should add the other homebrew dirs but not duplicate the existing one
        XCTAssertTrue(result.contains("/opt/homebrew/sbin"))
        XCTAssertTrue(result.contains("/usr/local/bin"))
        XCTAssertTrue(result.contains("/usr/local/sbin"))
    }

    // MARK: - Complete Homebrew already present

    func testAugmentPathWithCompleteHomebrewPath() {
        let input = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should return unchanged
        XCTAssertEqual(result, input)
    }

    // MARK: - Minimal launchd PATH (the main use case)

    func testAugmentPathWithLaunchServicesMinimalPath() {
        let input = "/usr/bin:/bin:/usr/sbin:/sbin"
        let result = ToolPathAugmenter.augmentPath(input)
        // Should prepend all four homebrew directories
        XCTAssertTrue(result.hasPrefix("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/opt/homebrew/sbin"))
        XCTAssertTrue(result.contains("/usr/local/bin"))
        XCTAssertTrue(result.contains("/usr/local/sbin"))
        // And preserve the original entries
        XCTAssertTrue(result.contains("/usr/bin"))
        XCTAssertTrue(result.contains("/bin"))
    }
}

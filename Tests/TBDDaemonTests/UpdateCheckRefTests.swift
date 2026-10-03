import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The ref the update check compares against: `main` unless
/// `scripts/update.sh` has written a check-ref file naming the release tag
/// (`docs/specs/2026-09-23-release-pipeline-design.md`, decision 7). Pure
/// functions over an explicit environment and an injected reader, so nothing
/// here touches a real TBD home.
@Suite("Update check ref")
struct UpdateCheckRefTests {

    private static let env = ["TBD_HOME": "/scratch/tbd-home"]

    @Test func theFileLivesUnderTheTBDHome() {
        #expect(TBDConstants.updateCheckRefFile(environment: Self.env).path
            == "/scratch/tbd-home/updates/check-ref")
    }

    @Test func noFileComparesAgainstMain() {
        var asked: [String] = []
        let ref = UpdateChecker.comparedRef(environment: Self.env) { url in
            asked.append(url.path)
            return nil
        }
        #expect(ref == "refs/heads/main")
        #expect(ref == UpdateChecker.mainRef)
        #expect(asked == ["/scratch/tbd-home/updates/check-ref"])
    }

    @Test func aReleaseFileComparesAgainstTheReleaseTag() {
        let ref = UpdateChecker.comparedRef(environment: Self.env) { _ in
            "refs/tags/main-builds\n"
        }
        #expect(ref == "refs/tags/main-builds")
    }

    @Test func aBranchRefIsHonoured() {
        #expect(UpdateChecker.comparedRef(fileContents: "refs/heads/release/next")
            == "refs/heads/release/next")
    }

    @Test(arguments: [
        "",
        "   \n",
        "main-builds",
        "refs/remotes/origin/main",
        "refs/tags/",
        "refs/tags/-x",
        "refs/tags/a..b",
        "refs/tags/a b",
        "refs/tags/a;rm",
        "refs/heads//x",
    ])
    func anythingElseFallsBackToMain(contents: String) {
        #expect(UpdateChecker.comparedRef(fileContents: contents) == UpdateChecker.mainRef)
    }
}

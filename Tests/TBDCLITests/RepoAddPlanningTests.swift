import Testing
import TBDShared

@testable import TBDCLI

/// Tier 1 — pure planning over a fixed working folder and an injected
/// `pathExists`; no daemon, no filesystem, no git.
@Suite("RepoAddPlanning")
struct RepoAddPlanningTests {
    private func plan(
        _ source: String,
        destination: String? = nil,
        existing: Set<String> = []
    ) throws -> RepoAddAction {
        try planRepoAdd(
            source: source,
            destination: destination,
            currentDirectory: "/work",
            pathExists: { existing.contains($0) }
        )
    }

    @Test func localPathUnchanged() throws {
        #expect(try plan(".", existing: ["/work"]) == .addLocal(path: "/work"))
    }

    @Test func missingPathStillAddsLocally() throws {
        #expect(try plan("nope") == .addLocal(path: "/work/nope"))
    }

    @Test func shortFormClonesIntoCurrentDirectory() throws {
        #expect(
            try plan("acme/widgets")
                == .clone(
                    source: .githubShortForm(owner: "acme", repo: "widgets"),
                    destination: "/work/widgets"))
    }

    @Test func existingFolderBeatsShortForm() throws {
        #expect(
            try plan("acme/widgets", existing: ["/work/acme/widgets"])
                == .addLocal(path: "/work/acme/widgets"))
    }

    @Test func explicitDestination() throws {
        let url = "https://github.com/acme/widgets.git"
        let source = RepoSource.remote(url: url, folderName: "widgets")
        #expect(
            try plan(url, destination: "../code/w")
                == .clone(source: source, destination: "/code/w"))
        #expect(
            try plan(url, destination: "/abs/w")
                == .clone(source: source, destination: "/abs/w"))
    }

    @Test func destinationWithLocalSourceRefused() {
        let expected = RepoAddUsageError(description: "A destination is only used when cloning.")
        #expect(throws: expected) {
            try plan(".", destination: "x", existing: ["/work"])
        }
        #expect(throws: expected) {
            try plan("nope", destination: "x")
        }
    }
}

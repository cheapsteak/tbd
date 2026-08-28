import Testing
@testable import TBDApp

/// The signpost region names and category are a published interface: the
/// analysis scripts under `scripts/diag/` match on them verbatim, and the
/// capture recipes in `docs/specs/2026-08-26-terminal-latency-signposts-design.md`
/// filter on the category.
///
/// A rename would break that tooling without breaking a build, and the failure
/// would surface only as "no intervals found" partway through a future
/// investigation — at which point the natural reading is "the app must not be
/// emitting", not "someone renamed a string". These assertions make the rename
/// fail here instead.
@Suite("TerminalSignposts identifiers are stable")
struct TerminalSignpostsTests {
    @Test("subsystem and category match the documented capture recipe")
    func subsystemAndCategoryAreStable() {
        #expect(TerminalSignposts.subsystem == "com.tbd.app")
        #expect(TerminalSignposts.category == "perf-terminal")
    }

    @Test("region names match what the analysis scripts grep for")
    func regionNamesAreStable() {
        #expect("\(TerminalSignposts.Region.mainThreadHop)" == "mainThreadHop")
        #expect("\(TerminalSignposts.Region.feed)" == "feed")
    }

}

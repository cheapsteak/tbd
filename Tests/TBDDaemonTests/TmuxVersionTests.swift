import Testing
@testable import TBDDaemonLib

@Suite("TmuxVersion")
struct TmuxVersionTests {
    @Test("parses a normal release with a letter suffix")
    func parseSuffix() {
        let v = TmuxVersion.parse("tmux 3.6a\n")
        #expect(v == TmuxVersion(major: 3, minor: 6))
        #expect(v?.suffix == "a")
    }

    @Test("parses a version with no suffix")
    func parseNoSuffix() {
        #expect(TmuxVersion.parse("tmux 3.2") == TmuxVersion(major: 3, minor: 2))
    }

    @Test("parses an older two-digit-minor version")
    func parseOld() {
        #expect(TmuxVersion.parse("tmux 2.9a") == TmuxVersion(major: 2, minor: 9))
    }

    @Test("parses a next- prerelease token")
    func parseNext() {
        #expect(TmuxVersion.parse("tmux next-3.4") == TmuxVersion(major: 3, minor: 4))
    }

    @Test("returns nil for unparseable output")
    func parseGarbage() {
        #expect(TmuxVersion.parse("not a version") == nil)
        #expect(TmuxVersion.parse("") == nil)
    }

    @Test("compares by major then minor, ignoring suffix")
    func comparison() {
        #expect(TmuxVersion(major: 3, minor: 2) >= TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 3, minor: 1) < TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 2, minor: 9) < TmuxVersion.controlModeMinimum)
        #expect(TmuxVersion(major: 3, minor: 6, suffix: "a") >= TmuxVersion.controlModeMinimum)
    }
}

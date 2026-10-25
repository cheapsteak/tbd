import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("ClaudePluginDirs")
struct ClaudePluginDirsTests {
    @Test func tildeExpandsAgainstHome() throws {
        let r = try ClaudePluginDirs.validated(["~/p"], homeDirectory: "/h", fileExists: { _ in true })
        #expect(r == ["/h/p"])
    }

    @Test func relativePathRefused() {
        do {
            _ = try ClaudePluginDirs.validated(["p"], homeDirectory: "/h", fileExists: { _ in true })
            Issue.record("expected throw")
        } catch let e as ClaudePluginDirs.InvalidPath {
            #expect(e.description == "plugin folder path must be absolute or start with ~/: p")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func missingPathRefused() {
        do {
            _ = try ClaudePluginDirs.validated(["/nope"], homeDirectory: "/h", fileExists: { _ in false })
            Issue.record("expected throw")
        } catch let e as ClaudePluginDirs.InvalidPath {
            #expect(e.description == "plugin folder does not exist: /nope")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func validatedDropsDuplicates() throws {
        let r = try ClaudePluginDirs.validated(["/a", "/a"], homeDirectory: "/h", fileExists: { _ in true })
        #expect(r == ["/a"])
    }
}

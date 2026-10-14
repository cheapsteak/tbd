import Foundation
import Testing
@testable import TBDShared

@Suite("Dev server declaration model")
struct DevServerDeclarationModelTests {
    private func server(_ name: String, _ command: String, _ source: DevServerSource) -> DeclaredDevServer {
        DeclaredDevServer(name: name, command: command, source: source)
    }

    @Test(arguments: ["web", "api-2", "a", "0"])
    func validNamesAreAccepted(_ name: String) {
        #expect(DeclaredDevServer.isValidName(name))
    }

    @Test(arguments: ["", "Web", "web_app", "web app", "wéb", "web.app"])
    func invalidNamesAreRejected(_ name: String) {
        #expect(!DeclaredDevServer.isValidName(name))
    }

    /// A later source replaces the same-named server as a whole — no field
    /// survives from the earlier one — and keeps the earlier position.
    @Test func aLaterSourceReplacesAServerWholeAndKeepsItsPosition() {
        var early = server("web", "npm start", .launchJSON)
        early.env = ["A": "1"]
        early.stop = "make stop"
        let layered = DeclaredDevServer.layered([
            [early, server("api", "go run .", .launchJSON)],
            [server("web", "pnpm dev", .repoTOML)],
        ])
        #expect(layered.map(\.name) == ["web", "api"])
        #expect(layered[0].command == "pnpm dev")
        #expect(layered[0].env.isEmpty)
        #expect(layered[0].stop == nil)
        #expect(layered[0].source == .repoTOML)
    }

    @Test func serversWithOtherNamesAreKeptFromEverySource() {
        let layered = DeclaredDevServer.layered([
            [server("web", "a", .launchJSON)],
            [server("api", "b", .repoTOML)],
            [server("docs", "c", .userTOML)],
        ])
        #expect(layered.map(\.name) == ["web", "api", "docs"])
    }

    @Test func displayLabelFallsBackToTheName() {
        var s = server("web", "x", .repoTOML)
        #expect(s.displayLabel == "web")
        s.label = "Web app"
        #expect(s.displayLabel == "Web app")
    }
}

import Testing
import Foundation
@testable import TBDShared

@Test func makeOpenWorktreeURL_buildsExpectedURL() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let url = DeepLink.makeOpenWorktreeURL(id)
    #expect(url.scheme == "tbd")
    #expect(url.host == "open")
    #expect(url.absoluteString == "tbd://open?worktree=12345678-1234-1234-1234-123456789ABC")
}

@Test func makeOpenWorktreeURL_withTerminal_appendsTerminalParam() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let terminal = UUID(uuidString: "ABCDEFAB-0000-0000-0000-000000000001")!
    let url = DeepLink.makeOpenWorktreeURL(id, terminalID: terminal)
    #expect(url.absoluteString ==
        "tbd://open?worktree=12345678-1234-1234-1234-123456789ABC&terminal=ABCDEFAB-0000-0000-0000-000000000001")
}

@Test func parseOpenURL_happyPath_returnsUUID() {
    let id = UUID()
    let url = DeepLink.makeOpenWorktreeURL(id)
    let parsed = DeepLink.parseOpenURL(url)
    #expect(parsed?.worktree == id)
    #expect(parsed?.terminal == nil)
}

@Test func parseOpenURL_withTerminal_roundTrips() {
    let id = UUID()
    let terminal = UUID()
    let url = DeepLink.makeOpenWorktreeURL(id, terminalID: terminal)
    let parsed = DeepLink.parseOpenURL(url)
    #expect(parsed?.worktree == id)
    #expect(parsed?.terminal == terminal)
}

@Test func parseOpenURL_malformedTerminal_keepsWorktreeDropsTerminal() {
    let id = UUID()
    let url = URL(string: "tbd://open?worktree=\(id.uuidString)&terminal=not-a-uuid")!
    let parsed = DeepLink.parseOpenURL(url)
    #expect(parsed?.worktree == id)
    #expect(parsed?.terminal == nil)
}

@Test func parseOpenURL_rejectsWrongScheme() {
    let url = URL(string: "https://open?worktree=12345678-1234-1234-1234-123456789ABC")!
    #expect(DeepLink.parseOpenURL(url) == nil)
}

@Test func parseOpenURL_rejectsWrongHost() {
    let url = URL(string: "tbd://other?worktree=12345678-1234-1234-1234-123456789ABC")!
    #expect(DeepLink.parseOpenURL(url) == nil)
}

@Test func parseOpenURL_rejectsMissingQuery() {
    let url = URL(string: "tbd://open")!
    #expect(DeepLink.parseOpenURL(url) == nil)
}

@Test func parseOpenURL_rejectsMalformedUUID() {
    let url = URL(string: "tbd://open?worktree=not-a-uuid")!
    #expect(DeepLink.parseOpenURL(url) == nil)
}

@Test func parseOpenURL_acceptsExtraQueryItems() {
    let id = UUID()
    let url = URL(string: "tbd://open?worktree=\(id.uuidString)&future=anchor")!
    #expect(DeepLink.parseOpenURL(url)?.worktree == id)
}

@Test func makeShareableOpenURL_buildsRedirectorURL() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let url = DeepLink.makeShareableOpenURL(id)
    #expect(url.absoluteString ==
        "https://cheapsteak.github.io/tbd/open/?worktree=12345678-1234-1234-1234-123456789ABC")
}

@Test func makeShareableOpenURL_withTerminal_appendsTerminalParam() {
    let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    let terminal = UUID(uuidString: "ABCDEFAB-0000-0000-0000-000000000001")!
    let url = DeepLink.makeShareableOpenURL(id, terminalID: terminal)
    #expect(url.absoluteString ==
        "https://cheapsteak.github.io/tbd/open/?worktree=12345678-1234-1234-1234-123456789ABC&terminal=ABCDEFAB-0000-0000-0000-000000000001")
}

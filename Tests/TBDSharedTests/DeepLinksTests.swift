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

@Test func parseOpenURL_happyPath_returnsUUID() {
    let id = UUID()
    let url = DeepLink.makeOpenWorktreeURL(id)
    #expect(DeepLink.parseOpenURL(url) == id)
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
    #expect(DeepLink.parseOpenURL(url) == id)
}

import Testing
import Foundation
@testable import TBDShared

@Test func hookPathSetup() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "setup")
    #expect(path.hasSuffix("/tbd/repos/12345678-1234-1234-1234-123456789ABC/hooks/setup"))
}

@Test func hookPathArchive() {
    let repoID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let path = TBDConstants.hookPath(repoID: repoID, eventName: "archive")
    #expect(path.hasSuffix("/tbd/repos/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/hooks/archive"))
}

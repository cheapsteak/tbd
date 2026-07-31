import Testing

@testable import TBDCLI

@Suite("PathResolver")
struct PathResolverTests {
    @Test func explicitRepoOptionExplainsAcceptedValues() {
        let message = repoResolutionFailureMessage(
            path: "acme-app",
            context: .explicitRepoOption
        )

        #expect(message.contains("No registered repository at 'acme-app'."))
        #expect(message.contains("--repo takes a repository UUID or a path, not a repo name."))
        #expect(message.contains("tbd repo list"))
        #expect(!message.contains("tbd repo add"))
    }

    @Test func discoveredCurrentDirectoryExplainsHowToRegisterIt() {
        let message = repoResolutionFailureMessage(
            path: nil,
            context: .discoveredPath
        )

        #expect(message.contains("No registered repository at the current directory."))
        #expect(message.contains("tbd repo add <path>"))
        #expect(message.contains("tbd repo list"))
        #expect(!message.contains("--repo"))
    }

    @Test func discoveredPathNamesTheTargetWithoutMentioningRepoOption() {
        let message = repoResolutionFailureMessage(
            path: "/tmp/acme-app",
            context: .discoveredPath
        )

        #expect(message.contains("No registered repository at '/tmp/acme-app'."))
        #expect(message.contains("tbd repo add <path>"))
        #expect(!message.contains("--repo"))
    }
}

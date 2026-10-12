import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server declaration parsing")
struct DevServerDeclarationParserTests {
    // MARK: TOML

    @Test func aTOMLServerWithEveryFieldParses() {
        let text = """
            [servers.web]
            command = "pnpm dev"
            cwd = "apps/web"
            env = { FEATURE_X = "1" }
            label = "Web app"
            stop = "make stop"
            status = "scripts/status"
            """
        let parsed = DevServerDeclarationParser.parseTOML(text, source: .repoTOML, path: "/tmp/acme/tbd.toml")
        #expect(parsed.errors.isEmpty)
        #expect(parsed.servers == [DeclaredDevServer(
            name: "web", command: "pnpm dev", cwd: "apps/web", env: ["FEATURE_X": "1"],
            label: "Web app", stop: "make stop", status: "scripts/status", source: .repoTOML)])
    }

    @Test func unknownKeysAreIgnored() {
        let text = """
            schema = 9
            [servers.web]
            command = "pnpm dev"
            port = 3000
            dependsOn = ["api"]
            """
        let parsed = DevServerDeclarationParser.parseTOML(text, source: .repoTOML, path: "p")
        #expect(parsed.errors.isEmpty)
        #expect(parsed.servers.map(\.name) == ["web"])
    }

    @Test func aServerWithoutACommandIsReportedAndOthersAreKept() {
        let text = """
            [servers.web]
            label = "Web"
            [servers.api]
            command = "go run ."
            """
        let parsed = DevServerDeclarationParser.parseTOML(text, source: .repoTOML, path: "/tmp/acme/tbd.toml")
        #expect(parsed.servers.map(\.name) == ["api"])
        #expect(parsed.errors.count == 1)
        #expect(parsed.errors.first?.message.contains("servers.web") == true)
        #expect(parsed.errors.first?.path == "/tmp/acme/tbd.toml")
    }

    @Test func anInvalidServerNameIsReported() {
        let parsed = DevServerDeclarationParser.parseTOML(
            "[servers.Web_App]\ncommand = \"x\"\n", source: .repoTOML, path: "p")
        #expect(parsed.servers.isEmpty)
        #expect(parsed.errors.count == 1)
    }

    @Test func brokenTOMLReportsTheFileAndContributesNothing() {
        let parsed = DevServerDeclarationParser.parseTOML(
            "[servers.web\ncommand = ", source: .repoTOML, path: "/tmp/acme/tbd.toml")
        #expect(parsed.servers.isEmpty)
        #expect(parsed.errors.map(\.path) == ["/tmp/acme/tbd.toml"])
    }

    @Test(arguments: ["/etc", "../outside", "apps/../../outside"])
    func aCwdOutsideTheWorktreeIsRejected(_ cwd: String) {
        let parsed = DevServerDeclarationParser.parseTOML(
            "[servers.web]\ncommand = \"x\"\ncwd = \"\(cwd)\"\n", source: .repoTOML, path: "p")
        #expect(parsed.servers.isEmpty)
        #expect(parsed.errors.count == 1)
    }

    @Test func aNonStringEnvValueIsReportedAndDropped() {
        let parsed = DevServerDeclarationParser.parseTOML(
            "[servers.web]\ncommand = \"x\"\nenv = { A = \"1\", B = 2 }\n", source: .repoTOML, path: "p")
        #expect(parsed.servers.first?.env == ["A": "1"])
        #expect(parsed.errors.count == 1)
    }

    // MARK: launch.json

    @Test func launchJSONWithCommentsTrailingCommasAndWorkspaceFolderTranslates() throws {
        let text = """
            {
              // Claude Code preview servers
              "version": "0.2.0",
              "configurations": [
                {
                  "name": "web",
                  "runtimeExecutable": "pnpm",
                  "runtimeArgs": ["--dir", "${workspaceFolder}/apps/web", "dev"], /* inline */
                  "cwd": "${workspaceFolder}/apps/web",
                  "env": { "API_URL": "http://localhost:8004" },
                  "port": 3000,
                  "url": "http://localhost:3000",
                },
              ],
            }
            """
        let parsed = DevServerDeclarationParser.parseLaunchJSON(
            text, worktreeRoot: "/tmp/acme/fix-login", path: "/tmp/acme/fix-login/.claude/launch.json")
        #expect(parsed.errors.isEmpty)
        let server = try #require(parsed.servers.first)
        #expect(server.name == "web")
        #expect(server.command == "pnpm --dir /tmp/acme/fix-login/apps/web dev")
        #expect(server.cwd == "apps/web")
        #expect(server.env == ["API_URL": "http://localhost:8004"])
        #expect(server.source == .launchJSON)
        #expect(server.label == nil)
    }

    @Test func aProgramEntryBecomesANodeCommandWithQuotedArguments() {
        let text = #"{"configurations":[{"name":"api","program":"server.js","args":["--name","it's mine"]}]}"#
        let parsed = DevServerDeclarationParser.parseLaunchJSON(text, worktreeRoot: "/tmp/acme/w", path: "p")
        #expect(parsed.servers.first?.command == #"node server.js --name 'it'\''s mine'"#)
    }

    /// Review Focus 2: real launch.json names are display names.
    @Test func launchJSONNamesAreSlugifiedAndKeepTheirLabel() {
        let text = #"{"configurations":[{"name":"Web App","runtimeExecutable":"pnpm","runtimeArgs":["dev"]},{"name":"API (dev)","program":"a.js"}]}"#
        let parsed = DevServerDeclarationParser.parseLaunchJSON(text, worktreeRoot: "/tmp/acme/w", path: "p")
        #expect(parsed.errors.isEmpty)
        #expect(parsed.servers.map(\.name) == ["web-app", "api-dev"])
        #expect(parsed.servers.map(\.label) == ["Web App", "API (dev)"])
    }

    @Test func anEntryWithNoCommandSourceIsReported() {
        let text = #"{"configurations":[{"name":"web"}]}"#
        let parsed = DevServerDeclarationParser.parseLaunchJSON(text, worktreeRoot: "/tmp/acme/w", path: "p")
        #expect(parsed.servers.isEmpty)
        #expect(parsed.errors.count == 1)
    }

    @Test func commentMarkersInsideStringsSurvive() {
        let stripped = DevServerDeclarationParser.stripJSONComments(#"{"u": "http://x/*y*/", "v": 1, } // c"#)
        #expect(stripped.contains("http://x/*y*/"))
        #expect(!stripped.contains("// c"))
        #expect(!stripped.contains(", }"))
    }

    // MARK: Layering across files

    @Test func loadLayersSourcesAndABrokenSourceHidesNothingElse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-devdecl-\(UUID().uuidString)", isDirectory: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-devdecl-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: home)
        }
        let repoID = UUID()
        let environment = ["TBD_HOME": home.path]
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"configurations":[{"name":"api","program":"a.js"},{"name":"web","program":"w.js"}]}"#.utf8)
            .write(to: root.appendingPathComponent(".claude/launch.json"))
        try Data("[servers.web\n".utf8).write(to: root.appendingPathComponent("tbd.toml"))
        let userPath = TBDConstants.serversConfigPath(repoID: repoID, environment: environment)
        try FileManager.default.createDirectory(
            atPath: (userPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("[servers.web]\ncommand = \"pnpm dev\"\n".utf8).write(to: URL(fileURLWithPath: userPath))

        let declarations = DevServerDeclarationParser.load(
            worktreePath: root.path, repoID: repoID, environment: environment)

        #expect(declarations.servers.map(\.name) == ["api", "web"])
        #expect(declarations.servers.last?.command == "pnpm dev")
        #expect(declarations.servers.last?.source == .userTOML)
        #expect(declarations.errors.map(\.path) == [root.appendingPathComponent("tbd.toml").path])
    }

    @Test func aWorktreeWithNoSourcesDeclaresNothing() {
        let declarations = DevServerDeclarationParser.load(
            worktreePath: "/tmp/tbd-devdecl-none-\(UUID().uuidString)", repoID: nil, environment: [:])
        #expect(declarations == DevServerDeclarations(servers: [], errors: []))
    }

    @Test func resolvedCwdJoinsTheRelativePath() {
        let server = DeclaredDevServer(name: "web", command: "x", cwd: "apps/web", source: .repoTOML)
        #expect(DevServerDeclarationParser.resolvedCwd(server, worktreePath: "/tmp/acme/w") == "/tmp/acme/w/apps/web")
        let rootServer = DeclaredDevServer(name: "api", command: "x", source: .repoTOML)
        #expect(DevServerDeclarationParser.resolvedCwd(rootServer, worktreePath: "/tmp/acme/w") == "/tmp/acme/w")
    }
}

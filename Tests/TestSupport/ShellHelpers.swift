import Foundation

/// Runs a bash command in `dir` with a hermetic test environment.
///
/// The environment excludes the developer's global git config (so test repos
/// don't inherit `commit.gpgsign`, signing keys, hooks, etc.) and sets a
/// deterministic author/committer identity so commits succeed in CI where
/// `user.name`/`user.email` aren't configured.
///
/// Throws `NSError(domain: "shell")` with the command output in the
/// `NSLocalizedDescriptionKey` user info entry on non-zero exit.
public func shell(_ command: String, at dir: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        throw NSError(
            domain: "shell",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Command failed: \(command)\n\(output)"]
        )
    }
}

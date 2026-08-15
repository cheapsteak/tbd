import Foundation

/// Runs a bash command in `dir` with a hermetic test environment.
///
/// The environment excludes the developer's global git config (so test repos
/// don't inherit `commit.gpgsign`, signing keys, hooks, etc.) and sets a
/// deterministic author/committer identity so commits succeed in CI where
/// `user.name`/`user.email` aren't configured.
///
/// `HOME` is deliberately `NSHomeDirectory()` and not a literal. Under
/// `scripts/test.sh` that is **not** the developer's real home: the wrapper
/// sets `CFFIXED_USER_HOME`, which CoreFoundation resolves ahead of `getpwuid`,
/// so `NSHomeDirectory()` returns the wrapper's scratch home and the spawned
/// shell inherits the same fence the in-process code runs behind. Writing the
/// real path in here — or reading `getpwuid` — would hand every test shell the
/// developer's actual home and quietly punch through the fence. Bare `swift
/// test` still yields the real home, which is one more reason the wrapper is
/// not optional.
///
/// `TMUX_TMPDIR` is forwarded when the parent has it, and omitted when it does
/// not. Assigning `process.environment` wholesale REPLACES the inherited
/// environment, so a command in here that starts tmux would otherwise resolve
/// `-L <name>` under the shared `/tmp/tmux-<uid>` — outside the fence
/// `scripts/test.sh` set up, and permanently: tmux never unlinks a socket file
/// when its server exits, it only unlinks a stale one lazily when a new server
/// claims that same path, and every test mints a fresh name. So one dropped
/// variable is one file that stays forever. Copying the value rather than
/// hardcoding a path keeps bare `swift test` behaving exactly as before —
/// unset in, unset out — which is the same rule `HOME` follows above.
///
/// Throws `NSError(domain: "shell")` with the command output in the
/// `NSLocalizedDescriptionKey` user info entry on non-zero exit.
public func shell(_ command: String, at dir: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    var environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    if let tmuxTmpdir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] {
        environment["TMUX_TMPDIR"] = tmuxTmpdir
    }
    process.environment = environment
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

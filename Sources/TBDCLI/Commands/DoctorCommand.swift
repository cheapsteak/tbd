import ArgumentParser
import Foundation
import TBDShared

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose and repair the tbd CLI install",
        discussion: """
        Verifies that ~/.local/bin/tbd is a hard link to the TBDCLI binary
        sibling to the running daemon. Repairs a missing, stale, or legacy
        symlink install in place. Use --dry-run to inspect without writing.

        Hard links require the install path and the source binary to be on the
        same filesystem. If they aren't (e.g. your project lives on a separate
        volume from your home directory), repair will fail with a cross-device
        error and you'll need to move the project or change the install location.
        """
    )

    @Flag(name: .long, help: "Inspect only; do not modify anything")
    var dryRun = false

    mutating func run() async throws {
        let client = SocketClient()
        let status: DaemonStatusResult
        do {
            status = try client.call(
                method: RPCMethod.daemonStatus,
                resultType: DaemonStatusResult.self
            )
        } catch {
            print("error: cannot reach TBD daemon: \(error)")
            throw ExitCode(2)
        }

        guard let daemonExec = status.executablePath, !daemonExec.isEmpty else {
            print("error: daemon did not report executablePath (older daemon? run scripts/restart.sh)")
            throw ExitCode(2)
        }

        let expected = CLIInstaller.cliPath(forDaemonExecutable: daemonExec)
        let installer = CLIInstaller()
        let state = installer.currentState(expectedTarget: expected)

        print("Daemon executable:   \(daemonExec)")
        print("Expected TBDCLI:     \(expected)")
        print("Install path:        \(installer.installPath)")

        let daemonSiblingExists = FileManager.default.fileExists(atPath: expected)
        if !daemonSiblingExists {
            print("Status:              ERROR — expected TBDCLI binary does not exist at \(expected)")
            print("                     The running daemon's worktree may have been deleted.")
            print("                     Run scripts/restart.sh from a live worktree, then re-run `tbd doctor`.")
            throw ExitCode(3)
        }

        switch state {
        case .installed(let target):
            print("Status:              OK (hard link -> \(target))")
            return
        case .notInstalled:
            print("Status:              NOT INSTALLED")
        case .stale(let current):
            print("Status:              STALE (current -> \(current))")
        case .unexpectedFileType:
            // install() refuses to recursively delete a directory, and other
            // non-file entries (sockets, devices) are unsafe to clobber blind.
            // Surface a clear next step instead of letting install() throw a
            // low-level error that looks like a partial repair.
            print("Status:              UNEXPECTED FILE TYPE — a directory or other non-file occupies \(installer.installPath)")
            print("                     Remove it manually and re-run `tbd doctor`.")
            throw ExitCode(5)
        }

        if dryRun {
            print("--dry-run: would install hard link -> \(expected)")
            return
        }

        do {
            let result = try await installer.install(target: expected)
            print("Repaired: \(result.installPath) -> \(result.target)")
            if !result.onPath {
                if let rc = result.suggestedShellRC, let line = result.exportLine {
                    print("Note: \(rc.replacingOccurrences(of: "~", with: NSHomeDirectory()))'s PATH does not include \((result.installPath as NSString).deletingLastPathComponent).")
                    print("      Add to \(rc):  \(line)")
                }
            }
        } catch {
            print("error: install failed: \(error.localizedDescription)")
            throw ExitCode(4)
        }
    }
}

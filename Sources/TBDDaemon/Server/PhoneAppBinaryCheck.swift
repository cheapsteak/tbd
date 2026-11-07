import Darwin
import Foundation
import TBDShared

/// Whether a process runs one of TBD's own app binaries: the second half of
/// the phone RPCs' app-only check (`RPCRouter.handlePhoneRPC`).
///
/// The first half, `authenticatesEnvelopeSuppression`, proves only that the
/// caller is the current client of the fd sidecar socket, and the sidecar
/// adopts whichever process connects to it. So the caller's executable must
/// also be the same file, by device and inode, as one of these:
///
/// - **`TBDApp` beside the daemon** – the build output in `.build/<config>`.
/// - **`TBD.app/Contents/MacOS/TBDApp` beside the daemon** – the bundle
///   `scripts/restart.sh` and `tbd update` assemble there, whose binary is a
///   hard link of the one above. A WIP restart runs the app from it.
/// - **`/Applications/TBD.app/Contents/MacOS/TBDApp`** – the installed app.
///   `scripts/restart.sh` and `tbd update` sign that bundle and install a
///   clone of it there (`cp -c`), so it is a file of its own, not a link to
///   either of the two above.
///
/// `tbd update` moves the bundle it replaces to `~/tbd/updates/previous/`,
/// but TBD never launches the app from there, so that path is no candidate.
///
/// The rule does not depend on signing. A candidate that does not exist is
/// skipped. When none matches, or the caller's path cannot be read or
/// stat'ed, the verdict is a refusal.
///
/// The three lookups are injected, so a test states a process table and a
/// file system without touching a real process or file.
struct PhoneAppBinaryCheck: Sendable {
    /// A file, named by the device it is on and its inode, so two hard links
    /// to one file compare equal and a copy does not.
    struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    enum Verdict: Equatable, Sendable {
        case accepted
        /// The reason names itself, and the caller's path where it was read,
        /// so a refusal can be explained from its log line.
        case refused(reason: String)
    }

    /// A pid's executable path, as `proc_pidpath` reports it, or nil when it
    /// cannot be read.
    let executablePath: @Sendable (Int32) -> String?
    /// The file at a path, following symlinks, or nil when it cannot be stat'ed.
    let fileIdentity: @Sendable (String) -> FileIdentity?
    /// The paths of TBD's own app binaries, in the order they are tried.
    let appBinaryPaths: @Sendable () -> [String]

    /// Whether `pid`'s executable is one of `appBinaryPaths`, by device and inode.
    func verify(pid: Int32) -> Verdict {
        guard let path = executablePath(pid), !path.isEmpty else {
            return .refused(reason: "the caller's executable path could not be read")
        }
        guard let caller = fileIdentity(path) else {
            return .refused(reason: "the caller's executable \(path) could not be stat'ed")
        }
        var foundAny = false
        for candidate in appBinaryPaths() {
            guard let identity = fileIdentity(candidate) else { continue }
            foundAny = true
            if identity == caller { return .accepted }
        }
        if !foundAny {
            return .refused(reason: "no TBD app binary was found to compare the caller's executable \(path) with")
        }
        return .refused(reason: "the caller's executable \(path) is not one of TBD's app binaries")
    }

    // MARK: - Production

    /// The installed app's binary.
    static let installedAppBinaryPath = "/Applications/TBD.app/Contents/MacOS/TBDApp"

    /// The candidates for a daemon whose executable is `daemonExecutable`,
    /// already resolved: its sibling `TBDApp`, the sibling bundle's binary,
    /// then the installed app. Only the installed app when the daemon's own
    /// path is unknown.
    static func candidatePaths(besideDaemonAt daemonExecutable: URL?) -> [String] {
        var paths: [String] = []
        if let daemonExecutable {
            let directory = daemonExecutable.deletingLastPathComponent()
            paths.append(directory.appendingPathComponent("TBDApp").path)
            paths.append(
                directory
                    .appendingPathComponent("TBD.app", isDirectory: true)
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("MacOS", isDirectory: true)
                    .appendingPathComponent("TBDApp").path)
        }
        paths.append(installedAppBinaryPath)
        return paths
    }

    /// `stat(2)` of `path`, following symlinks.
    static func statIdentity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// The daemon's own executable, resolved once.
    ///
    /// The kernel's path for this process first: it names the file the
    /// daemon was actually launched from. `Bundle.main`'s path is the fallback,
    /// for when the kernel cannot name it, as after a rebuild unlinked the
    /// running binary. Symlinks are resolved on purpose: `tbd update` launches
    /// the daemon through `.build/release`, which can be a link into a
    /// downloaded build, and the bundle sits beside the real binary.
    private static let resolvedDaemonExecutable: URL? = {
        let path = ProcessLiveness.executablePath(pid: getpid()) ?? Bundle.main.executableURL?.path
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }()

    /// The real lookups: `proc_pidpath`, `stat(2)`, and the candidates beside
    /// this daemon's own executable.
    static let production = PhoneAppBinaryCheck(
        executablePath: { ProcessLiveness.executablePath(pid: $0) },
        fileIdentity: { PhoneAppBinaryCheck.statIdentity(atPath: $0) },
        appBinaryPaths: {
            PhoneAppBinaryCheck.candidatePaths(besideDaemonAt: PhoneAppBinaryCheck.resolvedDaemonExecutable)
        })
}

import Foundation
import os

private let launchEnvironmentLogger = Logger(subsystem: "com.tbd.app", category: "launch-environment")

/// Makes the process `PATH` match the one the bundle asked to be launched with.
///
/// `scripts/restart.sh` records the developer's `PATH` in the app bundle's
/// `Info.plist` under `LSEnvironment.PATH`. LaunchServices applies that key when
/// it launches the bundle — but not on every path into the app. A relaunch at
/// login after a reboot has been observed starting TBD with launchd's bare
/// `/usr/bin:/bin:/usr/sbin:/sbin`, and everything the app spawns, the daemon
/// included, inherits it. The daemon then runs `git` without `/opt/homebrew/bin`
/// on its `PATH`, and an LFS repo stops creating worktrees.
///
/// So the app reads the key itself and adopts it. The plist is a contract the
/// build wrote for this exact binary, not ambient state, and adopting it makes
/// the two launch routes agree.
enum LaunchEnvironment {

    /// The `PATH` to install, or `nil` when nothing needs to change.
    ///
    /// Pure, so the decision is testable without touching the real environment.
    /// Returns `nil` when the bundle names no `PATH`, and when the current
    /// `PATH` already contains every directory the bundle asked for — the
    /// ordinary terminal launch, where the inherited `PATH` is a superset and
    /// overwriting it would discard entries the plist never knew about.
    static func pathToAdopt(currentPATH: String?, bundlePATH: String?) -> String? {
        guard let bundlePATH, !bundlePATH.isEmpty else { return nil }

        let wanted = bundlePATH
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        guard !wanted.isEmpty else { return nil }

        let present = Set(
            (currentPATH ?? "")
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
        )
        return wanted.allSatisfy(present.contains) ? nil : bundlePATH
    }

    /// Reads `LSEnvironment.PATH` from the running bundle and installs it when
    /// the process `PATH` does not already cover it. Returns the adopted value,
    /// or `nil` when nothing changed.
    ///
    /// Must run before anything spawns a subprocess: `setenv` mutates `environ`,
    /// which is what `Process` hands a child when it is given no explicit
    /// environment, so a child started earlier keeps the `PATH` it was born with.
    @discardableResult
    static func adoptBundlePATHIfNeeded(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        currentPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        install: (String) -> Void = { setenv("PATH", $0, 1) }
    ) -> String? {
        let bundlePATH = (infoDictionary?["LSEnvironment"] as? [String: Any])?["PATH"] as? String
        guard let adopted = pathToAdopt(currentPATH: currentPATH, bundlePATH: bundlePATH) else {
            if bundlePATH == nil {
                launchEnvironmentLogger.info(
                    "No LSEnvironment.PATH in the bundle; keeping the launch PATH"
                )
            } else {
                launchEnvironmentLogger.info(
                    "Launch PATH already covers LSEnvironment.PATH; leaving it alone"
                )
            }
            return nil
        }
        install(adopted)
        launchEnvironmentLogger.info("""
        Adopted LSEnvironment.PATH from the bundle — the launch PATH \
        (\(currentPATH ?? "<unset>", privacy: .public)) did not cover it; \
        subprocesses now get \(adopted, privacy: .public)
        """)
        return adopted
    }
}

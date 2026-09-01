import Darwin
import Foundation

// TBDHolder — one process per holder-transport session.
//
// Invoked as:
//
//   TBDHolder --session <uuid> --socket <path> --lock-fd <n> \
//             --launch <base64-json HolderLaunchRequest> [--owner <token>]
//
// Argument parsing and exactly one call into `Holder`. Every decision the
// holder makes lives in `Holder.swift`, so it can be exercised without
// spawning a process.
//
// Diagnostics go to stderr rather than `print()` — `no_print_in_sources`
// covers this target, and the daemon reads a holder's stderr as its channel
// for anything that went wrong before the socket existed.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("TBDHolder: \(message)\n".utf8))
    exit(code)
}

// The first thing this process does, before argument parsing and before
// anything that could block. Its presence in a holder's log is what separates
// "the holder ran and then went wrong" from "the holder never got here" — a
// process killed during `exec`, a redirect that never applied, and a holder
// that simply wrote nothing are otherwise the same empty file. See
// `HolderSpawner.describeFailure`, which reads this log when a spawn fails.
holderTrace("entered main: pid \(getpid()), \(CommandLine.arguments.count - 1) arguments")

do {
    let arguments = try HolderArguments.parse(Array(CommandLine.arguments.dropFirst()))
    exit(try Holder(arguments: arguments).run())
} catch let error as HolderStartupError {
    // The code carries the one thing a spawner needs from a dead holder: could
    // retrying help? 2 says no — the command line is wrong and will stay wrong.
    // 3 says the machine refused, so a later attempt can succeed. See
    // `HolderExitCode` for which failure sits on which side.
    fail(error.localizedDescription, code: error.exitCode)
} catch {
    fail(error.localizedDescription, code: HolderExitCode.unexpected)
}

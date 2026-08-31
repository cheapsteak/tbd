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

do {
    let arguments = try HolderArguments.parse(Array(CommandLine.arguments.dropFirst()))
    exit(try Holder(arguments: arguments).run())
} catch let error as HolderStartupError {
    // 2 is "the invocation was wrong", distinct from a holder that started and
    // then failed, so a spawner can tell a bad command line from a bad machine.
    fail(error.localizedDescription, code: 2)
} catch {
    fail(error.localizedDescription, code: 1)
}

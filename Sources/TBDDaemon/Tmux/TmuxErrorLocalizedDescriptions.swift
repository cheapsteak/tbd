import Foundation

// `LocalizedError` conformance for `TmuxError`, declared in `TmuxManager.swift`.
//
// WHY IT IS HERE AND NOT ON THE DECLARATION. `localizedDescription` reads
// `LocalizedError.errorDescription` and nothing else, so without this a thrown
// `TmuxError` reaches the os.Logger error line and the user-facing alert as the
// NSError bridge string ("The operation couldn't be completed.
// (TBDDaemonLib.TmuxError error 0.)") — losing the tmux command, its exit
// status and its output, which is the entire diagnosis. Unlike `GitError`,
// `TmuxError` carries no `description` to forward to, so the rendering is
// written out here.
//
// The conformance belongs on the type declaration; it sits in this separate
// file only because `TmuxManager.swift` is owned by a concurrently-live branch
// and editing it there would collide. **When that branch lands, move
// `LocalizedError` onto `TmuxError` itself, carry this `errorDescription` over,
// and delete this file** — along with the `TmuxManager.swift` entry under the
// `error_types_must_be_localized` rule's `excluded:` list in `.swiftlint.yml`.
// This mirrors `Git/GitErrorLocalizedDescriptions.swift`, which does the same
// for the two error types in `GitManager.swift`.

extension TmuxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, output):
            return "tmux command failed (\(status)): \(command)\n\(output)"
        case .unexpectedOutput(let output):
            return "tmux command returned unexpected output: \(output)"
        case let .timedOut(command, timeout):
            return "tmux command timed out after \(timeout): \(command)"
        }
    }
}

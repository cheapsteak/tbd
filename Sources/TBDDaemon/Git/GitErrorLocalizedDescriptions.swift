import Foundation

// `LocalizedError` conformances for the two error types declared in
// `GitManager.swift`.
//
// WHY THEY ARE HERE AND NOT ON THE DECLARATIONS. `localizedDescription` reads
// `LocalizedError.errorDescription` and nothing else — a `CustomStringConvertible`
// `description` is not consulted — so without these, a thrown `GitError` reaches
// the os.Logger error line and the user-facing alert as the NSError bridge
// string ("The operation couldn't be completed. (TBDDaemonLib.GitError error
// 1.)"), losing the command, the exit code and git's own stderr. Both types
// already render all of that in `description`, so the fix is to forward.
//
// The conformance belongs on the type declaration; it sits in this separate file
// only because `GitManager.swift` is owned by a concurrently-live branch and
// editing it there would collide. **When that branch lands, move
// `LocalizedError` onto `GitTimeoutError` and `GitError` themselves, keep the
// same one-line `errorDescription`, and delete this file** — along with the
// `GitManager.swift` entry under the `error_types_must_be_localized` rule's
// `excluded:` list in `.swiftlint.yml`, which is why that rule stays silent on
// those two declarations today and does not fight this file.

extension GitTimeoutError: LocalizedError {
    public var errorDescription: String? { description }
}

extension GitError: LocalizedError {
    public var errorDescription: String? { description }
}

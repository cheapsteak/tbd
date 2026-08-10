import Foundation
import TBDShared

/// One worktree's outcome from a `pr.bindings` fetch.
///
/// The daemon error is carried as a `String` rather than an `any Error` because
/// `Error` is not `Sendable` and this value crosses back to the main actor.
struct PRBindingFetchOutcome: Sendable {
    let worktreeID: UUID
    /// `nil` means the fetch FAILED. A non-nil result with an empty `bindings`
    /// array is the daemon answering "this worktree has none", which is a real
    /// answer and must not be confused with the failure.
    let result: PRBindingsResult?
    let failure: String?

    init(worktreeID: UUID, result: PRBindingsResult?, failure: String? = nil) {
        self.worktreeID = worktreeID
        self.result = result
        self.failure = failure
    }
}

/// Folding a round of per-worktree `pr.bindings` fetches into the app's published
/// state — pulled out of `AppState.refreshPRBindings` as a pure value transform
/// so the two-branch contract below can be asserted without a daemon.
///
/// Two per-worktree outcomes stay distinct, deliberately:
///
/// - a FAILED fetch keeps the previous value. An RPC hiccup is not evidence that
///   a worktree lost its PRs, and blanking the toolbar on one is a visible flap.
/// - an EMPTY result DOES drop the key. Everything-detached, or nothing ever
///   bound, is a real answer and the surfaces must follow it.
enum PRBindingRefresh {

    /// The published state this fold produces. `detachedCounts` is tracked
    /// alongside `bindings` rather than inside it because it survives the very
    /// case that empties `bindings`: a worktree whose last PR was detached has
    /// no live bindings and a non-zero count, and that count is the only thing
    /// keeping the legacy-status fallback from resurrecting the detached PR.
    struct State: Equatable {
        var bindings: [UUID: [PRBinding]] = [:]
        var detachedCounts: [UUID: Int] = [:]
    }

    /// Applies `outcomes` on top of `previous`. Worktrees absent from `outcomes`
    /// are untouched.
    static func merge(_ previous: State, applying outcomes: [PRBindingFetchOutcome]) -> State {
        var merged = previous
        for outcome in outcomes {
            guard let result = outcome.result else { continue }
            if result.bindings.isEmpty {
                merged.bindings.removeValue(forKey: outcome.worktreeID)
            } else {
                merged.bindings[outcome.worktreeID] = result.bindings
            }
            // A zero count is stored as absence, so the dictionary stays the
            // set of worktrees with tombstones rather than growing one entry per
            // worktree ever polled.
            let detached = result.detachedCount ?? 0
            if detached == 0 {
                merged.detachedCounts.removeValue(forKey: outcome.worktreeID)
            } else {
                merged.detachedCounts[outcome.worktreeID] = detached
            }
        }
        return merged
    }
}

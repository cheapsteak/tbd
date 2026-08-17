import Combine
import Foundation
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process state only. No sleeps, no subprocesses,
// no `~/tbd`.

// MARK: - The instrument

/// Counts `objectWillChange` emissions from `state` across `body`.
///
/// `AppState` is an `ObservableObject`, so `objectWillChange` is **object-wide**:
/// one emission re-runs the body of every view observing the object, regardless
/// of which of its ~107 `@Published` properties changed. Readership is therefore
/// irrelevant to invalidation — only *writer frequency* is. This helper turns
/// that frequency into a number a test can assert on.
///
/// The subtlety it exists to expose: `@Published` fires on **assignment**, not on
/// change. A guard inside a property's `didSet` suppresses the downstream work
/// but NOT the SwiftUI invalidation, because `objectWillChange` has already been
/// sent by `willSet` before `didSet` ever runs. To spare a render pass, the
/// equality guard has to sit at the *assignment site*.
///
/// The cancellable is held for exactly the closure's duration and cancelled on
/// the way out, so a later emission from an unrelated test can't be attributed
/// to this one.
@MainActor
func countEmissions(of state: AppState, during body: () -> Void) -> Int {
    var count = 0
    let token = state.objectWillChange.sink { _ in count += 1 }
    defer { token.cancel() }
    body()
    return count
}

/// `async` twin of ``countEmissions(of:during:)``, for driving a production path
/// that suspends. Same contract: the subscription is live for the whole
/// operation, including across every suspension point inside it.
///
/// Deliberately a separate argument label rather than an overload. A trailing
/// closure that happens to be synchronous binds to whichever overload the
/// compiler prefers, and picking the sync one for an `async` body would silently
/// stop counting at the first `await` — a miscount that looks exactly like a
/// well-behaved property.
@MainActor
func countEmissions(of state: AppState, duringAsync body: () async -> Void) async -> Int {
    var count = 0
    let token = state.objectWillChange.sink { _ in count += 1 }
    defer { token.cancel() }
    await body()
    return count
}

// MARK: - Fixtures

/// `AppState` against a throwaway `UserDefaults` suite. `UserDefaults.standard`
/// on this unbundled executable is the developer's real `TBDApp.plist` — see
/// the root `CLAUDE.md`. Mirrors `AppStateDerivedCacheTests.withState`.
@MainActor
func withEmissionState(_ body: (AppState) -> Void) {
    let suiteName = "TBDAppTests.AppStateEmissions.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(AppState(userDefaults: defaults))
}

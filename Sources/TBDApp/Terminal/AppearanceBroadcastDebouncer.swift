import Combine
import Foundation

/// Trailing-edge debounce for appearance changes, built on the injectable clock
/// seam instead of a Combine scheduler.
///
/// Why this type exists at all: the pipeline it owns used to be an inline
/// `.dropFirst().removeDuplicates().debounce(for:scheduler: DispatchQueue.main)`
/// chain inside `AppState.setupAppearanceSubscriptions`. Combine's `.debounce`
/// takes a `Scheduler`, and `Scheduler` and `any Clock<Duration>` are unrelated
/// protocols — there is no way to thread the project's clock seam
/// (`docs/specs/2026-07-24-test-hardening-design.md` §5) through that operator.
/// So the only test that covered the debounce contract *reconstructed* the
/// chain in its own body and asserted against a copy: the production wiring had
/// zero coverage, and the test waited on a real 200 ms timer against a wall
/// clock, which made it load-sensitive and flaky.
///
/// The split here follows that constraint: the *pure* stages stay in Combine
/// (`dropFirst`/`removeDuplicates` involve no time and are worth nobody's
/// hand-rolled reimplementation), and only the time-dependent stage becomes
/// cancel-and-replace on `clock.sleep(for:)` — the same shape as
/// `AppState.scheduleMainAreaSizeBroadcast` and `NotePaneView.debounceSave`,
/// but with the delay injectable so a `TestClock` can drive it in virtual time.
@MainActor
final class AppearanceBroadcastDebouncer {
    private let interval: Duration
    private let clock: any Clock<Duration>
    private var pending: Task<Void, Never>?

    /// - Parameter interval: quiet window before a change is broadcast. 200 ms
    ///   is long enough to swallow a scheme-picker scrub, short enough to feel
    ///   immediate.
    /// - Parameter clock: last parameter, existential, defaulted — the shared
    ///   seam contract. Existential rather than generic so this type doesn't
    ///   have to become generic at every storage site.
    init(interval: Duration = .milliseconds(200),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.interval = interval
        self.clock = clock
    }

    /// Wires `appearance.$schemeID` up and returns the subscription for the
    /// caller to store.
    ///
    /// Releasing that subscription stops *new* values, but — unlike the Combine
    /// `.debounce` this replaces, where the pending trailing emission died with
    /// the chain — an already-armed fire is owned by this object, not by the
    /// cancellable, and still lands. Call `cancel()` to drop it. `AppState` does
    /// exactly that before re-subscribing.
    ///
    /// `onQuiet` fires once per quiet window with the most recent value.
    /// `dropFirst()` matters: `@Published` replays the current value at
    /// subscription time, and without it the very first broadcast would run at
    /// app launch before the daemon connection exists — an RPC that fails and
    /// gets swallowed.
    func start(observing appearance: AppearanceSettings,
               onQuiet: @escaping @MainActor (String) -> Void) -> AnyCancellable {
        appearance.$schemeID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in
                self?.schedule(value, onQuiet: onQuiet)
            }
    }

    /// Cancels a pending fire, if any. Idempotent.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Trailing edge: every new value restarts the window, so a burst collapses
    /// to one call with the last value.
    private func schedule(_ value: String, onQuiet: @escaping @MainActor (String) -> Void) {
        pending?.cancel()
        pending = Task { @MainActor [clock, interval] in
            // Cancellation while still asleep surfaces as a thrown error — the
            // "a newer value superseded me" path.
            guard (try? await clock.sleep(for: interval)) != nil else { return }
            // Both checks are load-bearing; the throw alone is not enough.
            // Cancellation that arrives *after* the sleep has already resumed
            // cannot retroactively make that `await` throw. The window is real
            // and reachable: the timer resumption is enqueued on the MainActor,
            // and if the MainActor is mid-turn in something that sets
            // `schemeID` (a picker drag, a SwiftUI pass), `schedule` runs first
            // and cancels us — then our resumption executes anyway and
            // broadcasts a superseded scheme, to be corrected 200ms later.
            // Combine's `.debounce` could not do that, so omitting this would
            // be a real behaviour change, not a tidiness nit.
            guard !Task.isCancelled else { return }
            onQuiet(value)
        }
    }
}

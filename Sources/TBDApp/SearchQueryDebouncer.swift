import Foundation

/// Trailing-edge debounce for a typed search query, so a burst of keystrokes
/// costs one RPC instead of one per character.
///
/// Same shape and same contract as `AppearanceBroadcastDebouncer` (see that
/// file for the long-form rationale): cancel-and-replace a `Task` over
/// `clock.sleep(for:)`, with the clock injected as the last, defaulted,
/// **existential** parameter. Combine's `.debounce` is not an option — it takes
/// a `Scheduler`, which can never be an `any Clock<Duration>`, so the project's
/// clock seam (`docs/specs/2026-07-24-test-hardening-design.md` §5) cannot be
/// threaded through it and the timing would only be testable against a wall
/// clock.
///
/// Unlike `AppearanceBroadcastDebouncer` this one takes values directly rather
/// than subscribing to a publisher: its input is SwiftUI `@State` text driven
/// by `.onChange`, not a `@Published` property.
@MainActor
final class SearchQueryDebouncer {
    private let interval: Duration
    private let clock: any Clock<Duration>
    private var pending: Task<Void, Never>?

    /// - Parameter interval: quiet window before the query is acted on. 250 ms
    ///   is long enough to swallow ordinary typing, short enough that results
    ///   feel like they follow the keystroke.
    /// - Parameter clock: last parameter, existential, defaulted — the shared
    ///   seam contract. Existential rather than generic so this type doesn't
    ///   have to become generic at every storage site.
    init(interval: Duration = .milliseconds(250),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.interval = interval
        self.clock = clock
    }

    /// Cancels a pending fire, if any. Idempotent.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// Trailing edge: every new value restarts the window, so a burst collapses
    /// to one call with the last value.
    func schedule(_ value: String, onQuiet: @escaping @MainActor (String) -> Void) {
        pending?.cancel()
        pending = Task { @MainActor [clock, interval] in
            // Cancellation while still asleep surfaces as a thrown error — the
            // "a newer keystroke superseded me" path.
            guard (try? await clock.sleep(for: interval)) != nil else { return }
            // Both checks are load-bearing; the throw alone is not enough.
            // Cancellation that arrives *after* the sleep has already resumed
            // cannot retroactively make that `await` throw. The window is real:
            // the timer resumption is enqueued on the MainActor, and if the
            // MainActor is mid-turn in something that types another character
            // (or clears the field), `schedule`/`cancel` runs first — then our
            // resumption executes anyway and fires a superseded query.
            guard !Task.isCancelled else { return }
            onQuiet(value)
        }
    }
}

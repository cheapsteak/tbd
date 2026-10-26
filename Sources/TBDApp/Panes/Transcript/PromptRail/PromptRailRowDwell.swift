import Foundation

/// When a prompt rail card row expands: `delay` after the pointer comes to
/// rest on it. The card tells it which row the pointer rests on, counting
/// only rows that show part of their prompt, and shows and hides the
/// expansion on `onExpandedRowChange`.
///
/// - **Resting** – a new row hides the expansion at once and arms a fresh
///   delay, so the next row waits its own `delay`; the same row again changes
///   nothing, so moving within a row neither hides nor restarts it.
/// - **Cancelling** – hides at once and forgets the row: the list scrolled,
///   its rows changed, or the card closed. Resting on the same row afterwards
///   arms a fresh delay.
///
/// The timer sleeps on the injected `clock` and is cancel-and-replace, so a
/// test drives it in virtual time.
@MainActor
final class PromptRailRowDwell {
    /// The row the pointer rests on, armed or expanded; nil for none.
    private(set) var restingRow: Int?
    /// The row whose expansion shows; nil for none.
    private(set) var expandedRow: Int?

    /// Called on every change of `expandedRow`, and only on a change.
    var onExpandedRowChange: (@MainActor (Int?) -> Void)?

    private var task: Task<Void, Never>?
    /// Lets a task that resumes after a newer one was armed see that it is
    /// stale, so it neither expands nor clears the newer task.
    private var generation = 0

    private let delay: Duration
    private let clock: any Clock<Duration>

    init(delay: Duration = PromptRailCardMetrics.expansionDelay, clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        self.clock = clock
    }

    /// The pointer now rests on `row`; nil when it rests on no row that can
    /// expand.
    func rest(on row: Int?) {
        guard row != restingRow else { return }
        cancel()
        restingRow = row
        if let row { schedule(row) }
    }

    /// Hide at once and forget the row.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        restingRow = nil
        setExpanded(nil)
    }

    private func setExpanded(_ row: Int?) {
        guard expandedRow != row else { return }
        expandedRow = row
        onExpandedRowChange?(row)
    }

    private func schedule(_ row: Int) {
        generation += 1
        let armed = generation
        let clock = self.clock
        let delay = self.delay
        task = Task { [weak self] in
            try? await clock.sleep(for: delay)
            guard let self, self.generation == armed else { return }
            self.task = nil
            guard !Task.isCancelled, self.restingRow == row else { return }
            self.setExpanded(row)
        }
    }

    // MARK: - Testing

    /// Await the armed timer, so a test asserts on the state it left rather
    /// than racing it.
    func _drainForTesting() async {
        await task?.value
    }
}

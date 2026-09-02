// Deterministic reproduction of the `Process.waitUntilExit()` hang that
// `Tests/TBDDaemonLiveTests/Process/BoundedProcessTeardown.swift` is the
// standing defence against.
//
// WHAT IT DEMONSTRATES
//   `Process.run()` appends the task's pointer to a PER-THREAD CFArray (CF
//   thread-specific-data slot 30), created with NULL callbacks and never pruned
//   when a task is freed — so the list accumulates dangling pointers of dead
//   tasks. `waitUntilExit()` reads "my pointer is in THIS thread's list" as
//   "this thread launched me", and in that case keeps running the run loop until
//   a termination block has run — a block the exit handler queues onto the
//   LAUNCHING thread's run loop. Plant one stale entry and the two facts
//   disagree: the wait runs on a thread the block will never reach, and it spins
//   forever at 0% CPU with `isRunning` already false.
//
//   The probe plants that entry by hand instead of waiting for the allocator to
//   hand a dead task's address to a live one, which is what happens on its own
//   in a test process that churns hundreds of short-lived `Process` objects on
//   long-lived cooperative-pool threads (every `ps` call is one). A standalone
//   loop hit it unaided at iteration 13 of 300.
//
// HOW TO RUN
//   xcrun swiftc -O -o "$TMPDIR/stale" scripts/diag/nstask-waituntilexit-stale-entry.swift
//   "$TMPDIR/stale"
//
//   Pass --termination-handler to re-run with a `terminationHandler` set on the
//   task: that path is immune, because the handler forces the exit
//   notification down a route the waiting thread can observe.
//
// EXIT CODES
//   0  waitUntilExit returned on the thread with the stale entry (no hang)
//   1  the hang reproduced — waitUntilExit did not return within 3 seconds
//   2  the probe could not set itself up, or a premise did not hold. Every
//      case: `_CFGetTSD` could not be resolved; thread A has no per-thread task
//      list; a finished `Process` was not deallocated, so no stale entry can
//      arise at all; the task under test never started; it never exited, so
//      there is no completed exit for the wait to observe; the plant job did not
//      finish within its bound; or the control arm hung, which would leave a
//      step-5 hang unattributable.
//
// `_CFGetTSD` is private CoreFoundation API. It is used here only to READ and
// APPEND TO the per-thread list that Foundation itself creates and populates —
// the probe plants the state, it does not invent a mechanism. Nothing in
// `Sources/` calls it; this file is a diagnostic and is not linked into any
// product.
//
// Verified on macOS 26.1 (25B78).

import Darwin
import Foundation

/// A thread with a job queue, so the probe can say exactly which thread runs
/// which call. `Thread` rather than a `DispatchQueue` because the identity of
/// the OS thread is the whole subject.
final class Worker: @unchecked Sendable {
    private let lock = NSCondition()
    private var jobs: [() -> Void] = []

    init(_ name: String) {
        let thread = Thread { [self] in
            while true {
                lock.lock()
                while jobs.isEmpty { lock.wait() }
                let job = jobs.removeFirst()
                lock.unlock()
                autoreleasepool { job() }
            }
        }
        thread.name = name
        thread.start()
    }

    /// Runs `job` on this worker and waits, bounded, for it to finish. Returns
    /// false when the bound fires — which for this probe IS the finding.
    @discardableResult
    func run(timeout: Double = 3, _ job: @escaping () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        jobs.append {
            job()
            done.signal()
        }
        lock.signal()
        lock.unlock()
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// Holds a weak reference across the `autoreleasepool` boundary without needing
/// a weak global.
final class WeakProcessBox {
    weak var value: Process?
}

func make(_ path: String, _ args: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return process
}

@discardableResult
func launch(_ process: Process) -> Bool {
    do {
        try process.run()
        return true
    } catch {
        return false
    }
}

/// Step 0 — is a finished `Process` deallocated at all? It is, and that is what
/// makes the per-thread list unsound: the list keeps the raw pointer, the object
/// behind it goes away, and the next task allocated at that address inherits an
/// entry it never earned.
func finishedProcessIsDeallocated(on worker: Worker) -> Bool {
    let box = WeakProcessBox()
    let ran = worker.run(timeout: 10) {
        var task: Process? = make("/usr/bin/true", [])
        if let task, launch(task) {
            // Same-thread launch and wait: this shape is not exposed to the
            // defect, and the probe relies on that to get itself set up.
            task.waitUntilExit()
        }
        box.value = task
        task = nil
    }
    // A job that never ran is not a satisfied premise, so it must not read as
    // one.
    guard ran else { return false }
    // Bounded poll rather than one fixed sleep: a slow autorelease drain would
    // otherwise read as a failed premise. Monotonic, like the deadlines in
    // `BoundedProcessTeardown`, so a wall-clock step cannot stretch or shorten
    // the bound.
    let clock = ContinuousClock()
    let drainDeadline = clock.now.advanced(by: .seconds(2))
    while box.value != nil && clock.now < drainDeadline { usleep(10_000) }
    return box.value == nil
}

typealias GetTSD = @convention(c) (UInt32) -> UnsafeMutableRawPointer?

guard let getTSDSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CFGetTSD") else {
    print("could not resolve _CFGetTSD; this probe needs it to read the per-thread task list")
    exit(2)
}
let getTSD = unsafeBitCast(getTSDSymbol, to: GetTSD.self)

/// The slot Foundation stores the per-thread `NSTask` list in.
let taskListSlot: UInt32 = 30

let useHandler = CommandLine.arguments.contains("--termination-handler")
let threadA = Worker("A")
let threadB = Worker("B")
let threadC = Worker("C")

let deallocated = finishedProcessIsDeallocated(on: threadA)
print("finished Process deallocated: \(deallocated)")
// Enforced, not merely reported: if a finished task is never freed, its entry in
// the per-thread list stays valid and the reuse this probe plants cannot happen.
guard deallocated else {
    print("premise failed: a finished Process was not deallocated, so a stale entry cannot arise")
    exit(2)
}

// 1. Thread A has now launched a task, so its per-thread list exists.
let listRead = threadA.run {
    guard let raw = getTSD(taskListSlot) else {
        print("thread A has no task list after one launch")
        return
    }
    let list = Unmanaged<CFMutableArray>.fromOpaque(raw).takeUnretainedValue()
    print("thread A task-list count after one launch: \(CFArrayGetCount(list))")
}
guard listRead else {
    print("thread A did not finish reading its task list within its bound")
    exit(2)
}

// 2. Thread B launches the task under test; a third party kills it. The loop is
//    counted, not `while :`, so a probe that is itself killed leaves nothing
//    spinning for longer than five minutes.
let task = make(
    "/bin/zsh", ["-f", "-c", #"trap "" HUP; for _ in {1..1500}; do sleep 0.2; done"#])
if useHandler { task.terminationHandler = { _ in } }
let launchedOnB = threadB.run(timeout: 10, { _ = launch(task) })
guard launchedOnB else {
    print("thread B did not launch the task under test in time")
    exit(2)
}
let pid = task.processIdentifier
guard pid > 0 else {
    print("the task under test never started")
    exit(2)
}
kill(pid, SIGTERM)

let exitClock = ContinuousClock()
let exitDeadline = exitClock.now.advanced(by: .seconds(10))
while task.isRunning && exitClock.now < exitDeadline { usleep(5_000) }
print("pid \(pid) isRunning=\(task.isRunning) kill(pid, 0)=\(kill(pid, 0))")
// A child still running is not the hang under test: without this, exit code 1
// would report "hang reproduced" for a wait that is simply waiting.
guard !task.isRunning else {
    print("the task under test did not exit within 10 s; cannot test the wait")
    exit(2)
}

// 3. Plant the stale entry: thread A's list gets this task's pointer, exactly as
//    it would have after a task A launched was freed and its address reused.
var planted = false
let plantFinished = threadA.run {
    guard let raw = getTSD(taskListSlot) else { return }
    let list = Unmanaged<CFMutableArray>.fromOpaque(raw).takeUnretainedValue()
    CFArrayAppendValue(list, Unmanaged.passUnretained(task).toOpaque())
    planted = true
}
// Two distinct failures, two distinct messages: a worker that never got to the
// job at all, and a worker that ran it and found no list to plant into.
guard plantFinished else {
    print("thread A did not finish planting the entry within its bound")
    exit(2)
}
guard planted else {
    print("thread A has no per-thread task list to plant into")
    exit(2)
}

// 4. Control: thread C has no entry for this task, so it takes the ordinary
//    path and returns at once. Without this arm, a hang in step 5 could be
//    blamed on the task rather than on the thread the wait ran on.
let controlReturned = threadC.run { task.waitUntilExit() }
print("waitUntilExit on thread C (no entry): \(controlReturned ? "returned" : "HUNG")")
guard controlReturned else {
    print(
        """
        control failed: waitUntilExit did not return on a thread with no entry, so a hang in \
        step 5 could not be attributed to the stale entry
        """)
    exit(2)
}

// 5. The hazard: thread A's stale entry says "launched here", but the
//    notification block went to thread B's run loop and will never run here.
let hazardReturned = threadA.run(timeout: 3) { task.waitUntilExit() }
print("waitUntilExit on thread A (stale entry): \(hazardReturned ? "returned" : "HUNG for 3s")")
print("isRunning at the end: \(task.isRunning)")
exit(hazardReturned ? 0 : 1)

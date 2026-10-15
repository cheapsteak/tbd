import Foundation
import TBDShared

/// What a holder session's headless emulator needs to take part in the
/// Program Status Protocol (OSC 7501): the gate that decides whether it
/// answers the `?` probe at all, and where a report's raw payload goes.
///
/// Its own file, and a whole-module `import TBDShared`, because
/// `HolderReader.swift` imports `TBDShared` only by scoped declarations — there
/// `Terminal` must mean SwiftTerm's emulator, not the DB row — and the gate's
/// type is reached there only through this struct's property.
///
/// `deliver` runs **inside a parse, under the emulator's `terminalLock`**, on
/// the drain thread. It must not block and must not call back into the
/// emulator; the registry's tap hands the bytes to `ProgramStatusStore.enqueue`,
/// which only yields to an `AsyncStream`.
///
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md ("Answering
/// the probe", "Delivering reports to the daemon").
struct HolderProgramStatusTap: Sendable {
    let gate: ProgramStatusGate
    /// The raw OSC data after `7501;`, already copied out of SwiftTerm's
    /// borrowed slice.
    let deliver: @Sendable ([UInt8]) -> Void
}

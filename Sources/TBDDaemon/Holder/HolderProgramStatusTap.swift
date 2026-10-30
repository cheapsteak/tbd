import Foundation

/// What a holder session's headless emulator needs to take part in the
/// Program Status Protocol (OSC 7501): where a report's raw payload goes. A
/// reader built with a tap answers the `?` probe and delivers reports; one
/// built without leaves OSC 7501 unhandled.
///
/// `deliver` runs **inside a parse, under the emulator's `terminalLock`**, on
/// the drain thread. It must not block and must not call back into the
/// emulator; the registry's tap hands the bytes to `ProgramStatusStore.enqueue`,
/// which only yields to an `AsyncStream`.
///
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md ("Answering
/// the probe", "Delivering reports to the daemon").
struct HolderProgramStatusTap: Sendable {
    /// The raw OSC data after `7501;`, already copied out of SwiftTerm's
    /// borrowed slice.
    let deliver: @Sendable ([UInt8]) -> Void
}

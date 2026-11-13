import Foundation

/// What a holder session's headless emulator needs to take part in the
/// Program Status Protocol (OSC 7501): where a report's raw payload goes. A
/// reader built with a tap answers the `?` probe and delivers reports; one
/// built without leaves OSC 7501 unhandled.
///
/// `deliver` runs before the feed that carried the report returns. The
/// SwiftTerm emulator calls it **inside the parse, under its `terminalLock`**,
/// on the drain thread. The libghostty emulator calls it after the parse, once
/// the terminal's lock has dropped, on whichever thread is delivering that
/// terminal's effects at the moment: the feeding thread, unless another call's
/// delivery is already running, and every other call that produced a delivery
/// waits for it. Either way it must not block and must not call back into the
/// emulator; the registry's tap hands the bytes to
/// `ProgramStatusStore.enqueue`, which only yields to an `AsyncStream`.
///
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md ("Answering
/// the probe", "Delivering reports to the daemon").
struct HolderProgramStatusTap: Sendable {
    /// The raw OSC data after `7501;`: copied out of SwiftTerm's borrowed
    /// slice, or rebuilt from libghostty's parsed report by
    /// `ProgramStatusPayloadBuilder`.
    let deliver: @Sendable ([UInt8]) -> Void
}

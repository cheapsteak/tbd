/// The DA1, DA2 and XTVERSION answers TBD's terminals give, whichever engine draws them: the
/// bytes SwiftTerm answers with at the fork revision TBD pins.
///
/// Frozen, not read from a terminal at run time. A program that keys features off the
/// terminal's name could change behaviour if the answer changed, so TBD keeps answering as it
/// always has, through an engine change and after SwiftTerm is gone. The answer must not
/// disappear either: Claude Code turns on synchronized output (DEC 2026) only when XTVERSION is
/// answered.
///
/// While SwiftTerm is still linked, a test holds these bytes to
/// `SwiftTermDeviceIdentity.rawAnswers()`, SwiftTerm's own answers, byte for byte. Stream D of
/// the SwiftTerm retirement deletes `rawAnswers()` and keeps these constants. Design:
/// `docs/specs/2026-11-13-swiftterm-retirement-design.md`, "Device identity".
package enum TerminalDeviceIdentity {
    /// The reply to DA1 (`CSI c`): a VT525 (65) with sixel (4), 132 columns (1), a printer (2),
    /// selective erase (6), horizontal scrolling (21), ANSI colour (22), terminal state
    /// interrogation (17) and rectangular editing (28).
    package static let da1Reply: [UInt8] = Array("\u{1b}[?65;4;1;2;6;21;22;17;28c".utf8)

    /// The reply to DA2 (`CSI > c`): a VT525 (65), firmware version 20, a PC-style keyboard (1).
    package static let da2Reply: [UInt8] = Array("\u{1b}[>65;20;1c".utf8)

    /// The reply to XTVERSION (`CSI > 0 q`): the DCS string SwiftTerm writes, naming itself and
    /// the first twelve characters of the pinned commit.
    package static let xtversionReply: [UInt8] = Array("\u{1b}P>|SwiftTerm+b4db5b0ecd62:\u{1b}\\".utf8)

    /// DA1 and DA2 as libghostty takes them. A libghostty terminal given these answers with
    /// `da1Reply` and `da2Reply`.
    package static let deviceAttributes = GhosttyTerminalCallbacks.DeviceAttributes(
        conformanceLevel: 65,
        features: [4, 1, 2, 6, 21, 22, 17, 28],
        deviceType: 65,
        firmwareVersion: 20,
        romCartridge: 1,
        unitID: 0)

    /// XTVERSION as libghostty takes it: the text between `DCS > |` and the string terminator.
    /// A libghostty terminal given this answers with `xtversionReply`.
    package static let xtversion = "SwiftTerm+b4db5b0ecd62:"
}

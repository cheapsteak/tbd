import Foundation

/// Encodes app keystroke/paste bytes into `send-keys -H` command strings for
/// the FIFO correlator (addendum §2, "Daemon → tmux encoding").
///
/// Why `-H` for *every* byte (not tmux's literal/hex/`-H` three-way split):
/// tmux ≥ 3.5 (iTerm2 issue 12845) silently rewrites bare hex-token control
/// bytes to the literal text `"0xNN"` once a pane enables modifyOtherKeys —
/// which Claude Code's fullscreen renderer does. `-H` (tmux ≥ 3.0a; our floor
/// is 3.2) round-trips every byte 0x00–0xFF regardless of pane mode, so it is
/// both simpler and correct at our floor.
///
/// Each byte becomes one bare lowercase two-digit hex token
/// (`send-keys -H -t %N 68 65 6c 6c 6f`), space-separated. Control bytes ride
/// through as ordinary tokens (`03` = Ctrl-C, verified against live tmux).
enum SendKeysEncoder {
    /// Emit `send-keys -H` commands for `bytes`, chunked so no single command
    /// line approaches tmux's historical ~1024-byte crash threshold: at
    /// `maxBytesPerCommand` = 330, a command is ≈ 1011 chars (3 chars/byte).
    ///
    /// Empty `bytes` → `[]`. A blank command is NEVER emitted — the FIFO
    /// correlator rejects blank/newline command text with `.invalidCommand`.
    static func commands(paneID: String, bytes: Data, maxBytesPerCommand: Int = 330) -> [String] {
        precondition(maxBytesPerCommand >= 1, "maxBytesPerCommand must be positive")
        guard !bytes.isEmpty else { return [] }

        let allBytes = [UInt8](bytes)
        var commands: [String] = []
        var index = 0
        while index < allBytes.count {
            let end = min(index + maxBytesPerCommand, allBytes.count)
            let tokens = allBytes[index..<end].map { String(format: "%02x", $0) }.joined(separator: " ")
            commands.append("send-keys -H -t \(paneID) \(tokens)")
            index = end
        }
        return commands
    }
}

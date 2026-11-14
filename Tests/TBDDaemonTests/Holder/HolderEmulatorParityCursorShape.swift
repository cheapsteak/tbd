// The one viewer reading the emulator parity suite makes through libghostty's C API: the cursor's
// shape, which libghostty gives only to a render state. Kept apart because importing GhosttyVt
// makes a bare `GhosttyTerminal` name the C handle.
import GhosttyVt
import TBDGhosttyCore

extension EmulatorParity {
    /// The cursor's shape as a renderer would draw it, which DECSCUSR sets: a render state is
    /// updated from the viewer for this one read. Neither snapshot writer writes DECSCUSR, so a
    /// shape the program chose reaches neither viewer. Caller holds the viewer's lock.
    static func cursorShape(_ state: TBDGhosttyCore.GhosttyTerminalState) throws -> String {
        guard let raw = state.raw else {
            throw Failure(description: "the viewer closed before its cursor shape was read")
        }
        let render = try GhosttyRenderStateHandle()
        try ghosttyCheck(ghostty_render_state_update(render.raw, raw), "ghostty_render_state_update")
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.stride
        try ghosttyCheck(
            ghostty_render_state_get(render.raw, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor),
            "ghostty_render_state_get(CURSOR)")
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: return "bar"
        case GHOSTTY_CURSOR_STYLE_BLOCK: return "block"
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: return "underline"
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: return "hollow block"
        default: return "\(cursor.visual_style)"
        }
    }
}

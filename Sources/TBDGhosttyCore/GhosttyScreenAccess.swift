// GhosttyScreenAccess — one lock hold's worth of screen reads and mouse encoding, for a host.
//
// A host that routes the wheel itself, as the app's scroll monitor does, has to ask two things in
// one observation: whether the program is taking mouse reports, and, if it is, what the reports
// are. Asked in two lock holds, a feed between them could turn reporting off, and the host would
// send reports the program no longer reads. So both answers come from here, from the same encoder
// the view routes its own clicks and wheel by, under the one lock `withScreenAccess` holds.
import Foundation
import GhosttyVt

/// The screen, and the mouse encoder's view of it, for the length of one
/// `GhosttyTerminal.withScreenAccess` call.
///
/// **It must not escape that call**, for the reason `GhosttyTerminalState` must not: it reads the C
/// terminal directly. After `close()` the state reports a closed terminal and every answer here is
/// empty.
public struct GhosttyScreenAccess {
    /// The screen, read-only.
    public let state: GhosttyTerminalState
    let raw: VtTerminal?
    let binding: InputBinding?

    /// Whether libghostty reports a mouse press under the program's mouse modes as they stand.
    /// The encoder's answer, the one the view routes clicks and the wheel by, not the mode bits:
    /// after `?1000h ?1003h ?1003l` the 1000 bit is still set and nothing is reported.
    public var isMouseReporting: Bool {
        guard let raw, let binding else { return false }
        return binding.mouseEncoder.isReporting(terminal: raw)
    }

    /// The wheel reports for `lines` rows of scrolling at a cell, encoded in the program's mouse
    /// format: one press of button four per row up (positive `lines`), of button five per row
    /// down. Empty unless the program is taking reports, so a host never scrolls the viewport or
    /// types arrow keys through this.
    public func wheelReports(lines: Int, column: Int, row: Int) -> [UInt8] {
        guard lines != 0, let raw, let binding,
              binding.mouseEncoder.wheelRoute(terminal: raw) == .reports else { return [] }
        // The middle of the cell, in the surface pixels the encoder converts back to a cell.
        let geometry = binding.mouseEncoder.geometry
        let cellWidth = Double(max(geometry.cellWidth, 1))
        let cellHeight = Double(max(geometry.cellHeight, 1))
        let point = SurfacePoint(
            x: Double(geometry.paddingLeft) + (Double(max(column, 0)) + 0.5) * cellWidth,
            y: Double(geometry.paddingTop) + (Double(max(row, 0)) + 0.5) * cellHeight)
        do {
            // The encoder's rows are negative for up, the opposite of `lines`.
            guard case .report(let press, let count) = try binding.mouseEncoder.wheel(
                rows: -lines, at: point, terminal: raw) else { return [] }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(press.count * count)
            for _ in 0..<count { bytes.append(contentsOf: press) }
            return bytes
        } catch {
            terminalEngineLog.error("encoding wheel reports failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The OSC 8 URI of the cell at `column`, `row` of the viewport, or nil when it has none.
    public func hyperlink(column: Int, row: Int) -> String? {
        guard let raw, column >= 0, row >= 0, column <= Int(UInt16.max) else { return nil }
        let point = TerminalGridPoint(x: UInt16(column), y: UInt32(row), space: .viewport)
        return HyperlinkLookup.uri(at: point, in: raw)
    }
}

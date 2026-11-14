import GhosttyVt

/// An opaque 8-bit sRGB colour: what `GhosttyTerminalState` reports for the palette and the
/// default colours, and what a view's appearance sets them from (`GhosttyAppearance.RGB`, an alias
/// of this type).
public struct GhosttyRGB: Sendable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

extension GhosttyRGB {
    package init(_ color: GhosttyColorRgb) {
        self.init(r: color.r, g: color.g, b: color.b)
    }

    package var vtColor: GhosttyTerminal.VtColor {
        GhosttyTerminal.VtColor(r: r, g: g, b: b)
    }
}

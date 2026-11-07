// Replaces tkzmux's TkzCore `Theme` and `RGB` with the handful of tokens the terminal reads.
// Colours are tkzmux's "black" preset values; the palette is the common xterm-style 16.
import CoreGraphics
import Foundation

public struct RGB: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xff) / 255, g: Double((hex >> 8) & 0xff) / 255,
                  b: Double(hex & 0xff) / 255, a: alpha)
    }
    public var bytes: (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }
    /// Source-over onto an opaque background.
    public func over(_ background: RGB) -> RGB {
        RGB(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a))
    }
}

public struct Theme: Hashable, Sendable {
    public struct FontMono: Hashable, Sendable {
        public var family = "Menlo"
        public var fallback = "Menlo"
        public var terminal: CGFloat = 13
        public var thicken = true
    }

    public var isDark = true
    public var terminalBackground = RGB(hex: 0x111113)
    public var terminalForeground = RGB(hex: 0xd8d8dc)
    public var accent = RGB(hex: 0x8b93f8)
    public var selection = RGB(r: 1, g: 1, b: 1, a: 0.20)
    public var terminalMinContrast = 1.0
    public var fontMono = FontMono()
    public var terminalPalette16: [RGB] = [
        0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
        0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
    ].map { RGB(hex: $0) }

    public static var `default` = Theme()
}

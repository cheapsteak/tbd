import Foundation
import SwiftTerm

/// Encodes a SwiftTerm `Attribute` as SGR parameters.
///
/// SwiftTerm has an internal `Attribute.toSgr()`; it is unreachable from here
/// and defective in three ways this encoder must not reproduce — a stray
/// trailing separator on the ANSI-16 branches, a `> 16` cutoff where the
/// 256-colour range begins at 16, and silence on underline style, underline
/// colour, dim, italic and crossed-out.
///
/// Every parameter list begins with `0`. A run is therefore self-describing:
/// the reader does not need to have seen the preceding run, which is what lets
/// the cell walk restart mid-scrollback and what stops a dangling attribute
/// bleeding into the rows below (the same discipline `ParkedSnapshotComposer`
/// applies for the same reason).
public enum SGREncoder {
    public static func sequence(for attribute: Attribute) -> String {
        "\u{1b}[" + parameters(for: attribute) + "m"
    }

    public static func parameters(for attribute: Attribute) -> String {
        var parts: [String] = ["0"]

        let style = attribute.style
        if style.contains(.bold) { parts.append("1") }
        if style.contains(.dim) { parts.append("2") }
        if style.contains(.italic) { parts.append("3") }
        if style.contains(.inverse) { parts.append("7") }
        if style.contains(.invisible) { parts.append("8") }
        if style.contains(.crossedOut) { parts.append("9") }

        switch attribute.underlineStyle {
        case .none:
            if style.contains(.underline) { parts.append("4") }
        case .single: parts.append("4")
        case .double: parts.append("4:2")
        case .curly: parts.append("4:3")
        case .dotted: parts.append("4:4")
        case .dashed: parts.append("4:5")
        }

        parts.append(contentsOf: colorParameters(attribute.fg, ground: .foreground))
        parts.append(contentsOf: colorParameters(attribute.bg, ground: .background))
        if let underlineColor = attribute.underlineColor {
            parts.append(contentsOf: colorParameters(underlineColor, ground: .underline))
        }

        return parts.joined(separator: ";")
    }

    private enum Ground {
        case foreground, background, underline

        var ansiBase: Int {
            switch self {
            case .foreground: return 30
            case .background: return 40
            case .underline: return 0   // underline has no ANSI-16 form
            }
        }

        var brightBase: Int {
            switch self {
            case .foreground: return 90
            case .background: return 100
            case .underline: return 0
            }
        }

        var extendedIntroducer: Int {
            switch self {
            case .foreground: return 38
            case .background: return 48
            case .underline: return 58
            }
        }
    }

    private static func colorParameters(_ color: Attribute.Color, ground: Ground) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return []
        case .trueColor(let r, let g, let b):
            return ["\(ground.extendedIntroducer)", "2", "\(r)", "\(g)", "\(b)"]
        case .ansi256(let code):
            let value = Int(code)
            // The 256-colour range starts AT 16. Anything below is expressible
            // as ANSI-16, and only for the two grounds that have such a form.
            if value >= 16 || ground == .underline {
                return ["\(ground.extendedIntroducer)", "5", "\(value)"]
            }
            return value >= 8
                ? ["\(ground.brightBase + value - 8)"]
                : ["\(ground.ansiBase + value)"]
        }
    }
}

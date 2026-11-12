/// Escaping text for HTML and XML: element text and double-quoted attribute
/// values.
public enum HTMLEscaping {
    /// `text` with each `&`, `<`, `>` and `"` written as `&amp;`, `&lt;`,
    /// `&gt;` and `&quot;`. With `includingApostrophe`, each `'` is written as
    /// `&#39;` too. Everything else is copied as it is.
    ///
    /// The replacement runs over Unicode scalars, so every one of those
    /// characters is escaped whatever sits next to it. Foundation's
    /// `replacingOccurrences(of:with:)` and Swift's `Character` comparison
    /// compare composed character sequences instead. A `"` followed by a
    /// combining mark (U+0301), a variation selector (U+FE0F) or an enclosing
    /// keycap (U+20E3), or preceded by a prepended concatenation mark
    /// (U+0600), forms one character with it and is not replaced. An HTML
    /// parser reads code points, so it ends the attribute value at that `"`
    /// and reads the rest of the text as attributes.
    ///
    /// One pass, so the `&` of an entity this writes is never escaped again.
    public static func escaped(_ text: String, includingApostrophe: Bool = false) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped.append(contentsOf: "&amp;".unicodeScalars)
            case "<": escaped.append(contentsOf: "&lt;".unicodeScalars)
            case ">": escaped.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": escaped.append(contentsOf: "&quot;".unicodeScalars)
            case "'" where includingApostrophe: escaped.append(contentsOf: "&#39;".unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        return String(escaped)
    }
}

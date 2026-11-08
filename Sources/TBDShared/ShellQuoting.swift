/// Quoting text as one POSIX shell word.
public enum ShellQuoting {
    /// `text` as one single-quoted shell word: wrapped in `'`, with each `'`
    /// in it written as `'\''` (close the quote, an escaped quote, reopen).
    ///
    /// The replacement runs over Unicode scalars, so every U+0027 is escaped
    /// whatever follows it. Foundation's `replacingOccurrences(of:with:)`
    /// compares composed character sequences instead: a `'` followed by a
    /// combining mark (U+0301), a variation selector (U+FE0F) or an enclosing
    /// keycap (U+20E3) forms one character with it and is not replaced. The
    /// shell reads bytes, so it ends the quoted word at that `'` and runs the
    /// rest of the text as commands.
    public static func singleQuoted(_ text: String) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in text.unicodeScalars {
            if scalar == "'" {
                quoted.append(contentsOf: #"'\''"#.unicodeScalars)
            } else {
                quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
    }
}

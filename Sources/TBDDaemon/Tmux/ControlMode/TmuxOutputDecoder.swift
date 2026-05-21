import Foundation

/// Decodes the octal-escaped payload of a tmux `%output` / `%extended-output`
/// notification back into raw bytes.
enum TmuxOutputDecoder {
    /// Decode an escaped payload string into raw bytes.
    ///
    /// A backslash not followed by three octal digits is passed through
    /// literally — control-mode payloads should never contain one, but
    /// silently dropping bytes would be worse than emitting a stray backslash.
    static func decode(_ escaped: String) -> Data {
        var out = Data()
        let bytes = Array(escaped.utf8)
        let backslash = UInt8(ascii: "\\")
        var i = 0
        while i < bytes.count {
            guard bytes[i] == backslash, i + 3 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let d0 = octalValue(bytes[i + 1]),
                  let d1 = octalValue(bytes[i + 2]),
                  let d2 = octalValue(bytes[i + 3]) else {
                out.append(bytes[i])  // not a valid escape; emit the backslash
                i += 1
                continue
            }
            out.append(UInt8((d0 * 64 + d1 * 8 + d2) & 0xFF))
            i += 4
        }
        return out
    }

    private static func octalValue(_ byte: UInt8) -> Int? {
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else { return nil }
        return Int(byte - UInt8(ascii: "0"))
    }
}

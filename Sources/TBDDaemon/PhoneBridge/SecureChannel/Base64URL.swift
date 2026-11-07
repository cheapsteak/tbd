import Foundation

/// Base64url without padding (RFC 4648 section 5), decoded strictly.
///
/// The phone channel carries room IDs, secrets and keys as base64url text,
/// and the loader decodes them with the same rules, so both sides must agree
/// on which strings name which bytes. `decode` accepts only the canonical
/// text for each byte string: no `=` padding, no standard `+/` alphabet, no
/// length of 1 mod 4, and no last character with non-zero spare bits.
/// Foundation's `Data(base64Encoded:)` alone accepts `"AB=="` as one byte,
/// which is the same byte `"AA"` names, so a lenient decoder would let two
/// texts name one relay room.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The bytes `string` names, or `nil` unless `string` is canonical
    /// base64url without padding.
    static func decode(_ string: String) -> Data? {
        let length = string.utf8.count
        guard length % 4 != 1, string.utf8.allSatisfy(isAlphabetByte) else { return nil }
        let standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - length % 4) % 4)
        // Re-encoding rejects a last character with non-zero spare bits,
        // which `Data(base64Encoded:)` drops silently.
        guard let data = Data(base64Encoded: standard), encode(data) == string else { return nil }
        return data
    }

    private static func isAlphabetByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"),
             UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}

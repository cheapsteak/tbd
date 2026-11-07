import Foundation

/// Loads the phone channel's shared vectors from `phone/test-vectors/`, the
/// files the loader's Node tests read too.
enum PhoneTestVectors {
    static func load<T: Decodable>(_ fileName: String, as type: T.Type) throws -> T {
        // This file sits in Tests/TBDDaemonTests/PhoneBridge, four levels
        // below the repo root.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("phone/test-vectors")
            .appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    /// The bytes a lowercase or uppercase hex string spells.
    static func bytes(_ hex: String) -> Data {
        precondition(hex.utf8.count.isMultiple(of: 2), "odd-length hex: \(hex)")
        var data = Data(capacity: hex.utf8.count / 2)
        var rest = Substring(hex)
        while !rest.isEmpty {
            let pair = rest.prefix(2)
            guard pair.allSatisfy(\.isHexDigit), let byte = UInt8(pair, radix: 16) else {
                preconditionFailure("not hex: \(hex)")
            }
            data.append(byte)
            rest = rest.dropFirst(2)
        }
        return data
    }
}

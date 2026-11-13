// Scoped: only the protocol's constants are needed from TBDShared.
import enum TBDShared.ProgramStatusProtocol

/// libghostty's answer to the OSC 7501 probe, found in the reply bytes and
/// swapped for TBD's.
///
/// The reply bytes carry only what the terminal writes back to the program:
/// a paste is captured apart from them, and keys never pass through them. So
/// anything there that starts `ESC ] 7501 ; ?` is libghostty answering the
/// probe, and it runs to the string terminator, BEL or `ESC \`. libghostty
/// writes a whole answer inside one parse, so an answer never straddles two
/// deliveries.
package enum ProgramStatusProbeAnswer {
    package static let introducer: [UInt8] = Array("\u{1b}]\(ProgramStatusProtocol.oscCode);?".utf8)

    /// `bytes` with every probe answer replaced by `replacement`, or removed
    /// when it is nil. Everything else is kept, in order.
    package static func replacingLibghosttyAnswers(in bytes: [UInt8], with replacement: [UInt8]?) -> [UInt8] {
        swappingLibghosttyAnswers(in: bytes, with: replacement).bytes
    }

    /// `replacingLibghosttyAnswers(in:with:)`, and how many answers it found.
    /// libghostty has no event for a probe it saw, so the count is how an
    /// owner learns that one arrived: the daemon records each probe it
    /// answers.
    package static func swappingLibghosttyAnswers(
        in bytes: [UInt8], with replacement: [UInt8]?
    ) -> (bytes: [UInt8], answers: Int) {
        guard bytes.count >= introducer.count, let first = introducerIndex(in: bytes, from: 0) else {
            return (bytes, 0)
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var answers = 0
        var cursor = 0
        var start: Int? = first
        while let answerStart = start {
            out.append(contentsOf: bytes[cursor..<answerStart])
            guard let end = terminatorEnd(in: bytes, from: answerStart + introducer.count) else {
                // No terminator: not an answer libghostty finished, so it is
                // left as it is.
                cursor = answerStart
                break
            }
            if let replacement { out.append(contentsOf: replacement) }
            answers += 1
            cursor = end
            start = introducerIndex(in: bytes, from: end)
        }
        out.append(contentsOf: bytes[cursor...])
        return (out, answers)
    }

    private static func introducerIndex(in bytes: [UInt8], from index: Int) -> Int? {
        var position = index
        while position + introducer.count <= bytes.count {
            if bytes[position] == 0x1B, bytes[position..<(position + introducer.count)].elementsEqual(introducer) {
                return position
            }
            position += 1
        }
        return nil
    }

    /// The index just past the BEL or `ESC \` that ends the string at `index`.
    private static func terminatorEnd(in bytes: [UInt8], from index: Int) -> Int? {
        var position = index
        while position < bytes.count {
            switch bytes[position] {
            case 0x07:
                return position + 1
            case 0x1B where position + 1 < bytes.count && bytes[position + 1] == UInt8(ascii: "\\"):
                return position + 2
            default:
                position += 1
            }
        }
        return nil
    }
}

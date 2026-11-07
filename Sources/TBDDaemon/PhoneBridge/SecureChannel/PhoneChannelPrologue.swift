import Foundation

/// The Noise prologue both sides mix into the handshake hash: UTF-8
/// `tbd-phone/1` followed by the 32 raw room-ID bytes. The phone and the
/// laptop must build the same bytes, or every handshake fails with a bare
/// `decryptFailed`, so the room ID goes in as raw bytes, never as its
/// base64url text. The label carries the channel version, so a future
/// channel cannot be confused with this one.
enum PhoneChannelPrologue {
    static let label = "tbd-phone/1"

    static func make(roomID: Data) throws -> Data {
        guard roomID.count == 32 else {
            throw NoiseError.invalidRoomID
        }
        return Data(label.utf8) + roomID
    }
}

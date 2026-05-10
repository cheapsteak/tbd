import Foundation
import GRDB
import TBDShared

/// GRDB Record for the `channel_index` table — derivable cache of per-channel
/// metadata that backs `tbd channels list` and the daemon's per-post update.
struct ChannelIndexRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "channel_index"

    var name: String
    var createdAt: Date
    var lastMessageAt: Date?
    var messageCount: Int
}

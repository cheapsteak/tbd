import Foundation
import TBDShared

/// A remote lane the sidebar is already drawing, before the daemon has a row
/// for it. Client-side only — nothing here is persisted or sent anywhere.
///
/// `sessionID` is the whole reason this type exists. A local create is swapped
/// on the id the create RPC returns; `remote.create` returns the PROVIDER's
/// session payload, and the worktree row is minted separately by
/// `RemoteSessionAdopter` under a UUID unrelated to `id`. The only fact both
/// sides share is the `(provider, sessionID)` pair the row carries in its
/// `Worktree.location` — so that pair, not an id, is what retires this
/// placeholder. It is nil until `remote.create` answers, which is exactly why
/// the correlation has to tolerate the row arriving first.
struct PendingRemoteLane: Equatable, Sendable, Identifiable {
    /// The placeholder row's id. The daemon has never heard of it.
    let id: UUID
    /// The repo section the placeholder was appended to.
    let repoID: UUID
    let provider: String
    /// The provider's session id, known only once `remote.create` returns.
    var sessionID: String?
}

/// Pure decisions behind the optimistic remote-lane row: what it calls itself,
/// and when the real row has arrived to replace it. No SwiftUI and no
/// `AppState`, so both are directly unit-testable — same seam shape as
/// `RemoteCreateFormLogic`.
enum RemoteLanePlaceholder {
    /// Well-known `create_params` names (`docs/remote-provider-contract.md`
    /// § `describe`) worth showing on the row, in the order a provider is
    /// likeliest to derive its own title from.
    private static let nameKeys = ["title", "slug"]

    /// What the placeholder row is called while it waits.
    ///
    /// Read out of the very params being sent, so the row reads like the lane
    /// the user asked for rather than an invented name: a provider normally
    /// titles the session after `title` or `slug`, and `RemoteSessionAdopter`
    /// then names the real row from that title. A guess is fine here in a way
    /// it would not be for a create param — this string is replaced by the
    /// adopted row's own `displayName` the moment it lands, and the row it
    /// labels is visibly `.creating` until then.
    ///
    /// `fallback` covers a provider whose create form has neither key (and a
    /// `paramsJSON` that does not parse at all); callers pass a generated
    /// name, the same generator local worktree placeholders use.
    static func displayName(paramsJSON: String, fallback: String) -> String {
        guard let data = paramsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return fallback }
        for key in nameKeys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }

    /// The real row `lane` was drawn for, if the app is already holding it.
    ///
    /// Matches on the `(provider, sessionID)` binding alone — never on name,
    /// branch or repo. Adoption seeds a row's name once and the user is free to
    /// change it, and the repo a session resolves to is the daemon's decision,
    /// not the placeholder's guess: a lane filed under a different repo than
    /// the `+` that started it is still that lane, and leaving the placeholder
    /// behind would show it twice.
    ///
    /// Answers nil while `sessionID` is unknown, which is the arrival order
    /// where the row lands BEFORE `remote.create` returns: nothing can be
    /// correlated yet, so the caller keeps waiting and asks again the moment
    /// the session id arrives. The placeholder itself is excluded by id, so a
    /// placeholder can never retire itself.
    static func adoptedRow(for lane: PendingRemoteLane, in rows: [Worktree]) -> Worktree? {
        guard let sessionID = lane.sessionID else { return nil }
        let binding = WorktreeLocation.remote(provider: lane.provider, sessionID: sessionID)
        return rows.first { $0.id != lane.id && $0.location == binding }
    }
}

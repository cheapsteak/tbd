import Foundation
import os
import TBDShared

private let shadowPeerLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - Drops

/// Why a frame was dropped.
///
/// Every case is loss the sender is never told about: the channel has no reply
/// path, and nothing on it is acknowledged. A silent drop is this feature's
/// characteristic failure, so there is no "just return" anywhere in the frame
/// paths below — a frame that does not get delivered gets counted here, and the
/// counts surface in `tbd peer list`.
public enum ShadowPeerDropReason: String, Sendable, CaseIterable, Codable {
    /// The frame named a handle that is not in the table. **The security
    /// boundary in one case**: it covers an inbound `to` naming a local session
    /// TBD never announced, an inbound `from` naming a shadow TBD never
    /// published, and an outbound `from` naming a local socket the roster never
    /// admitted. A handle outside the table resolves to nothing — never to a
    /// name match, a nearest match, or a broadcast.
    case unknownHandle
    /// An outbound frame's content still carried a path into the local
    /// peer-socket directory, so it was dropped instead of sent.
    ///
    /// **Defence in depth, and it should never fire.** The sender's own
    /// attribution wrapper — which names its socket, the name it chose for
    /// itself, and the permission class it claims — is removed by
    /// `PeerHelper.strippedOfSenderAttribution` one hop earlier, and that strip
    /// is anchored on the content beginning with a particular element. A
    /// leading newline, a renamed element or a reshaped wrapper makes the strip
    /// a silent no-op, and "raw socket paths never travel" is structural rather
    /// than advisory. A count here means that anchor stopped matching: the
    /// frame is lost, which is the cheap failure, and the regression is visible
    /// in `tbd peer list` rather than silent on the wire.
    case unstrippedAddress
    /// The link was down. Clean failure, no buffering: the send fails exactly
    /// as messaging a session that has exited fails.
    case linkDown
    /// The link was up but its stdin would have blocked. **A different fact
    /// from `linkDown`, and worth its own count**: the far side is alive and
    /// not draining, which is backpressure to investigate rather than a
    /// connection to re-dial. Writes to the provider are non-blocking, so a
    /// write that would block fails the frame rather than parking the caller.
    case linkWouldBlock
    /// The write to the link failed outright.
    case linkWriteFailed
    /// The link took only part of the frame. Fatal to the connection — a
    /// half-written line corrupts every frame after it — so the link goes down
    /// behind this and a `linkStateChanged(to: .down)` follows.
    case linkTruncated
    /// TBD tried to send a line kind the contract carries in one direction
    /// only. A programming error on this side, counted rather than swallowed
    /// so it cannot hide as ordinary loss.
    case notOutbound
    /// Past the 512 KB frame cap. Dropped whole rather than truncated — a
    /// truncated frame arrives looking valid while saying something the sender
    /// did not.
    case oversized
    /// The helper that should have carried the frame is gone, or has stopped
    /// draining its stdin.
    case helperGone
    /// The local session's socket refused the write. `ECONNREFUSED` here is the
    /// designed signal that a session has exited.
    case deliveryFailed
    /// Not decodable as a frame of the kind it claimed to be.
    case malformed
}

/// Frames dropped, by reason.
///
/// Ordered rendering rather than a bare dictionary because these numbers exist
/// to be read: `tbd peer list` prints them, and a test asserts on the whole
/// composed line rather than picking one count out of a map.
public struct ShadowPeerDropCounts: Sendable, Equatable {
    private var counts: [ShadowPeerDropReason: Int] = [:]

    public init() {}

    public subscript(reason: ShadowPeerDropReason) -> Int {
        counts[reason] ?? 0
    }

    public var total: Int {
        counts.values.reduce(0, +)
    }

    public mutating func record(_ reason: ShadowPeerDropReason) {
        counts[reason, default: 0] += 1
    }

    /// One line, in `ShadowPeerDropReason`'s declaration order, naming only the
    /// reasons that actually fired. `"none"` when nothing was dropped, so the
    /// healthy case reads as a statement rather than as an empty string.
    public var summary: String {
        let fired = ShadowPeerDropReason.allCases
            .filter { self[$0] > 0 }
            .map { "\($0.rawValue)=\(self[$0])" }
        return fired.isEmpty ? "none" : fired.joined(separator: " ")
    }
}

// MARK: - Siting a shadow

/// Where a remote session lands locally.
///
/// A shadow needs both halves and can be published with neither invented. The
/// display name is the whole of its identity — the pane join that disambiguates
/// local peers is unavailable to it — and the path is a `cwd` that must exist
/// on **this** machine, because a remote path resolves to nothing here and a
/// surface filtering on the directory existing would drop the row.
public struct ShadowPeerSite: Sendable, Equatable {
    public let worktreeDisplayName: String
    public let path: String

    public init(worktreeDisplayName: String, path: String) {
        self.worktreeDisplayName = worktreeDisplayName
        self.path = path
    }
}

/// Resolves the provider's own session id to the local worktree TBD adopted
/// that remote session into.
///
/// A seam rather than a database call inside the manager, for two reasons. The
/// join is over TBD's own worktree rows, which is somebody else's subsystem;
/// and every handle-table and attribution test below then needs no database at
/// all.
///
/// **The join key is the session id and nothing else on the `peer` line.** That
/// id is the `id` the provider's Session object already carries, which is what
/// TBD stored as the row's `providerSessionID` when it adopted the session, so
/// an implementation is a `findRemote(provider:sessionID:)` probe rather than a
/// search. The alternatives on the line are not identities: a handle means
/// nothing outside one connection, and the name is the far side's assertion —
/// naming a shadow after it would publish exactly the invented identity this
/// design refuses (see `composedName(for:)`).
public protocol ShadowPeerSiteResolving: Sendable {
    /// Nil when TBD has no worktree for this session. A remote session that
    /// resolves to no registered repository is never bridged, so nil means "do
    /// not publish a shadow" rather than "publish one with a guess".
    func site(forProviderSessionID sessionID: String) async -> ShadowPeerSite?
}

// MARK: - What the manager can be asked about

/// One published shadow, for `tbd peer list` and for the reclaimer's whitelist.
///
/// The three durable artifacts a shadow owns are named here — process, socket,
/// record — because `ShadowPeerReconciler` reclaims against a whitelist of
/// artifacts TBD's own bookkeeping recorded, and **MUST NOT** reclaim by
/// inference. A shadow's record carries no field Claude Code does not define,
/// so there is no marker inside it to recognise; this is the recognition.
public struct ShadowPeerSummary: Sendable, Equatable {
    public let handle: String
    public let name: String
    public let status: String
    public let pid: pid_t
    public let socketPath: String
    public let recordPath: String
    /// The **provider's** session id — the remote session this shadow stands
    /// for, taken off the `peer` line that sited it.
    ///
    /// Deliberately not on the durable artifact row, which carries the id of
    /// the record the helper publishes here instead. The two are different
    /// identities and neither can stand in for the other: the record's id is
    /// what proves ownership before an unlink, and this is what names the
    /// session on the far host. This one is held for the life of one
    /// connection, exactly like the handle beside it, because that is how long
    /// the announcement that supplied it is good for.
    public let remoteSessionID: String?

    public init(
        handle: String, name: String, status: String, pid: pid_t,
        socketPath: String, recordPath: String, remoteSessionID: String? = nil
    ) {
        self.handle = handle
        self.name = name
        self.status = status
        self.pid = pid
        self.socketPath = socketPath
        self.recordPath = recordPath
        self.remoteSessionID = remoteSessionID
    }
}

/// Everything the manager can answer about one provider's shadow peers.
public struct ShadowPeerSnapshot: Sendable, Equatable {
    public let provider: String
    /// The origin the far side declared in its `hello`, or nil before one
    /// arrived.
    public let origin: String?
    /// Shadows currently published, ordered by handle so the value is
    /// comparable.
    public let shadows: [ShadowPeerSummary]
    /// Handles TBD minted for local sessions and announced on this link.
    public let localHandles: [String]
    /// Handles the far side announced that TBD could not site, and therefore
    /// never mirrored — a `peer` line with no session id on it, or one whose
    /// session id names no worktree row TBD adopted, among them. Surfaced
    /// rather than swallowed: a feature that silently does nothing is the
    /// failure this contract's users have been bitten by.
    public let unmirroredHandles: [String]
    /// Handles the provider's last `peer-inventory` claimed but TBD never
    /// announced, and vice versa. TBD cannot verify the far half's hygiene, so
    /// the divergence is the mitigation: a provider that leaks is visible as a
    /// difference rather than as a mystery.
    public let inventorySurplus: [String]
    public let inventoryMissing: [String]
    public let drops: ShadowPeerDropCounts

    public init(
        provider: String, origin: String?, shadows: [ShadowPeerSummary],
        localHandles: [String], unmirroredHandles: [String],
        inventorySurplus: [String], inventoryMissing: [String],
        drops: ShadowPeerDropCounts
    ) {
        self.provider = provider
        self.origin = origin
        self.shadows = shadows
        self.localHandles = localHandles
        self.unmirroredHandles = unmirroredHandles
        self.inventorySurplus = inventorySurplus
        self.inventoryMissing = inventoryMissing
        self.drops = drops
    }
}

// MARK: - The manager

/// Owns the local half of one provider's shadow peers: the handle table, the
/// helper processes behind it, and every frame that crosses in either
/// direction.
///
/// **The handle table is the security boundary, and it has two halves.** Each
/// side of the link mints handles for its own peers, so the table holds both
/// what TBD was *given* (the provider's handles, one per remote session, each
/// backed by a helper here) and what TBD *minted* (one per local session the
/// roster announced, each bound to a real socket in the peer-socket directory).
/// Delivery is a lookup in that table and nothing else:
///
/// - an inbound `message`'s `to` is looked up among the handles TBD minted, so
///   a frame can only ever reach a session TBD chose to announce. Without that
///   lookup the wire would carry socket paths, and a compromised far side could
///   name any socket in `/tmp/cc-socks` — including a personal non-TBD session,
///   or one on a profile logged into a different account.
/// - an inbound `message`'s `from` is looked up among the handles TBD was
///   given, because attribution is stamped from the handle the frame arrived on
///   and a frame that cannot be attributed is one that cannot be stamped.
/// - an outbound `from` is rewritten from the local sender's real `uds:`
///   address to the handle TBD minted for it, so **no raw socket path ever
///   travels**.
///
/// That last lookup is also where the outward scoping lands for free. The
/// roster admits only TBD-spawned sessions in the right repository, so a local
/// session it never announced has no handle, and a message it writes to a
/// shadow's socket is dropped here rather than leaving the machine.
///
/// **Handles die with the connection.** A handle names one session for the life
/// of one stream and means nothing outside it, so a link that goes down clears
/// both halves of the table; the next `hello` re-announces the whole roster
/// from scratch. Nothing here is persisted across connections.
///
/// **Link down means every shadow goes away**, not that it stops answering. A
/// listening socket cannot decline — `connect()` succeeds while a listener
/// exists and the transport is connect-write-close with no handshake — so a
/// shadow left bound would report success to every sender and discard
/// everything. Tearing the helper down closes and unlinks the listener, which
/// gives the sender `ECONNREFUSED` and lets `ListAgents`' connect-and-drop
/// probe delist the row.
///
/// Design: `docs/specs/2026-08-29-remote-peer-messaging-design.md`
/// §§ "Trust", "Shadow peer lifecycle", "Failure semantics".
///
/// **Reclamation is not this type's job.** The helper processes, sockets and
/// records it creates are durable external resources, and their named
/// reconciler is `ShadowPeerReconciler` (that spec, § "Reclamation and
/// detection"), which sweeps against the whitelist `artifacts()` exposes.
public actor ShadowPeerManager: PeerLinkHandler, LocalPeerHandleRegistry {
    /// One shadow: the handle the far side minted, the helper behind it, and
    /// the reader task draining that helper's stdout.
    private struct Shadow {
        let handle: String
        var name: String
        var status: String
        let peerProtocol: Int
        /// The provider's session id this shadow was sited by. `let`, because
        /// a handle names one session for the life of one connection and that
        /// session never becomes a different one.
        let remoteSessionID: String?
        let helper: any ShadowPeerHelperHandle
        var reader: Task<Void, Never>?
    }

    /// One local session TBD announced on this link: the handle it minted, and
    /// the real socket that handle privately resolves to.
    private struct LocalPeer {
        let handle: String
        let socketPath: String
        let name: String
    }

    private let provider: String
    private let link: any PeerLinkSending
    private let spawner: any ShadowPeerHelperSpawning
    private let siteResolver: any ShadowPeerSiteResolving
    private let delivery: any LocalPeerDelivering
    private let socketDirectory: URL
    /// `socketDirectory.path`, held because every outbound frame's content is
    /// checked against it.
    ///
    /// The configured path verbatim, never a resolved or standardized one: what
    /// the check is looking for is the text a sender's own client wrote into a
    /// message, and on macOS standardizing `/tmp/cc-socks` to `/private/tmp/...`
    /// would leave it matching nothing.
    private let socketDirectoryPath: String
    private let sessionsDirectory: URL
    private let grantedMode: String
    /// Mints opaque handles for local sessions. A seam so a test can pin them;
    /// the default is random, because a handle must carry no information a
    /// receiver could parse.
    private let mintHandle: @Sendable () -> String
    /// Mints Claude Code's own `msg_id` for a composed agent frame. A seam for
    /// the same reason: it lets a test assert the whole composed payload.
    private let mintAgentMessageID: @Sendable () -> String
    /// Mints the stable session id a shadow's record keeps across rewrites.
    private let mintSessionID: @Sendable () -> String
    /// Where a published shadow's three artifacts are written down so they
    /// survive a daemon restart.
    ///
    /// **The manager's own table is not enough, and that is not a nicety.** A
    /// shadow's record carries no field Claude Code does not define (an unknown
    /// key was measured to make a record invisible to every listing while
    /// surviving on disk), so TBD cannot mark its own records from the inside
    /// and cannot recognise one by its path either. Bookkeeping that died with
    /// the daemon would leave every shadow of a crashed daemon unrecognisable —
    /// a helper, a socket and a record that nothing on the machine can ever
    /// claim. `ShadowPeerReconciler` reclaims against exactly these rows.
    private let artifactRecorder: any ShadowPeerArtifactRecording

    private var shadows: [String: Shadow] = [:]
    private var localPeers: [String: LocalPeer] = [:]
    /// `uds:<path>` → the handle TBD minted for it. The reverse index of
    /// `localPeers`, kept because the outbound path resolves by address.
    private var localHandlesByAddress: [String: String] = [:]
    private var unmirrored: Set<String> = []
    /// Bumped every time the link goes down.
    ///
    /// **The guard against resurrecting a shadow the teardown already
    /// reclaimed.** `applyPeer` suspends twice — once resolving the site, once
    /// spawning — and a `linkStateChanged(to: .down)` can land in either
    /// window, which the supervisor makes routine rather than exotic: a short
    /// write is fatal to the connection, so an ordinary send failure produces a
    /// `.down`. Without a generation captured before the suspension, the spawn
    /// that resumes afterwards would install a helper into a table that had
    /// just been emptied, and nothing would ever close that listener again.
    private var linkGeneration = 0
    private var remoteOrigin: String?
    private var inventorySurplus: [String] = []
    private var inventoryMissing: [String] = []
    private var drops = ShadowPeerDropCounts()

    /// `/tmp/cc-socks`: the directory every Claude Code session on this machine
    /// binds into and reads from. A default rather than a constant so a test
    /// never binds into the real one.
    public static let defaultSocketDirectory = URL(
        fileURLWithPath: "/tmp/cc-socks", isDirectory: true)

    public init(
        provider: String,
        link: any PeerLinkSending,
        siteResolver: any ShadowPeerSiteResolving,
        spawner: any ShadowPeerHelperSpawning = ShadowPeerHelperProcessSpawner(),
        delivery: any LocalPeerDelivering = UnixSocketLocalPeerDelivery(),
        socketDirectory: URL = ShadowPeerManager.defaultSocketDirectory,
        sessionsDirectory: URL = ShadowPeerRecordStore().sessionsDirectory,
        grantedMode: String = ShadowPeerAttribution.grantedMode,
        mintHandle: @escaping @Sendable () -> String = ShadowPeerManager.randomHandle,
        mintAgentMessageID: @escaping @Sendable () -> String = { UUID().uuidString },
        mintSessionID: @escaping @Sendable () -> String = { UUID().uuidString },
        artifactRecorder: any ShadowPeerArtifactRecording = UnrecordedShadowPeerArtifacts()
    ) {
        self.provider = provider
        self.link = link
        self.siteResolver = siteResolver
        self.spawner = spawner
        self.delivery = delivery
        self.socketDirectory = socketDirectory
        self.socketDirectoryPath = socketDirectory.path
        self.sessionsDirectory = sessionsDirectory
        self.grantedMode = grantedMode
        self.mintHandle = mintHandle
        self.mintAgentMessageID = mintAgentMessageID
        self.mintSessionID = mintSessionID
        self.artifactRecorder = artifactRecorder
    }

    /// The shadow published under `handle`, but **only if it is still the one
    /// running as `pid`** — otherwise nil.
    ///
    /// **The one check three suspended callers share, and the reason they share
    /// it.** A handle belongs to the far side. The contract permits it to
    /// retire one and announce the same string again over a link that never
    /// dropped, so `shadows[handle]` after a suspension need not be the shadow
    /// the suspending caller was holding — and every caller here suspends
    /// before acting on what it read. Keyed on the pid because that is already
    /// this file's identity for a shadow: it is what `retireRow` and the
    /// reclaimer's whitelist rows are filed under, and a second notion of
    /// identity beside it would be one more thing to keep in step.
    ///
    /// Three near-identical guards would drift apart. This one does not, and it
    /// hands the *current* entry back rather than a bool so no caller is
    /// tempted to act on the copy it took before it suspended.
    private func currentShadow(handle: String, pid: pid_t) -> Shadow? {
        guard let shadow = shadows[handle], shadow.helper.pid == pid else { return nil }
        return shadow
    }

    /// An opaque handle. **Random, and it must stay that way**: the contract
    /// forbids a receiver from parsing a handle or deriving anything from it,
    /// and a handle built out of a pid, a path or an index would invite exactly
    /// that. The `h-` prefix is for logs, not for parsing.
    public static let randomHandle: @Sendable () -> String = {
        let hex = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
        return "h-" + hex.joined()
    }

    // MARK: - Inbound from the link

    /// Apply one frame the far side sent.
    public func handle(_ frame: PeerBridgeFrame) async {
        switch frame {
        case .hello(let origin, _):
            remoteOrigin = origin
            shadowPeerLogger.info("""
                peer link \(self.provider, privacy: .public) answered hello from origin \
                \(origin, privacy: .public)
                """)
        case .peer(let peer):
            await applyPeer(peer)
        case .peerGone(let handle):
            await withdrawShadow(handle: handle, because: "the far side withdrew it")
        case .message(let message):
            await deliverInbound(message)
        case .peerInventory(let handles):
            applyInventory(handles)
        case .ping:
            break  // the link's own liveness is the supervisor's to watch
        }
    }

    /// Announce or update one shadow.
    ///
    /// **Idempotent on the handle.** A `peer` line is a complete statement of
    /// one session's state, never a partial diff, so a line for a handle
    /// already published updates the existing helper — it never respawns one.
    /// A respawn would mint a new pid, a new socket and a new record, and every
    /// peer that had settled into addressing the old shadow would be addressing
    /// something that no longer exists.
    private func applyPeer(_ peer: PeerBridgePeer) async {
        let generation = linkGeneration
        if let existing = shadows[peer.handle] {
            // The process this update is addressed to. Both awaits below let
            // the table move on underneath it, and every decision after them is
            // made against this identity rather than against the handle.
            let helperPID = existing.helper.pid
            let name = await composedName(for: peer) ?? existing.name
            do {
                try await existing.helper.send(.peer(PeerBridgePeer(
                    handle: peer.handle, name: name, status: peer.status,
                    peerProtocol: existing.peerProtocol)))
            } catch {
                drops.record(.helperGone)
                shadowPeerLogger.error("""
                    shadow \(peer.handle, privacy: .public) could not be updated: \
                    \(error.localizedDescription, privacy: .public); tearing it down
                    """)
                // The teardown is for the helper that refused the frame, not
                // for whatever holds the handle now: this write went to a copy
                // taken before the `composedName` suspension, and a helper
                // published during it is a live process this call never
                // addressed.
                if currentShadow(handle: peer.handle, pid: helperPID) != nil {
                    await withdrawShadow(
                        handle: peer.handle, because: "its helper stopped answering")
                }
                return
            }
            // **Re-read, never written back from the copy.** A link drop or a
            // `peer-gone` and a fresh announcement can both land in the window
            // above, and writing `existing` back over the result would do three
            // things at once: evict a live helper from the table — out of
            // `artifacts()`, so the sweep's vouched-for inventory never sees it
            // and only the ledger row is left of a process nothing can reclaim
            // — publish a shadow whose own process is already terminated, and
            // leave the far side addressing a handle that now resolves to
            // nothing. The status and name this line carries belong to the
            // entry that is there now, or to nothing at all.
            guard generation == linkGeneration,
                  var current = currentShadow(handle: peer.handle, pid: helperPID)
            else { return }
            current.name = name
            current.status = peer.status
            shadows[peer.handle] = current
            return
        }

        guard let site = await resolveSite(for: peer) else {
            unmirrored.insert(peer.handle)
            shadowPeerLogger.error("""
                \(self.provider, privacy: .public) announced \(peer.name, privacy: .public) \
                (session \(peer.sessionID ?? "<none on the line>", privacy: .public)) but TBD \
                has no worktree row for it; not mirroring it. A shadow needs a local directory \
                that exists and a display name that is its whole identity, both of which come \
                from that row, and neither may be invented
                """)
            return
        }

        let name = "\(provider):\(site.worktreeDisplayName)"
        // `sessionID` here is the id of the *record the helper publishes* on
        // this machine, minted locally and stable across its rewrites. It is
        // not `peer.sessionID`, which names a session on the provider's host
        // and is TBD's join key rather than anything a local record carries.
        let sessionID = mintSessionID()
        let invocation = ShadowPeerHelperInvocation(
            handle: peer.handle, name: name, status: peer.status,
            peerProtocol: peer.peerProtocol, cwd: site.path,
            socketDirectory: socketDirectory, sessionsDirectory: sessionsDirectory,
            sessionID: sessionID)
        let helper: any ShadowPeerHelperHandle
        do {
            helper = try await spawner.spawn(invocation)
        } catch {
            unmirrored.insert(peer.handle)
            shadowPeerLogger.error("""
                could not publish a shadow for \(peer.handle, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        // Written down before the guard below can decide not to install this
        // helper. The record and the socket exist from the instant the process
        // starts, so bookkeeping that waited for a successful install would
        // leave a window in which both artifacts are on disk and nothing can
        // recognise them. The reconciler's publication grace is what keeps a
        // row this fresh from being read as an orphan.
        await artifactRecorder.recordPublished(
            provider: provider, handle: peer.handle, name: name, pid: helper.pid,
            sessionID: sessionID, socketPath: helper.socketPath,
            recordPath: helper.recordPath)

        // Two races land here, and both end the same way: the process this
        // call just started is reclaimed rather than installed. A second `peer`
        // line for the same handle means somebody else already owns the table
        // entry; a bumped generation means the link went down mid-spawn and the
        // teardown has already swept a table this helper was never in. Either
        // way, overwriting or inserting would leak a listener nothing else
        // would ever close.
        guard generation == linkGeneration, shadows[peer.handle] == nil else {
            let termination = await helper.terminate()
            await retireRow(handle: peer.handle, pid: helper.pid, after: termination)
            return
        }

        // The identity of the process this reader is reading, carried into
        // the completion below. A handle is the far side's to reuse, and the
        // pid is what the rest of this file already treats as a shadow's
        // identity — it is the key the reclaimer's whitelist rows are filed
        // under.
        let helperPID = helper.pid
        let reader = Task { [weak self, lines = helper.lines] in
            for await line in lines {
                await self?.helperEmitted(line, from: peer.handle, pid: helperPID)
            }
            // **The stream ending is the only notice a helper's own death
            // gives.** Its stdout closes when the process exits, however it
            // exited — a crash, a stray kill, a `bindListener` that failed on
            // the way up. Returning silently here would leave the shadow in
            // `shadows`, and therefore in `artifacts()` and in the inventory
            // the reclaimer vouches against: the sweep skips a vouched-for row
            // "whatever the process table says", so neither collector would
            // ever take the socket and record, while `tbd peer list` went on
            // reporting a live shadow that does not exist.
            await self?.helperStreamEnded(handle: peer.handle, pid: helperPID)
        }
        shadows[peer.handle] = Shadow(
            handle: peer.handle, name: name, status: peer.status,
            peerProtocol: peer.peerProtocol, remoteSessionID: peer.sessionID,
            helper: helper, reader: reader)
        unmirrored.remove(peer.handle)
        shadowPeerLogger.info("""
            published shadow \(name, privacy: .public) for \(peer.handle, privacy: .public) as \
            pid \(helper.pid, privacy: .public)
            """)
    }

    /// The name a shadow is published under: `<provider>:<worktree display
    /// name>`.
    ///
    /// **No discriminator on collision, deliberately.** The contract makes the
    /// name unique by construction — a session that resolves to a registered
    /// repository gets exactly one worktree row — so the only collision left is
    /// a display name the user reused across two remote worktrees. That
    /// collision costs one refusal naming the `[ref]`, never a misdelivery,
    /// and a name that changed when some *other* session appeared would be
    /// worse than one that occasionally needs a ref.
    private func composedName(for peer: PeerBridgePeer) async -> String? {
        guard let site = await resolveSite(for: peer) else { return nil }
        return "\(provider):\(site.worktreeDisplayName)"
    }

    /// Where the announced session lands locally, or nil when it lands nowhere.
    ///
    /// **Two ways a peer fails to site, and both end here rather than in a
    /// second path.** A `peer` line that carries no session id cannot be joined
    /// to anything — the field is required in this direction for exactly this
    /// reason — and one whose session id names no row TBD adopted has been
    /// joined and found nothing. Either way TBD is missing both halves of a
    /// site and may invent neither: a made-up display name is an identity peers
    /// would go on to address, and a made-up `cwd` is a directory that does not
    /// exist here. The caller counts the handle as unmirrored and publishes
    /// nothing, so nothing addresses it.
    ///
    /// Nothing retries on a timer, and nothing needs to: a `peer` line is
    /// idempotent and complete, one is written whenever anything about that
    /// session changes, and the whole roster is re-announced after the next
    /// `hello` — so a session TBD adopts later sites on the next line for it.
    private func resolveSite(for peer: PeerBridgePeer) async -> ShadowPeerSite? {
        guard let sessionID = peer.sessionID else { return nil }
        return await siteResolver.site(forProviderSessionID: sessionID)
    }

    /// Deliver one frame from a remote session into the local session it names.
    ///
    /// Two lookups and neither has a fallback. `to` must be a handle TBD minted
    /// for a local session; `from` must be a handle TBD was given and published
    /// a shadow for. A miss on either is a drop, never a guess.
    private func deliverInbound(_ message: PeerBridgeMessage) async {
        guard let local = localPeers[message.to] else {
            drops.record(.unknownHandle)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) on \
                \(self.provider, privacy: .public): its addressee is not a handle TBD announced
                """)
            return
        }
        guard let shadow = shadows[message.from] else {
            drops.record(.unknownHandle)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) on \
                \(self.provider, privacy: .public): its sender is not a shadow TBD published, so \
                it cannot be attributed
                """)
            return
        }

        // The reply path, and the address stamped into the attribution: the
        // shadow's own local socket. Writing to it reaches the helper, which
        // sends the answer back out over the link. Nothing derived from the
        // wire appears here.
        let address = "uds:\(shadow.helper.socketPath)"
        let stamped = ShadowPeerAttribution.stamp(
            content: message.content, senderAddress: address, senderName: shadow.name,
            mode: grantedMode)
        let frame = ShadowPeerAgentFrame(
            from: address, content: stamped, messageID: mintAgentMessageID())

        let payload: Data
        do {
            payload = try frame.encoded()
        } catch {
            drops.record(.malformed)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public): its content would not encode \
                into an agent frame: \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        guard payload.count <= PeerBridgeFrameCodec.maxFrameBytes else {
            drops.record(.oversized)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public): the composed agent frame is \
                \(payload.count, privacy: .public) bytes, over the \
                \(PeerBridgeFrameCodec.maxFrameBytes, privacy: .public)-byte cap
                """)
            return
        }

        do {
            try await delivery.deliver(payload, toSocketPath: local.socketPath)
            shadowPeerLogger.debug("""
                delivered message \(message.id, privacy: .public) from \
                \(shadow.name, privacy: .public) to \(local.name, privacy: .public)
                """)
        } catch {
            drops.record(.deliveryFailed)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) for \
                \(local.name, privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// Diff the provider's claimed inventory against what TBD asked it to
    /// publish. TBD cannot see a host it has no access to, so this difference
    /// is the whole of the far half's observable hygiene.
    private func applyInventory(_ handles: [String]) {
        let claimed = Set(handles)
        let asked = Set(localPeers.keys)
        inventorySurplus = claimed.subtracting(asked).sorted()
        inventoryMissing = asked.subtracting(claimed).sorted()
        guard !inventorySurplus.isEmpty || !inventoryMissing.isEmpty else { return }
        shadowPeerLogger.error("""
            \(self.provider, privacy: .public) peer inventory diverges: \
            \(self.inventorySurplus.count, privacy: .public) published that TBD never asked for, \
            \(self.inventoryMissing.count, privacy: .public) asked for that it does not publish
            """)
    }

    // MARK: - Outbound from a helper

    /// One line a helper wrote on its stdout: a local session's message,
    /// addressed to the shadow that helper stands for.
    ///
    /// The helper hands up the sender's **real** `uds:` address, because that
    /// hop is inside the trust boundary and it is what Claude Code's own frame
    /// carries. Rewriting it to a handle here is what keeps raw socket paths
    /// off the wire.
    ///
    /// **Attributed by the identity of the process that wrote it, not by the
    /// handle it was written under.** A line is decoded against its shadow's
    /// negotiated protocol and forwarded under its shadow's name, and this
    /// design refuses to let anyone else choose that attribution — so a line
    /// from a helper that is no longer the one published under `handle` is
    /// counted as loss rather than credited to the process that replaced it.
    /// The stream buffers, so a dead helper's last lines can arrive after its
    /// replacement took the handle.
    ///
    /// Not `private` for the reason `helperStreamEnded` gives below.
    func helperEmitted(_ line: String, from handle: String, pid: pid_t) async {
        guard let shadow = currentShadow(handle: handle, pid: pid) else {
            drops.record(.helperGone)
            return
        }
        switch PeerBridgeFrameCodec.decode(
            line: line, negotiatedProtocol: shadow.peerProtocol
        ) {
        case .skipped(let skip):
            shadowPeerLogger.debug("""
                skipped a line from shadow \(handle, privacy: .public): \
                \(skip.localizedDescription, privacy: .public)
                """)
        case .rejected(let rejection):
            drops.record(Self.dropReason(for: rejection))
            shadowPeerLogger.error("""
                dropped a line from shadow \(handle, privacy: .public): \
                \(rejection.localizedDescription, privacy: .public)
                """)
        case .frame(let frame):
            guard case .message(let message) = frame else {
                shadowPeerLogger.debug("""
                    ignored a \(frame.kind.rawValue, privacy: .public) line from shadow \
                    \(handle, privacy: .public); a helper's stdout carries messages
                    """)
                return
            }
            await forwardOutbound(message, from: shadow)
        }
    }

    private func forwardOutbound(_ message: PeerBridgeMessage, from shadow: Shadow) async {
        // A helper is answerable for exactly one shadow; a frame it addresses
        // anywhere else is not something it was given the right to say.
        guard message.to == shadow.handle else {
            drops.record(.unknownHandle)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public): shadow \
                \(shadow.handle, privacy: .public) addressed \(message.to, privacy: .public), \
                which is not itself
                """)
            return
        }
        guard let senderHandle = localHandlesByAddress[message.from] else {
            drops.record(.unknownHandle)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) to \
                \(shadow.name, privacy: .public): its sender is not a session TBD announced on \
                this link, so it has no handle and its address must not travel
                """)
            return
        }

        // **The last check before the content leaves the machine, and the one
        // that trusts nothing outside this actor.** `from` is rewritten to a
        // handle above, so the only way a socket path reaches the wire now is
        // inside `content` — which is forwarded byte-verbatim, and whose
        // sender-composed attribution wrapper (the sender's socket, the name it
        // chose for itself, the permission class it claims) was removed a hop
        // earlier by a strip anchored on that wrapper's exact opening element.
        // A leading newline, a renamed element or a reshaped wrapper turns that
        // strip into a silent no-op. "Raw socket paths never travel" is
        // structural, so it does not get to rest on one unverified prefix in
        // another module.
        //
        // A guard, deliberately, and not a second stripper: re-parsing content
        // that already defeated one parser is how a half-repaired frame arrives
        // looking valid while saying something the sender did not. The frame is
        // dropped whole and counted, so a regression in the strip surfaces in
        // `tbd peer list` instead of on the network.
        guard !message.content.contains(socketDirectoryPath) else {
            drops.record(.unstrippedAddress)
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) to shadow \
                \(shadow.handle, privacy: .public): its content still names the local peer \
                socket directory, so the sender's own attribution was not stripped and a socket \
                path would have reached the wire
                """)
            return
        }

        let outbound = PeerBridgeFrame.message(PeerBridgeMessage(
            id: message.id, to: shadow.handle, from: senderHandle, content: message.content))
        do {
            try await link.send(outbound)
            shadowPeerLogger.debug("""
                forwarded message \(message.id, privacy: .public) to shadow \
                \(shadow.handle, privacy: .public)
                """)
        } catch {
            drops.record(Self.dropReason(forSendFailure: error))
            shadowPeerLogger.error("""
                dropped message \(message.id, privacy: .public) to shadow \
                \(shadow.handle, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// Every way a send can fail keeps its own count.
    ///
    /// **Collapsing them would destroy the diagnosis.** "The link is down" and
    /// "the link is up and not draining" call for opposite investigations, and
    /// a truncated write is a corrupted connection rather than lost traffic. An
    /// error this build does not recognise falls back to `linkDown`, which is
    /// the honest reading of "the send did not happen and we cannot say more".
    private static func dropReason(forSendFailure error: any Error) -> ShadowPeerDropReason {
        switch error {
        case let rejection as PeerBridgeFrameRejection:
            return dropReason(for: rejection)
        case let failure as PeerLinkSendFailure:
            switch failure {
            case .linkDown: return .linkDown
            case .wouldBlock: return .linkWouldBlock
            case .writeFailed: return .linkWriteFailed
            case .truncated: return .linkTruncated
            case .notOutbound: return .notOutbound
            }
        case is ShadowPeerHelperError:
            return .helperGone
        default:
            return .linkDown
        }
    }

    private static func dropReason(
        for rejection: PeerBridgeFrameRejection
    ) -> ShadowPeerDropReason {
        switch rejection {
        case .oversized: return .oversized
        case .malformed, .protocolMismatch: return .malformed
        }
    }

    // MARK: - The local roster's half of the table

    /// Mint (or return) the handle for one local session, and bind it privately
    /// to that session's real socket. `LocalPeerHandleRegistry`.
    ///
    /// Called by the roster watcher before it announces the session on this
    /// link: the handle it gets back is what goes on the `peer` line, and the
    /// path stays here. **Minting and resolving have to be the same table** —
    /// an inbound frame is delivered by looking its `to` up among the handles
    /// this method minted, so a roster that kept its own would leave every
    /// inbound frame resolving to nothing.
    ///
    /// Idempotent on the socket path: a `peer` line is a complete statement
    /// re-sent whenever anything about a session changes, and a handle that
    /// churned on a status change would strand every peer already told about
    /// it.
    @discardableResult
    public func handle(forLocalPeerAt socketPath: String, name: String) -> String {
        let address = "uds:\(socketPath)"
        if let existing = localHandlesByAddress[address] {
            return existing
        }
        let handle = mintHandle()
        localHandlesByAddress[address] = handle
        localPeers[handle] = LocalPeer(handle: handle, socketPath: socketPath, name: name)
        return handle
    }

    /// Forget one local session. Returns the handle it held so the caller can
    /// write the matching `peer-gone`, or nil when it was never announced.
    @discardableResult
    public func withdrawLocalPeer(at socketPath: String) -> String? {
        let address = "uds:\(socketPath)"
        guard let handle = localHandlesByAddress.removeValue(forKey: address) else { return nil }
        localPeers.removeValue(forKey: handle)
        return handle
    }

    // MARK: - Link state

    /// **Link down takes every shadow with it.**
    ///
    /// Not "stops answering": a listening socket cannot decline, so a shadow
    /// left bound while the link is down accepts every message sent to it,
    /// reports success, and discards them. Closing and unlinking the listener
    /// is what makes a sender see `ECONNREFUSED` — the same failure a session
    /// that exited gives — and what makes `ListAgents`' connect-and-drop probe
    /// delist the row.
    ///
    /// Both halves of the handle table go with it. A handle names one session
    /// for the life of one connection and means nothing outside it, so nothing
    /// is carried across; the next `hello` re-announces the whole roster, the
    /// way `events` resyncs with a snapshot rather than a cursor.
    public func linkStateChanged(to state: PeerLinkState) async {
        switch state {
        case .up:
            shadowPeerLogger.info(
                "peer link \(self.provider, privacy: .public) is up; awaiting hello")
        case .down:
            let count = shadows.count
            // Bumped BEFORE the teardown awaits anything, so an `applyPeer`
            // already suspended on a spawn sees the new generation the moment
            // it resumes, whichever order the two finish in.
            linkGeneration += 1
            await tearDownAllShadows(because: "the link went down")
            localPeers.removeAll()
            localHandlesByAddress.removeAll()
            unmirrored.removeAll()
            inventorySurplus = []
            inventoryMissing = []
            remoteOrigin = nil
            shadowPeerLogger.info("""
                peer link \(self.provider, privacy: .public) went down; unpublished \
                \(count, privacy: .public) shadow(s) and forgot every handle
                """)
        }
    }

    /// Tear everything down and return only once it is gone. Called on daemon
    /// shutdown; an actor cannot do this from `deinit`.
    public func shutdown() async {
        await tearDownAllShadows(because: "the daemon is shutting down")
        localPeers.removeAll()
        localHandlesByAddress.removeAll()
    }

    /// Idempotent, and it has to be: a short write is fatal to the connection,
    /// so an ordinary send failure produces a `.down` that can land while a
    /// previous teardown is still running. Each shadow leaves the table
    /// synchronously, before anything is awaited, so a second pass sees an
    /// already-empty table and no helper is ever terminated twice.
    private func tearDownAllShadows(because reason: String) async {
        let handles = shadows.keys.sorted()
        for handle in handles {
            await withdrawShadow(handle: handle, because: reason)
        }
    }

    /// The reader task's one and only continuation: the helper behind `handle`
    /// closed its stdout, so that process is gone and the shadow it stood for
    /// must go with it.
    ///
    /// **Keyed on the pid, not on the handle, and that is the whole of it.**
    /// This runs after an actor hop the reader has no control over, and
    /// `shadows[handle]` seconds later need not be the shadow this reader was
    /// reading: a handle belongs to the far side, which may retire one and
    /// announce the same string again over a link that never dropped. A
    /// completion that keyed on the handle alone would then withdraw a helper
    /// spawned after it died — terminating a live shadow while the far side
    /// went on addressing the handle, every frame dropping as an unknown one
    /// until the provider re-announced. `Task.isCancelled` cannot stand in for
    /// this check: it is read before the hop, so a `cancel()` arriving during
    /// the hop is never observed.
    ///
    /// A pid that no longer matches means somebody else already owns the entry
    /// and has already dealt with this process, so there is nothing to do.
    /// Withdrawing twice is separately harmless — `withdrawShadow` no-ops on an
    /// entry that is already gone — so this needs no guard of its own for that.
    ///
    /// **Not `private`, and this is the only reason**: the two interleavings
    /// this and `helperEmitted` exist to survive both need a reader to reach
    /// the actor *after* a replacement was installed, and no test can order
    /// that on demand — the old cancellation check was read before the hop, a
    /// window a few instructions wide. `ShadowPeerManagerTests` builds the
    /// state through the manager's real paths and then calls the reader's own
    /// entry point; calling `withdrawShadow` instead would bypass the guard
    /// under test and prove nothing.
    func helperStreamEnded(handle: String, pid: pid_t) async {
        guard currentShadow(handle: handle, pid: pid) != nil else { return }
        await withdrawShadow(handle: handle, because: "its helper exited on its own")
    }

    /// Unpublish one shadow: tell the helper it is finished, stop reading it,
    /// and make sure the process is gone before returning.
    ///
    /// The `peer-gone` control frame is a courtesy that buys a better log line
    /// on the helper's side; `terminate()` is what actually guarantees the
    /// process is gone, and it does not depend on the frame having landed.
    ///
    /// It does **not** guarantee the socket and record are unlinked. Those go
    /// with the helper's own `defer`s, which stdin EOF and `SIGTERM` reach and
    /// `SIGKILL` does not — so `terminate()` reports which happened and
    /// `retireRow` decides the row's fate on that answer.
    private func withdrawShadow(handle: String, because reason: String) async {
        // Cleared first and unconditionally, because a handle in `unmirrored`
        // is by definition a handle that never reached `shadows` — it failed to
        // site, so no helper was ever spawned for it. Doing this after the
        // guard below would mean a `peer-gone` for such a handle returned
        // without ever clearing it, and `tbd peer list` would go on warning
        // about a remote session retired long ago until the link dropped.
        unmirrored.remove(handle)
        guard let shadow = shadows.removeValue(forKey: handle) else { return }
        shadow.reader?.cancel()
        try? await shadow.helper.send(.peerGone(handle: handle))
        let termination = await shadow.helper.terminate()
        await retireRow(
            handle: shadow.handle, pid: shadow.helper.pid, after: termination)
        shadowPeerLogger.info("""
            unpublished shadow \(shadow.name, privacy: .public) \
            (\(handle, privacy: .public)) because \(reason, privacy: .public)
            """)
    }

    /// Retire the whitelist row **only when the helper cleaned up after
    /// itself**, and leave it for the sweep otherwise.
    ///
    /// The row is the only recognition TBD has: a shadow's record carries no
    /// field Claude Code does not define, and both file artifacts sit in
    /// directories every session on the machine writes into, so a path proves
    /// nothing. A `SIGKILL`ed helper runs no `defer`, which leaves its socket
    /// and record on disk — and retiring the row in that state would delete the
    /// entry naming them while the reconciler is forbidden from finding them by
    /// inference. Unreclaimable, permanently, by construction.
    ///
    /// **Keeping the row rather than unlinking the two paths from here** is the
    /// reconciliation-over-rollback doctrine (root `CLAUDE.md`, "Every durable
    /// external resource needs a named reconciler"), and it is also the only
    /// correct choice on the facts: `kill(2)` returns before the kernel has
    /// reaped the process, so a daemon-side unlink races the helper's own last
    /// record rewrite, and proving ownership before an unlink — the session id
    /// inside the record, a connect that refuses on the socket — is precisely
    /// the logic `ShadowPeerReconciler` already implements. The shadow has
    /// already left `shadows`, so it is out of `artifacts()` and out of the
    /// inventory the sweep vouches against; the next pass sees a row nothing
    /// vouches for and reclaims whatever is left of it.
    private func retireRow(
        handle: String, pid: pid_t, after termination: ShadowPeerHelperTermination
    ) async {
        switch termination {
        case .clean:
            await artifactRecorder.forgetPublished(pid: pid)
        case .unclean:
            shadowPeerLogger.error("""
                shadow peer helper \(handle, privacy: .public) (pid \(pid, privacy: .public)) \
                did not exit cleanly, so it ran no cleanup; keeping its whitelist row so \
                ShadowPeerReconciler can reclaim the socket and record it left behind
                """)
        }
    }

    // MARK: - Diagnostics

    /// The three durable artifacts of every live shadow — the whitelist
    /// `ShadowPeerReconciler` reclaims against. A shadow's record carries no
    /// marker of TBD's own (one unknown key makes a record invisible to Claude
    /// Code's loader), so this bookkeeping is the *only* way TBD recognises its
    /// own shadows.
    public func artifacts() -> [ShadowPeerSummary] {
        shadows.keys.sorted().compactMap { handle in
            guard let shadow = shadows[handle] else { return nil }
            return ShadowPeerSummary(
                handle: shadow.handle, name: shadow.name, status: shadow.status,
                pid: shadow.helper.pid, socketPath: shadow.helper.socketPath,
                recordPath: shadow.helper.recordPath,
                remoteSessionID: shadow.remoteSessionID)
        }
    }

    public func snapshot() -> ShadowPeerSnapshot {
        ShadowPeerSnapshot(
            provider: provider,
            origin: remoteOrigin,
            shadows: artifacts(),
            localHandles: localPeers.keys.sorted(),
            unmirroredHandles: unmirrored.sorted(),
            inventorySurplus: inventorySurplus,
            inventoryMissing: inventoryMissing,
            drops: drops)
    }

    /// Frames dropped so far, by reason. `tbd peer list` prints
    /// `dropCounts.summary`.
    public var dropCounts: ShadowPeerDropCounts { drops }
}

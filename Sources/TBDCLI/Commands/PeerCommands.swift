import ArgumentParser
import Foundation
import TBDShared

struct PeerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "peer",
        abstract: "Inspect the cross-session peer registry",
        subcommands: [PeerList.self, PeerMessaging.self]
    )
}

// MARK: - peer messaging

/// The soak switch for remote peer messaging — the single opt-in for shadow
/// peers and for a provider's `messages` stream.
///
/// It lives here rather than under `tbd config set` because the flag is about
/// peers: the command that reports the gate is `tbd peer list`, and the one
/// that moves it should be its sibling under the same noun. It exists at all
/// because a default-off flag with no way to turn it on is enabled only by
/// hand-editing `~/tbd/state.db`, which the project's own rules put out of
/// bounds.
struct PeerMessaging: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messaging",
        abstract: "Enable or disable remote peer messaging (default off)",
        discussion: """
            Remote peer messaging lets a session on this machine address a session \
            on another one: TBD publishes a shadow peer for each remote session a \
            provider announces, and opens the provider's `messages` stream.

            It ships off and is opted into by hand. `tbd peer list` reports the \
            resolved gate, every provider's half of the bridge, and what a listing \
            could not establish.

            \(peerMessagingRestartCaveat)
            """
    )

    @Argument(help: "on or off")
    var value: OnOffArgument

    /// What the command says it did.
    ///
    /// Pure, and separated from the call so the sentence can be read — and
    /// tested — against the branch actually taken. Both branches carry the
    /// restart caveat, because both are subject to it: the gate is read where a
    /// provider's streams are armed, so neither direction moves a bridge that
    /// is already running.
    static func confirmation(value: OnOffArgument) -> String {
        """
        Set remote peer messaging to \(value.rawValue) \
        (config remote_peer_messaging_enabled). \(peerMessagingRestartCaveat)
        """
    }

    mutating func run() async throws {
        try SocketClient().callVoid(
            method: RPCMethod.configSetRemotePeerMessagingEnabled,
            params: ConfigSetPeerMessagingEnabledParams(enabled: value.boolValue))
        print(Self.confirmation(value: value))
    }
}

// MARK: - peer list

struct PeerList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every peer TBD can see, with what stands behind each one",
        discussion: """
            A **peer** is one live Claude Code session another session can address by
            name (docs/cross-session-messaging.md). This lists every one on this
            machine — local and remote alike — and does the join the docs otherwise
            teach a human to do by hand: pull `tbd worktree list --json`, pull
            `tbd terminal list`, and match them on the tmux pane to work out which
            row is which lane.

            The KIND column says what a row turned out to be:

              local          a session TBD spawned; BEHIND names its worktree, pane
                             and terminal.
              shadow         a shadow peer standing in for a session on another
                             machine; BEHIND names the provider session it mirrors.
              external       a peer TBD did not spawn — a plain-terminal `claude`, or
                             a session on a profile TBD does not manage. Still listed:
                             every local session can address it.
              unattributed   the daemon did not answer, so nothing could be joined.

            It keeps working where the pane join cannot reach. A shadow peer carries
            no `tmux` field by design — remote coordinates would look joinable
            against local panes and would join to the wrong terminal — and it carries
            no marker of TBD's either, because one unknown key makes a record
            invisible to every listing. It is therefore recognised the only way it
            can be: by looking its pid up in TBD's own durable shadow-peer ledger,
            which the daemon answers with over `peer.status`.

            One thing this command deliberately does not claim:

            - **No `[ref]`.** Claude Code mints a ref per record and never writes it
              to disk, so no reader of the registry can produce one. Read a ref from
              `ListAgents` inside a session; the session id printed here is the value
              that is actually on disk.

            It also says what it could not establish. A provider that has not declared
            the `messages` capability while the flag is on is named as such — an old
            shim is never invoked, so the feature would otherwise do nothing, silently.

            Orphans are listed, never reclaimed — `ShadowPeerReconciler` owns
            reclamation, and it sweeps against TBD's own bookkeeping rather than
            against the inferences available here.

            Every failure degrades rather than exits: a daemon that is not running,
            a registry that does not exist, and a record that will not decode each
            narrow the answer and say so, because a diagnostic that fails hard is
            useless exactly when it is needed.
            """
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let registry = ShadowPeerRecordStore().sessionsDirectory
        let scan = readPeerRegistry(at: registry)
        let fleet = readPeerListFleet(client: SocketClient())

        let result = composePeerListing(
            registryPath: registry.path,
            scan: scan,
            fleet: fleet,
            socketFilesOnDisk: peerSocketFiles(namedBy: scan.entries),
            procStartForPID: { ProcessStartTime.procStart(pid: $0) },
            socketExists: { FileManager.default.fileExists(atPath: $0) })

        if json {
            // A single object, deliberately outside `VersionedJSONEnvelope`.
            // That envelope carries the printed contract in
            // `docs/capacity-facts.md`, which programs schedule against; this is
            // a diagnostic view over facts that live in the registry and in
            // TBD's own rows, and versioning it would imply a stability promise
            // about somebody else's on-disk format. An encoding failure must
            // still not read as "no peers": name it on stderr and exit nonzero
            // rather than printing nothing at exit 0.
            guard let output = jsonString(result) else {
                FileHandle.standardError.write(Data(
                    "Error: could not encode the peer listing as JSON\n".utf8))
                throw ExitCode.failure
            }
            print(output)
        } else {
            print(renderPeerListing(result))
        }
    }
}

// MARK: - Reading the registry

/// Read every record in one registry directory.
///
/// Never throws: an unreadable directory is an empty scan that says so, and one
/// unreadable record is one skipped record. This is the whole of the command's
/// registry I/O — the composition it feeds touches no filesystem.
func readPeerRegistry(
    at directory: URL, fileManager: FileManager = .default
) -> PeerRegistryScan {
    var scan = PeerRegistryScan()

    let contents: [URL]
    do {
        contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
    } catch {
        scan.directoryUnreadable = true
        return scan
    }

    let decoder = JSONDecoder()
    for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let pid = PeerJoinKeys.pid(fromRecordFilename: url.lastPathComponent) else {
            continue
        }
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(PeerRegistryRecord.self, from: data)
        else {
            scan.malformedFilenames.append(url.lastPathComponent)
            continue
        }
        scan.entries.append(PeerRegistryEntry(pid: pid, record: record))
    }
    return scan
}

/// Every socket file sitting in the directories the records themselves name.
///
/// **The directory is derived, never guessed.** A hard-coded `/tmp/cc-socks`
/// would report a clean bill on a machine that keeps its sockets elsewhere, and
/// would sweep a directory nothing in this listing refers to. With no records
/// there is no directory, and no unclaimed-socket report — which is the honest
/// answer, since nothing was looked at.
///
/// Only `.sock` files are collected. Each live peer also owns a
/// `<pid>.<sha256(messagingSocketPath)>.key` token file in the same tree, and
/// reporting one of those as an unclaimed socket would be a false leak on every
/// run.
func peerSocketFiles(
    namedBy entries: [PeerRegistryEntry], fileManager: FileManager = .default
) -> [String] {
    var directories: Set<String> = []
    for entry in entries {
        guard let path = nonEmptyPeerField(entry.record.messagingSocketPath) else { continue }
        directories.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }

    var files: [String] = []
    for directory in directories.sorted() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            includingPropertiesForKeys: nil)
        else { continue }
        for url in contents where url.lastPathComponent.hasSuffix(".sock") {
            files.append(url.path)
        }
    }
    return files
}

// MARK: - Reading TBD's own rows

/// TBD's worktree and terminal rows, plus the messaging gate.
///
/// The two list calls are the join's inputs, so either one failing makes the
/// whole fleet unreachable: a listing that joined against terminals but not
/// worktrees would name panes with no lanes behind them. The config read is not
/// an input — it only sharpens a warning — so its failure leaves the gate
/// unknown and the listing intact.
func readPeerListFleet(client: SocketClient) -> PeerListFleet {
    guard client.isDaemonRunning else {
        return .unreachable(reason: "the daemon socket is not there")
    }
    do {
        let worktrees: [Worktree] = try client.call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(excludeArchived: true, includeSessionCounts: false),
            resultType: [Worktree].self)
        let terminals: [Terminal] = try client.call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(),
            resultType: [Terminal].self)
        let config = try? client.call(method: RPCMethod.configGet, resultType: Config.self)
        // Also not an input to the join, and also degrading rather than fatal: a
        // daemon that predates `peer.status`, or one that refuses it, leaves
        // every shadow unrecognisable and every link state unknown — which the
        // listing says out loud rather than papering over.
        let bridge = try? client.call(
            method: RPCMethod.peerStatus, resultType: PeerBridgeStatus.self)
        return PeerListFleet(
            reachable: true,
            worktrees: worktrees,
            terminals: terminals,
            remotePeerMessagingEnabled: config?.remotePeerMessagingEnabled,
            bridge: bridge)
    } catch {
        return .unreachable(reason: String(describing: error))
    }
}

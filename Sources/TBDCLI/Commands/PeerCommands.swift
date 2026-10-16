import ArgumentParser
import Foundation
import TBDShared

struct PeerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "peer",
        abstract: "Inspect the cross-session peer registry",
        subcommands: [PeerList.self]
    )
}

// MARK: - peer list

struct PeerList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every peer TBD can see, with what stands behind each one",
        discussion: """
            A **peer** is one live Claude Code session another session can address by
            name (docs/cross-session-messaging.md). This lists every one on this
            machine — local and remote alike — and joins each one to the worktree and
            terminal behind it, work that otherwise means pulling
            `tbd worktree list --json` and `tbd terminal list` and matching rows by
            hand. A terminal is named by the first eight characters of its id, a
            prefix of the id `tbd terminal list` prints; that is the row's identity on
            every transport.

            The KIND column says what a row turned out to be:

              local          a session in a TBD terminal — one TBD spawned, or one
                             started inside a TBD tab; BEHIND names its worktree and
                             terminal, plus the tmux pane on a tmux-transport row.
              shadow         a shadow peer standing in for a session on another
                             machine; BEHIND names the provider session it mirrors.
              external       a peer no join placed in a TBD terminal — a
                             plain-terminal `claude`, or a session on a profile TBD
                             does not manage. Still listed: every local session can
                             address it.
              unattributed   the daemon did not answer, so nothing could be joined.

            A local row is joined to its terminal by the Claude session id TBD captured
            at `SessionStart`, falling back to its tmux pane when none was captured. A
            holder-backed session has no pane; one whose session id TBD has not captured
            — a launcher run in a tab, a `claude` typed at a shell prompt — is joined to
            the tab whose live job it descends from, read from one snapshot of the
            process table. Only descent counts, never a working directory or an
            environment variable. A tab whose own session is joined by session id is not
            handed to a second one, a Claude tab whose session TBD captured is joined only
            by that session, and of two sessions in one tab only the one nearest
            the tab's job is joined. Under --json, `joinedBy` says which join placed a
            row, and `unjoinedReason` says why an external row was not placed. A shadow
            peer carries no `tmux` field by design — remote
            coordinates would look joinable against local panes and would join to the
            wrong terminal — and it carries no marker of TBD's either, because one
            unknown key makes a record invisible to every listing. A shadow is
            therefore recognised the only way it can be: by looking its pid up in
            TBD's own durable shadow-peer ledger, which the daemon answers with over
            `peer.status`.

            One thing this command deliberately does not claim:

            - **No `[ref]`.** Claude Code mints a ref per record and never writes it
              to disk, so no reader of the registry can produce one. Read a ref from
              `ListAgents` inside a session; the session id printed here is the value
              that is actually on disk.

            Remote peer messaging is switched per repository, in the repository's
            committed `tbd.toml`:

              [remote_sessions]
              peer_messaging = true

            The value is `true` or `false`; absent means off, and so does any value
            TBD cannot read. TBD reads the file in the repository's main checkout,
            fresh on every check. A repository with it on gets a shadow peer for
            each of its remote sessions, and its local sessions are announced to the
            providers that run its remote sessions. A provider's `messages` stream
            opens once any repository it runs sessions in has it on.
            \(peerMessagingStreamOpeningNote) This listing names each repository's
            state and any problem with its `tbd.toml`.

            It also says what it could not establish. A provider that has not declared
            the `messages` capability while a repository has peer messaging on is named
            as such — an old shim is never invoked, so the feature would otherwise do
            nothing, silently.

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
            // One read for the whole listing: the descent join walks it for
            // every record, and every pid it compares was seen at one instant.
            processes: ProcessTableSnapshot.read(),
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

/// TBD's worktree and terminal rows, plus the bridge's own status.
///
/// The two list calls are the join's inputs, so either one failing makes the
/// whole fleet unreachable: a listing that joined against terminals but not
/// worktrees would name panes with no lanes behind them.
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
            bridge: bridge)
    } catch {
        return .unreachable(reason: String(describing: error))
    }
}

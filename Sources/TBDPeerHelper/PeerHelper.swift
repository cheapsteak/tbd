import Darwin
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeerHelper")

// MARK: - Signal plumbing

/// The write end of the self-pipe a signal handler pokes.
///
/// A signal handler may call only async-signal-safe functions, which rules out
/// unlinking a record or writing a log line from inside one. The classic answer
/// is this: the handler does nothing but `write(2)` one byte, and the ordinary
/// `poll(2)` loop — which is already watching stdin and the listener — wakes on
/// that byte and shuts down through the same path every other exit takes. So
/// `SIGTERM` reaches exactly the same cleanup as stdin EOF.
///
/// **That claim holds only because both ends of the pipe are `O_NONBLOCK`.**
/// `run()` sets the flag, and `drain(fd:)` depends on it: this process holds the
/// write end open for its whole life, so a blocking read on an empty pipe never
/// returns, and Darwin's `signal(3)` installs handlers with `SA_RESTART`, so a
/// later signal restarts that read rather than failing it with `EINTR`. A
/// blocking read end therefore parks the helper inside its own shutdown path
/// with the socket still bound and the record still published — a peer that
/// answers every `connect()` and delivers nothing, which is the one failure
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Failure
/// semantics") this design exists to prevent. The write end is non-blocking for
/// the mirror-image reason: a full pipe must fail the handler's `write(2)`
/// rather than park a signal handler.
nonisolated(unsafe) private var signalPipeWriteFD: Int32 = -1

/// Async-signal-safe by construction: one `write(2)`, no allocation, no
/// Foundation, no locks.
private func peerHelperSignalHandler(_ received: Int32) {
    var byte = UInt8(truncatingIfNeeded: received)
    _ = Darwin.write(signalPipeWriteFD, &byte, 1)
}

// MARK: - Entry point

/// `main.swift`'s whole body, factored out so the logger and the helper can be
/// ordinary file-scope declarations rather than top-level code (which Swift 6
/// isolates to the main actor).
enum PeerHelperMain {
    static func run(arguments: [String], environment: [String: String]) -> Int32 {
        let options: PeerHelperOptions
        do {
            options = try PeerHelperOptions.parse(
                arguments: arguments, environment: environment)
        } catch {
            let message = "TBDPeerHelper: \(error.localizedDescription)\n\n"
                + PeerHelperOptions.usage + "\n"
            FileHandle.standardError.write(Data(message.utf8))
            logger.error("""
                shadow peer helper refused its invocation: \
                \(error.localizedDescription, privacy: .public)
                """)
            return 2
        }
        return PeerHelper(options: options).run()
    }
}

// MARK: - The helper

/// One shadow peer: one process, one socket, one record, filed under this
/// process's own real pid in the local `darwin` domain.
///
/// **One process per shadow is forced, not preferred.** The record's pid is
/// parsed from its *filename*, so one process cannot publish several valid
/// records; and a record filed under a pid that does not own its socket would
/// depend on behavior nobody has explained.
/// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Shadow peer
/// lifecycle".)
///
/// **The load-bearing cleanup mechanism is stdin EOF.** The kernel closes that
/// descriptor even when the daemon is `SIGKILL`ed, so a dead daemon means dead
/// helpers within milliseconds — which is the only cleanup path that survives
/// the daemon losing the chance to run any code at all. Claude Code's reaper is
/// the backstop for unclean exits, not the mechanism.
///
/// Single-threaded on purpose. Everything the helper does — control frames on
/// stdin, connections on its socket, a termination signal — arrives on a
/// descriptor, so one `poll(2)` loop serves all three with no locking, no
/// dispatch queues, and no concurrency for a reviewer to reason about.
final class PeerHelper {
    let options: PeerHelperOptions

    /// How long one inbound connection may hold the loop before its read is
    /// abandoned. Claude Code's transport is connect-write-close, so a healthy
    /// client is done in microseconds; this only bounds a client that connects
    /// and then says nothing. A field rather than a literal so it is adjustable
    /// without hunting for it.
    let connectionReadTimeout: TimeInterval

    /// Chunk size for socket and stdin reads.
    private static let readChunkBytes = 16 * 1024
    /// Backlog for the shadow's listener. Deeper than 1 because the liveness
    /// probe (`ListAgents` connect-and-drop) and a real send can arrive
    /// together, and a refused connect reads as "this peer is gone".
    private static let listenBacklog: Int32 = 16
    /// Permissions on the socket, matching every real session's `0600`.
    private static let socketPermissions: mode_t = 0o600
    /// Permissions on the socket directory, matching `/tmp/cc-socks`'s `0700`.
    private static let socketDirectoryPermissions = 0o700

    /// The record this helper publishes. **This process is its single writer**
    /// — nothing else in TBD may touch it — so it is plain mutable state on a
    /// single-threaded object rather than anything guarded.
    private var record: ShadowPeerRecord?
    /// Un-newlined bytes carried over from a previous stdin read.
    private var stdinPending = Data()
    /// Frames dropped, by reason. Loss is never reported to a sender — the
    /// channel has no reply path — so it is logged and counted instead.
    private var droppedFrames = 0

    init(options: PeerHelperOptions, connectionReadTimeout: TimeInterval = 2) {
        self.options = options
        self.connectionReadTimeout = connectionReadTimeout
    }

    func run() -> Int32 {
        let pid = getpid()

        // The record must describe a process that genuinely exists. If the
        // kernel will not tell us when this process started we cannot compose
        // an honest record, and a fabricated `procStart` is exactly the value
        // the recycled-pid ghost check exists to catch — so refuse rather than
        // guess.
        guard let procStart = ProcessStartTime.procStart(pid: pid) else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not read \
                its own start time; refusing to publish a record it cannot stand behind
                """)
            return 1
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not create \
                its signal pipe: \(String(cString: strerror(errno)), privacy: .public)
                """)
            return 1
        }
        let signalReadFD = pipeFDs[0]
        signalPipeWriteFD = pipeFDs[1]
        // Non-blocking on both ends, and the read end's flag is load-bearing:
        // see `signalPipeWriteFD`'s doc comment. A failure to set it is fatal
        // rather than tolerated, because the shape it produces — a helper that
        // wedges on its way out, still bound and still published — is worse
        // than one that never starts.
        for end in [signalReadFD, signalPipeWriteFD] {
            let flags = fcntl(end, F_GETFL)
            guard flags >= 0, fcntl(end, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) could not make \
                    its signal pipe non-blocking: \
                    \(String(cString: strerror(errno)), privacy: .public)
                    """)
                Darwin.close(signalReadFD)
                Darwin.close(signalPipeWriteFD)
                signalPipeWriteFD = -1
                return 1
            }
        }
        defer {
            Darwin.close(signalReadFD)
            Darwin.close(signalPipeWriteFD)
            signalPipeWriteFD = -1
        }
        // A stdout write to a daemon that has gone away must surface as EPIPE
        // on the write, not as a signal that kills the process before it can
        // unlink anything.
        signal(SIGPIPE, SIG_IGN)
        for received in [SIGTERM, SIGINT, SIGHUP] {
            signal(received, peerHelperSignalHandler)
        }

        let socketPath = options.socketDirectory
            .appendingPathComponent("\(pid).sock").path
        guard let listenFD = bindListener(at: socketPath) else { return 1 }
        // Unlinked on **every** return from here down, including the signal
        // path: a listening socket cannot decline, so a shadow that stops being
        // reachable must stop existing. Leaving it bound would report success
        // to every sender forever.
        defer {
            Darwin.close(listenFD)
            _ = unlink(socketPath)
        }

        let store = ShadowPeerRecordStore(sessionsDirectory: options.sessionsDirectory)
        let published = ShadowPeerRecord(
            pid: pid,
            procStart: procStart,
            messagingSocketPath: socketPath,
            name: options.name,
            status: options.status,
            peerProtocol: options.peerProtocol,
            cwd: options.cwd,
            sessionID: options.sessionID ?? UUID().uuidString,
            version: options.version)
        do {
            try store.write(published)
        } catch {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not publish \
                its record: \(error.localizedDescription, privacy: .public)
                """)
            return 1
        }
        record = published
        // Declared after the socket's, so it runs first: unpublish the address
        // before closing the door it points at.
        defer {
            do {
                try store.remove(pid: pid)
            } catch {
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) could not \
                    unlink its record: \(error.localizedDescription, privacy: .public)
                    """)
            }
        }

        logger.info("""
            shadow peer helper \(self.options.handle, privacy: .public) published \
            \(self.options.name, privacy: .public) as pid \(pid, privacy: .public) \
            on \(socketPath, privacy: .public)
            """)

        let exitCode = pollLoop(listenFD: listenFD, signalReadFD: signalReadFD, store: store)

        if droppedFrames > 0 {
            logger.info("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped \
                \(self.droppedFrames, privacy: .public) frame(s) over its life
                """)
        }
        return exitCode
    }

    // MARK: - The loop

    private func pollLoop(
        listenFD: Int32, signalReadFD: Int32, store: ShadowPeerRecordStore
    ) -> Int32 {
        while true {
            var fds = [
                pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: signalReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) poll failed: \
                    \(String(cString: strerror(errno)), privacy: .public)
                    """)
                return 1
            }

            if fds[2].revents != 0 {
                drain(fd: signalReadFD)
                logger.info("""
                    shadow peer helper \(self.options.handle, privacy: .public) received a \
                    termination signal; unpublishing
                    """)
                return 0
            }

            if fds[0].revents != 0 {
                switch readStdin(store: store) {
                case .keepRunning:
                    break
                case .endOfFile:
                    // The daemon is gone — cleanly, or `SIGKILL`ed, which the
                    // kernel makes indistinguishable from here on purpose.
                    logger.info("""
                        shadow peer helper \(self.options.handle, privacy: .public) saw stdin \
                        close; unpublishing
                        """)
                    return 0
                case .withdrawn:
                    logger.info("""
                        shadow peer helper \(self.options.handle, privacy: .public) was \
                        withdrawn by the far side; unpublishing
                        """)
                    return 0
                case .failed:
                    return 1
                }
            }

            if fds[1].revents & Int16(POLLIN) != 0 {
                acceptAndForward(listenFD: listenFD)
            }
        }
    }

    private enum StdinOutcome {
        case keepRunning
        /// The daemon's end of the pipe is gone.
        case endOfFile
        /// A `peer-gone` line named this shadow: the far side withdrew it while
        /// the daemon is still very much alive. A different fact from EOF, and
        /// worth a different log line, because they call for different
        /// investigation.
        case withdrawn
        case failed
    }

    private func readStdin(store: ShadowPeerRecordStore) -> StdinOutcome {
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
        if count == 0 { return .endOfFile }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return .keepRunning }
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) stdin read failed: \
                \(String(cString: strerror(errno)), privacy: .public)
                """)
            return .failed
        }

        stdinPending.append(contentsOf: chunk[0..<count])
        while let newline = stdinPending.firstIndex(of: 0x0A) {
            let lineBytes = stdinPending[stdinPending.startIndex..<newline]
            stdinPending = Data(stdinPending[stdinPending.index(after: newline)...])
            // Failable rather than lossy: a control line that is not UTF-8 is a
            // line this build cannot act on, and decoding it with replacement
            // characters would turn it into one that parses as something else.
            guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                droppedFrames += 1
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) dropped a \
                    control line that was not valid UTF-8
                    """)
                continue
            }
            if !apply(line: line, store: store) { return .withdrawn }
        }

        // An un-newlined remainder past the frame cap can never become a frame
        // this build would accept, so it is discarded whole rather than grown
        // without bound — the same rule the daemon's own pipe reader follows,
        // at half its threshold.
        if stdinPending.count > PeerBridgeFrameCodec.maxFrameBytes {
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) discarded \
                \(self.stdinPending.count, privacy: .public) un-newlined stdin bytes, over the \
                \(PeerBridgeFrameCodec.maxFrameBytes, privacy: .public)-byte frame cap
                """)
            stdinPending.removeAll(keepingCapacity: false)
        }
        return .keepRunning
    }

    /// Apply one control line. Returns false when the line says this shadow is
    /// finished.
    private func apply(line: String, store: ShadowPeerRecordStore) -> Bool {
        switch PeerBridgeFrameCodec.decode(
            line: line, negotiatedProtocol: options.peerProtocol) {
        case .skipped(let skip):
            logger.debug("""
                shadow peer helper \(self.options.handle, privacy: .public) skipped a line: \
                \(skip.localizedDescription, privacy: .public)
                """)
            return true
        case .rejected(let rejection):
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped a control \
                frame: \(rejection.localizedDescription, privacy: .public)
                """)
            return true
        case .frame(let frame):
            return apply(frame: frame, store: store)
        }
    }

    private func apply(frame: PeerBridgeFrame, store: ShadowPeerRecordStore) -> Bool {
        switch frame {
        case .peer(let peer):
            // A helper is answerable for exactly one shadow. A line about any
            // other handle is the daemon's business, not this process's.
            guard peer.handle == options.handle else { return true }
            republish(name: peer.name, status: peer.status, store: store)
            return true

        case .peerGone(let handle):
            guard handle == options.handle else { return true }
            return false

        case .ping:
            // The link's own liveness is the daemon's to watch: a helper whose
            // daemon has died learns it from stdin closing, which is both
            // faster and impossible to miss.
            return true

        case .hello, .message, .peerInventory:
            // Not a helper's traffic. `message` in particular travels the other
            // way — a frame *addressed to* this shadow is a remote session
            // reaching a local one, which the daemon writes into that local
            // session's own socket without a helper in the path.
            logger.debug("""
                shadow peer helper \(self.options.handle, privacy: .public) ignored a \
                \(frame.kind.rawValue, privacy: .public) line
                """)
            return true
        }
    }

    /// Rewrite the record when, and only when, something in it changed. A
    /// record published once and never updated shows a frozen status forever;
    /// a record rewritten on every keepalive would churn a directory every
    /// session on the machine reads.
    private func republish(name: String, status: String, store: ShadowPeerRecordStore) {
        guard let current = record else { return }
        guard current.name != name || current.status != status else { return }
        let updated = current.withName(name).withStatus(status)
        do {
            try store.write(updated)
            record = updated
        } catch {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not rewrite \
                its record: \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    // MARK: - The socket

    /// Accept one connection, read what it says, and hand it up to the daemon.
    ///
    /// A connection that says nothing is the ordinary case rather than an
    /// error: `ListAgents` probes liveness by connecting and dropping, and that
    /// probe is the whole reason this listener has to exist.
    private func acceptAndForward(listenFD: Int32) {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else {
            if errno != EINTR && errno != EAGAIN && errno != ECONNABORTED {
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) accept failed: \
                    \(String(cString: strerror(errno)), privacy: .public)
                    """)
            }
            return
        }
        defer { Darwin.close(clientFD) }

        var timeout = timeval(
            tv_sec: Int(connectionReadTimeout),
            tv_usec: Int32((connectionReadTimeout - connectionReadTimeout.rounded(.down))
                * 1_000_000))
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        var payload = Data()
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        var oversized = false
        while true {
            let count = Darwin.read(clientFD, &chunk, chunk.count)
            if count > 0 {
                payload.append(contentsOf: chunk[0..<count])
                if payload.count > PeerBridgeFrameCodec.maxFrameBytes {
                    oversized = true
                    break
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }

        if oversized {
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped an inbound \
                message over the \(PeerBridgeFrameCodec.maxFrameBytes, privacy: .public)-byte \
                cap rather than truncating it
                """)
            return
        }
        guard !payload.isEmpty else { return }  // a liveness probe

        forward(payload: payload)
    }

    /// Hand one message from a local session up to the daemon on stdout.
    ///
    /// **What travels is the message *body*, never the agent's frame.**
    /// `PeerBridgeMessage.content` is defined as the thing the delivering side
    /// composes an agent frame *around*, so putting the frame itself there
    /// would mean a conforming provider mirroring TBD's own inbound behavior
    /// handed its session a `<cross-session-message>` whose body is raw JSON.
    /// It would also defeat the design's first trust property outright: the
    /// frame carries `"from":"uds:/tmp/cc-socks/<pid>.sock"` at top level *and*
    /// again inside the sender's own `<cross-session-message …>` wrapper, so a
    /// `content` holding the whole frame smuggles across the wire the very path
    /// the daemon rewrites `from` to hide — along with the local pid the socket
    /// filename embeds and the permission class the sender claimed for itself
    /// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Trust";
    /// `docs/research/2026-08-29-cross-machine-messaging/findings.md` § T1).
    ///
    /// So the body is lifted out of the frame and its opening wrapper is
    /// stripped here, at the first hop, rather than anywhere later. Stripping
    /// is what makes "no raw paths on the wire" true rather than nearly true,
    /// and it costs nothing: attribution is stamped by the *delivering* side
    /// from the handle a frame arrived on, and
    /// `ShadowPeerAttribution.stamp`'s wrap branch composes a fresh wrapper
    /// around a bare body. Only attribution is removed; the body itself passes
    /// byte-verbatim.
    ///
    /// **This hop is inside the trust boundary and the wire is not.** `from` is
    /// still a real `uds:` socket path, because that is the key the daemon
    /// looks the sender up by in the handle table it keeps privately. The
    /// daemon rewrites it to a handle before anything leaves the machine; that
    /// field is the *only* place a path appears on this hop, and it appears
    /// nowhere at all on the next one.
    private func forward(payload: Data) {
        // Failable rather than lossy, and that is the design's rule rather than
        // a style choice: message content passes **byte-verbatim**, so a
        // payload this build cannot read a body out of is dropped and counted
        // rather than forwarded as something the sender did not write. The
        // fallback that suggests itself — forward the raw bytes when the frame
        // will not parse — is exactly the leak above, so there is none.
        guard let inbound = Self.readAgentFrame(payload) else {
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped an inbound \
                message it could not read a body out of; forwarding the raw frame instead would \
                put the sender's socket path on the wire
                """)
            return
        }
        let content = Self.strippedOfSenderAttribution(inbound.body)
        let sender = inbound.sender
        if sender.isEmpty {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) received a message \
                with no sender address; forwarding it unattributed
                """)
        }
        // The id is minted here, at the frame's first hop, so the same string
        // names this message in the helper's log and in the daemon's. It is
        // diagnostic only — nothing acks, retries, or deduplicates on it.
        let id = UUID().uuidString
        let frame = PeerBridgeFrame.message(PeerBridgeMessage(
            id: id, to: options.handle, from: sender, content: content))
        let line: String
        do {
            line = try PeerBridgeFrameCodec.encodeLine(frame)
        } catch {
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped message \
                \(id, privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
            return
        }
        if writeAll(Data(line.utf8), to: STDOUT_FILENO) {
            logger.debug("""
                shadow peer helper \(self.options.handle, privacy: .public) forwarded message \
                \(id, privacy: .public) (\(content.utf8.count, privacy: .public) bytes)
                """)
        } else {
            droppedFrames += 1
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) dropped message \
                \(id, privacy: .public): the daemon's end of stdout is gone
                """)
        }
    }

    // MARK: - Reading the agent's frame

    /// The two things this helper takes out of Claude Code's own message frame,
    /// and the only two: who sent it, and what they wrote.
    struct InboundAgentMessage: Equatable {
        /// The frame's top-level `from` — a real `uds:` address. Local, and the
        /// daemon's key into the handle table; rewritten to a handle before
        /// anything leaves the machine.
        let sender: String
        /// `message.content`, exactly as it arrived: the sender's own
        /// `<cross-session-message …>` wrapper still around it.
        let body: String
    }

    /// Read the sender and the body out of one agent frame.
    ///
    /// `JSONSerialization` rather than a typed decode because the frame's shape
    /// belongs to the agent, not to this contract — a `Decodable` mirror of it
    /// here would be a second copy of somebody else's schema, and would reject
    /// a frame that grew a field. Only the two fields named above are read; the
    /// rest is neither interpreted nor carried.
    ///
    /// Nil when the payload is not a JSON object, or carries no string body:
    /// both are frames this build cannot forward, and neither is a reason to
    /// fall back to shipping the raw bytes.
    static func readAgentFrame(_ payload: Data) -> InboundAgentMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              let message = dictionary["message"] as? [String: Any],
              let body = message["content"] as? String
        else { return nil }
        let sender = (dictionary["from"] as? String) ?? ""
        return InboundAgentMessage(sender: sender, body: body)
    }

    // MARK: - Stripping the sender's attribution

    /// The wrapper's element name, without its closing angle bracket.
    ///
    /// **Deliberately a second copy of `ShadowPeerAttribution`'s constants and
    /// tag scanner, not a shared one.** The helper links `TBDShared` and
    /// nothing else, by design (see `Package.swift`), and the two halves sit on
    /// opposite ends of the same contract the way `PeerHelperOptions.parse` and
    /// `ShadowPeerHelperInvocation.arguments` already do: each is pinned by a
    /// test on its own side. Widening the helper's dependency on the daemon to
    /// share two string literals would cost more than the duplication does.
    static let crossSessionOpenTagName = "<cross-session-message"
    /// The wrapper's closing tag.
    static let crossSessionCloseTag = "</cross-session-message>"

    /// One message body with the sender's own attribution wrapper removed.
    ///
    /// The wrapper is composed by the *sender's* client, so it names the
    /// sender's socket path, the name it chose for itself, and the permission
    /// class it claims — none of which may cross the machine boundary
    /// (`docs/specs/2026-08-29-remote-peer-messaging-design.md` § "Trust"). The
    /// receiving side stamps a wrapper of its own from the handle the frame
    /// arrived on, so removing this one loses nothing and is what makes "raw
    /// socket paths never travel" true of `content` as well as of `from`.
    ///
    /// The opening tag and its matching closing tag are removed **together**,
    /// leaving a bare body: that is the shape `ShadowPeerAttribution.stamp`'s
    /// wrap branch expects, and it reproduces the exact framing a real local
    /// send composes. A body with no wrapper is returned untouched, and one
    /// whose closing tag is missing keeps whatever it has after the opening
    /// one. Nothing else is trimmed, re-indented or normalised, and the
    /// interior is never searched — a body quoting a `</cross-session-message>`
    /// of its own keeps it, because only a *trailing* one is paired with the
    /// opening tag that was actually removed.
    static func strippedOfSenderAttribution(_ body: String) -> String {
        guard let end = openTagEnd(in: body) else { return body }
        var stripped = String(body[body.index(after: end)...])
        // The newline Claude Code's composer writes after the opening tag, and
        // the one before the closing tag. Removed only when present, and only
        // one each: they are framing, not content.
        if stripped.hasPrefix("\n") { stripped.removeFirst() }
        if stripped.hasSuffix(Self.crossSessionCloseTag) {
            stripped.removeLast(Self.crossSessionCloseTag.count)
            if stripped.hasSuffix("\n") { stripped.removeLast() }
        }
        return stripped
    }

    /// The index of the `>` that closes a leading opening tag, or nil when the
    /// content does not begin with one.
    ///
    /// Quote-aware on purpose: an attribute value may legally contain `>`, and
    /// a naive `firstIndex(of: ">")` would split inside one and spill the tail
    /// of the sender's tag — socket path included — into the body this function
    /// exists to clean.
    static func openTagEnd(in content: String) -> String.Index? {
        guard content.hasPrefix(Self.crossSessionOpenTagName) else { return nil }
        var index = content.index(
            content.startIndex, offsetBy: Self.crossSessionOpenTagName.count)
        // `<cross-session-messageX` is a different element, not this one.
        guard index < content.endIndex else { return nil }
        let following = content[index]
        guard following == ">" || following.isWhitespace else { return nil }
        var quoted = false
        while index < content.endIndex {
            let character = content[index]
            if character == "\"" {
                quoted.toggle()
            } else if character == ">" && !quoted {
                return index
            }
            index = content.index(after: index)
        }
        return nil
    }

    /// Bind and listen on `path`.
    ///
    /// The path is derived from **this process's own pid**, so an existing file
    /// there is a dead predecessor's socket and unlinking it reclaims nothing
    /// that is in use. That is the only inference this code makes about a
    /// socket file, and it is bounded to a path no live process can own: any
    /// broader "unlink anything with nothing listening" would race a real
    /// session between `bind()` and `listen()`.
    private func bindListener(at path: String) -> Int32? {
        let fileManager = FileManager.default
        let directory = options.socketDirectory
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: Self.socketDirectoryPermissions])
            } catch {
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) could not create \
                    \(directory.path, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return nil
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not create a \
                socket: \(String(cString: strerror(errno)), privacy: .public)
                """)
            return nil
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < sunPathSize else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) socket path \
                \(path, privacy: .public) is longer than sun_path allows
                """)
            Darwin.close(fd)
            return nil
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &addr.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        var result = withUnsafePointer(to: &addr) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, addressLength)
            }
        }
        if result < 0 && errno == EADDRINUSE {
            // A file at this path is a dead predecessor's socket, because the
            // path names *our own* pid. Nothing live can be listening on it.
            _ = unlink(path)
            result = withUnsafePointer(to: &addr) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.bind(fd, generic, addressLength)
                }
            }
        }
        guard result == 0 else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not bind \
                \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)
                """)
            Darwin.close(fd)
            return nil
        }

        _ = chmod(path, Self.socketPermissions)

        guard Darwin.listen(fd, Self.listenBacklog) == 0 else {
            logger.error("""
                shadow peer helper \(self.options.handle, privacy: .public) could not listen on \
                \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)
                """)
            Darwin.close(fd)
            _ = unlink(path)
            return nil
        }
        return fd
    }

    // MARK: - Descriptor helpers

    /// Empty the self-pipe of every byte a signal handler has poked into it.
    ///
    /// **Terminating depends on the read end being `O_NONBLOCK`** — set in
    /// `run()`, explained on `signalPipeWriteFD`. With the flag, an empty pipe
    /// fails the read with `EAGAIN` and this returns; without it, the read
    /// blocks forever and takes the helper's whole shutdown path with it.
    /// `EINTR` is the one error worth retrying: everything else means there is
    /// nothing more to read, and the caller is on its way out regardless.
    private func drain(fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 { continue }
            if count < 0 && errno == EINTR { continue }
            return
        }
    }

    /// Write every byte or report failure. A short write is normal on a pipe and
    /// silently losing its tail would corrupt the next frame on the stream.
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                logger.error("""
                    shadow peer helper \(self.options.handle, privacy: .public) could not write \
                    to the daemon: \(String(cString: strerror(errno)), privacy: .public)
                    """)
                return false
            }
            return true
        }
    }
}

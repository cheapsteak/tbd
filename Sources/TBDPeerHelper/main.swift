import Foundation

// TBDPeerHelper — one process per shadow peer.
//
// The daemon spawns one of these for each remote session it mirrors. It binds a
// socket in the peer-socket directory, publishes a record under its own real
// pid, and is a genuine peer by the same rules any Claude Code session follows:
// a record plus a socket that answers a connect. It takes control frames from
// the daemon on stdin, is the single writer of its own record, and exits the
// moment stdin reaches EOF — which the kernel guarantees even when the daemon
// is SIGKILLed, so a dead daemon means dead helpers within milliseconds.
//
// Everything of substance lives in PeerHelper.swift; this file is the entry
// point, kept to one statement so the rest can be ordinary declarations rather
// than main-actor-isolated top-level code.
//
// See docs/specs/2026-08-29-remote-peer-messaging-design.md § "Shadow peer
// lifecycle".

exit(PeerHelperMain.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment))

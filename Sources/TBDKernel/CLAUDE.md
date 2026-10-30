# TBDKernel

The contract the helper programs share with the daemon: the holder's wire protocol, framing, rendezvous paths and creation lock, the descriptor channel, the peer helper's frame codec and shadow peer record, and the process helpers and paths those need. `TBDHolder` and `TBDPeerHelper` depend on this module alone. Design: [`docs/specs/2026-10-30-helper-kernel-design.md`](../../docs/specs/2026-10-30-helper-kernel-design.md).

- **A declaration goes into the kernel only if a helper program needs it,** directly or through another kernel declaration. Everything else goes into `TBDShared`.
- **The kernel depends on no other module,** first-party or package.
- **The wire shapes stay byte-identical.**
  - For the holder, these are the Codable names and shapes, the rendezvous directory and file names, `HolderRendezvous.sunPathLimit` and `HolderProtocolVersion.busySentinel`. The daemon must work with every holder version that has ever shipped, as the protocol section of [`docs/specs/2026-08-30-pty-holder-session-transport-design.md`](../../docs/specs/2026-08-30-pty-holder-session-transport-design.md) says.
  - For the peer helper, Claude Code's side fixes `PeerBridgeFrameCodec.peerProtocol` and the shape of the shadow peer record.

A file outside the kernel that names a kernel declaration imports `TBDKernel` itself, and its target lists `TBDKernel`; nothing re-exports it.

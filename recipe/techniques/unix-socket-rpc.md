# Unix domain socket + HTTP RPC

## Posture: Make

Standard Unix IPC pattern. SwiftNIO provides the transport layer.

## The problem

The daemon, app, and CLI need to communicate. The protocol must be fast (for real-time state streaming), secure (user-scoped), and debuggable (for development).

## The technique

Dual transport: Unix domain socket at `~/.tbd/sock` (primary, user-scoped permissions) and HTTP on localhost (port stored in `~/.tbd/port`, for debugging with curl). Both use the same JSON-RPC style protocol with newline-delimited messages.

The `state.subscribe` method returns a persistent streaming connection that pushes state deltas as they occur — the app uses this for reactive UI updates.

## Why not alternatives

- **HTTP only:** No Unix socket means no user-scoped permissions out of the box. Localhost HTTP is fine for debugging but shouldn't be the primary transport.
- **gRPC:** Heavy dependency for a single-machine IPC use case. JSON-RPC is simpler and curl-debuggable.
- **XPC:** macOS-only, requires entitlements, harder to debug, no good Swift async story.

## Where this applies

Any daemon + client architecture on a single machine where both performance and debuggability matter.

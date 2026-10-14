# Unix domain socket + HTTP RPC

## Posture: Make

Standard Unix IPC pattern. SwiftNIO provides the transport layer.

## The problem

The daemon, app, and CLI need to communicate. The protocol must be fast (for real-time state streaming), secure (user-scoped), and debuggable (for development).

## The technique

Dual transport: Unix domain socket at `~/tbd/sock` (primary, user-scoped permissions) and HTTP on localhost (port stored in `~/tbd/port`, for debugging with curl). HTTP requests must carry an `X-TBD-Token` header with the contents of `~/tbd/http-token`; requests with an `Origin` header or a `Host` other than the loopback address and port are refused. For example:

```
curl -s -H "X-TBD-Token: $(cat ~/tbd/http-token)" -d '{"method":"daemon.status","params":"{}"}' "http://127.0.0.1:$(cat ~/tbd/port)/rpc"
```

Both use the same JSON-RPC style protocol with newline-delimited messages.

The `state.subscribe` method returns a persistent streaming connection that pushes state deltas as they occur — the app uses this for reactive UI updates.

## Why not alternatives

- **HTTP only:** No Unix socket means no user-scoped permissions out of the box. Localhost HTTP is fine for debugging but shouldn't be the primary transport.
- **gRPC:** Heavy dependency for a single-machine IPC use case. JSON-RPC is simpler and curl-debuggable.
- **XPC:** macOS-only, requires entitlements, harder to debug, no good Swift async story.

## Where this applies

Any daemon + client architecture on a single machine where both performance and debuggability matter.

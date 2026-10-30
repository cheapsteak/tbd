# Unix domain socket RPC

## Posture: Make

Standard Unix IPC pattern. SwiftNIO provides the transport layer.

## The problem

The daemon, app, and CLI need to communicate. The protocol must be fast (for real-time state streaming), secure (user-scoped), and debuggable (for development).

## The technique

One transport: a Unix domain socket at `~/tbd/sock`, scoped to the user by its file permissions. The app, the CLI and the CLI's hooks all speak the same JSON-RPC style protocol over it, one newline-delimited JSON message per request and per response.

The `state.subscribe` method returns a persistent streaming connection that pushes state deltas as they occur — the app uses this for reactive UI updates.

For ad-hoc calls during development, the `tbd` CLI covers the common methods, and any method can be called by hand in one line:

```sh
(echo '{"method":"daemon.status","params":"{}"}'; sleep 1) | nc -U ~/tbd/sock
```

`params` is itself a JSON-encoded string. The `sleep` holds the connection open until the reply arrives: without it, `nc` closes its side as soon as `echo` finishes, the daemon drops the connection before answering, and nothing is printed.

## Why not alternatives

- **A second, HTTP transport for debugging:** a second surface to keep in step with the socket, for calls the CLI and the one-line socket call above already cover.
- **gRPC:** Heavy dependency for a single-machine IPC use case. JSON-RPC is simpler, and a request is one line of JSON any socket client can send.
- **XPC:** macOS-only, requires entitlements, harder to debug, no good Swift async story.

## Where this applies

Any daemon + client architecture on a single machine where both performance and debuggability matter.

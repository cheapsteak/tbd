# Daemon Supervisor Diagnosis (2026-07-21 08:32 Incident)

## Incident Summary

macOS relaunched the app at 08:32. The daemon was dead. The app showed "disconnected" for several minutes before eventually self-healing when the daemon spawned and connected.

## Root Cause Analysis

The app's daemon supervision has three distinct startup paths, and the interaction between them creates a multi-second (or multi-minute) reconnection delay when the daemon is absent on cold launch:

### Path 1: Initial App Launch (AppState.init)
```swift
// AppState.swift lines 728-731
Task {
    await connectAndLoadInitialState()  // ONE attempt via daemonClient.connect()
    startPolling()                       // 2-second reconnect timer
}
```

**Issue**: This background task calls `connectAndLoadInitialState()`, which does a SINGLE call to `daemonClient.connect()`. While that method has internal auto-spawn logic (tries to launch daemon + waits 4 seconds), if it fails, the task continues to `startPolling()` immediately without retrying or ensuring the daemon is running.

### Path 2: DaemonClient Auto-Start (DaemonClient.swift lines 97–126)
```swift
func connect() async -> Bool {
    if tryConnect() { return true }  // Try once
    
    // Auto-start: launch daemon and wait up to 4 seconds
    for attempt in 1...8 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if tryConnect() { return true }
    }
    return false  // Timeout or connect still failed
}
```

**Issue**: The auto-start only waits 4 seconds total. If the daemon spawns successfully but takes longer to bind the socket, this times out and returns false.

### Path 3: Polling Reconnect (AppState.swift lines 1343–1364)
```swift
if !self.isConnected {
    if !FileManager.default.fileExists(atPath: TBDConstants.socketPath) {
        await self.startDaemonAndConnect()  // Socket missing → spawn
    } else {
        let didConnect = await self.daemonClient.connect()  // Socket exists → retry
        if didConnect { ... }
        else if !AppState.pidFilePointsAtLiveDaemon() {
            await self.startDaemonAndConnect()  // Stale socket → respawn
        }
        // else: live daemon but transient failure → just retry
    }
}
```

**Critical Issue**: This polling logic has two related bugs:

1. **Stale Socket Detection Lag**: A reboot often leaves a stale socket file on disk. The socket exists but nobody is listening. The app detects this is stale only AFTER the first `daemonClient.connect()` fails and checks `pidFilePointsAtLiveDaemon()`. This takes a full 2-second poll cycle (or more if the connect itself times out).

2. **Weak Cleanup Coordination**: When `startDaemonAndConnect()` is called to clean up stale artifacts, it removes the pid/socket and spawns the daemon. But it only waits 4 seconds for the socket to appear before calling `connectAndLoadInitialState()` (another single connect attempt). If the daemon is slow to start, the connect fails and we wait another 2 seconds for the next poll tick.

### The Multi-Minute Delay Scenario

1. **08:32**: macOS relaunch, leaves stale socket file
2. **App launches**: `connectAndLoadInitialState()` tries to connect, fails (auto-start times out after 4s)
3. **First poll tick (2s later)**: Socket exists (stale), tries `daemonClient.connect()` → fails
4. **After connect timeout**: Checks `pidFilePointsAtLiveDaemon()` → correctly detects stale pid
5. **Calls `startDaemonAndConnect()`**: Removes artifacts, spawns daemon, waits 4s for socket, calls `connectAndLoadInitialState()` again
6. **If daemon is still slow**: Another 2s wait for next poll tick
7. **Repeat**: Multiple 2–4 second cycles until daemon is fully ready

The cascade happens because each stage (initial launch, first poll, respawn attempt) has a limited timeout and doesn't aggressively wait for daemon readiness.

## Root Cause Summary

**The app's daemon-supervision model is reactive and polling-based, with multiple independent timeout stages. After a cold launch with a dead daemon and stale socket/pid files, the app is slow to detect and correct the situation.**

Key failures:
- Initial launch doesn't ensure daemon is running before marking "initial state loaded"
- Stale socket detection is deferred to a polling cycle
- Daemon spawn + socket-wait has a short timeout with no retry-backoff
- `connectAndLoadInitialState()` is called multiple times but is always a single-attempt connect

## Fix Strategy

Make the app an eager daemon supervisor:

1. **At app launch**: If the daemon is not reachable, spawn it immediately (concurrent with UI, not blocking) and wait aggressively for readiness
2. **On reconnect failure**: When a connect fails and no live daemon is detected, spawn immediately and connect with retry, not a 2-second delay
3. **Cleanup stale artifacts**: Do this as soon as a connect failure is detected, not after checking pid-file liveness
4. **Expected outcome**: Cold launch with dead daemon and stale artifacts → daemon up and app connected in ~1 second, not minutes

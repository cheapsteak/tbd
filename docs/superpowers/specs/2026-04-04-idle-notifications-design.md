# Idle Notifications: Sound + macOS Banners

**Date:** 2026-04-04

## Summary

When a Claude session finishes responding in a non-visible worktree, TBD plays a configurable sound and/or shows a macOS notification banner with the worktree name and truncated response.

## Architecture

```
Claude Code Stop hook
  → reads JSON from stdin (last_assistant_message, stop_reason)
  → calls: tbd notify --type response_complete --message "<truncated>"
  → NotifyCommand resolves worktree via TBD_WORKTREE_ID env var or CWD (PathResolver — already implemented)
  → daemon stores notification in DB, broadcasts StateDelta.notificationReceived
  → app receives delta instantly via persistent subscription socket
  → checks worktree visibility (same logic as unread badge: blue dot / bold)
  → if not visible: plays sound (NSSound) and/or posts macOS notification (UNUserNotificationCenter)
```

The app subscribes to daemon state deltas via a persistent socket connection for real-time notification delivery (see Component 7).

## Components

### 1. Stop Hook Update

The existing `tbd setup-hooks` command installs a Stop hook in Claude Code's `settings.json`. Update the hook command to extract and pass the response message.

**Current hook command:**
```bash
tbd notify --type response_complete 2>/dev/null || true
```

**Updated hook command:**
```bash
MSG=$(jq -r '.last_assistant_message // empty' 2>/dev/null); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true
```

Claude Code passes Stop hook data as JSON on stdin with these fields:
- `last_assistant_message` — full response text
- `stop_reason` — `"end_turn"`, `"max_tokens"`, `"stop_sequence"`, or `"tool_use"`
- `session_id`, `cwd`, `transcript_path`, `permission_mode`, `hook_event_name`

Message truncation happens app-side only (first ~200 chars for notification body). Truncating in the shell with `head -c` risks splitting multi-byte UTF-8 characters.

**Hook migration:** The existing `installHooks` function skips adding a new entry when it finds an existing `tbd notify` hook (`found = true`). This means existing users who already ran `tbd setup-hooks` will keep the old command (without `--message`). Fix: when a matching entry is found but the command string differs, update it in place.

**Files changed:**
- `Sources/TBDCLI/Commands/SetupHooksCommand.swift` — update `tbdNotifyCommand` string + fix migration to update existing entries

### 2. Worktree Resolution (Already Implemented)

`NotifyCommand` already resolves worktree ID from:
1. `--worktree` flag (explicit UUID)
2. `PathResolver` using CWD (matches against daemon's worktree list)

Additionally, set `TBD_WORKTREE_ID` in the tmux environment when TBD creates a terminal, so the hook can pass it explicitly for faster resolution. The CLI checks the env var first, falls back to CWD resolution.

**Note:** `TmuxManager.newWindowCommand` currently does not accept environment parameters. Its signature needs to be extended to support passing env vars (e.g., via tmux `set-environment` or the `-e` flag on `new-window`). This is a non-trivial but straightforward change to the tmux command builder.

**Files changed:**
- `Sources/TBDCLI/Commands/NotifyCommand.swift` — check `TBD_WORKTREE_ID` env var before PathResolver fallback
- `Sources/TBDDaemon/Tmux/TmuxManager.swift` — extend `newWindowCommand` to accept env vars
- Terminal creation code — pass `TBD_WORKTREE_ID` when creating tmux sessions

### 3. App-Side: Sound Playback

Triggered when the app receives a `notificationReceived` delta via its subscription (Component 7):
1. Check if the worktree is visible (same logic as unread badge — selected tab or visible pinned terminal)
2. If not visible and `enableNotificationSounds` is on, play the configured sound

Sound playback via `NSSound`:
- System sounds: `NSSound(named: NSSound.Name("Blow"))` (loads from `/System/Library/Sounds/`)
- Custom sounds: `NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)`

`NSSound.play()` requires the main thread. `NotificationSoundPlayer` must be `@MainActor` (natural since `AppState` is already `@MainActor` and the polling loop runs there).

**Settings:**
- `@AppStorage("enableNotificationSounds")` — Bool, default `true`
- `@AppStorage("notificationSoundName")` — String, default `"Blow"` (system sound name)
- `@AppStorage("notificationSoundCustomPath")` — String, default `""` (custom file path; when non-empty, takes precedence over `notificationSoundName`)

Two keys distinguish system sounds from custom paths: `notificationSoundName` for system sounds, `notificationSoundCustomPath` for user-selected files. If `notificationSoundCustomPath` is non-empty, it's used; otherwise fall back to `notificationSoundName`.

**Files changed:**
- New: `Sources/TBDApp/Services/NotificationSoundPlayer.swift` (`@MainActor`)

### 4. App-Side: macOS Notification Banners

Triggered alongside sound when the app receives a `notificationReceived` delta for a non-visible worktree. When `enableNotifications` is on:

```swift
let content = UNMutableNotificationContent()
content.title = worktree.displayName        // e.g. "20260404-rapid-badger"
content.body = truncatedMessage             // first ~200 chars of Claude response
content.sound = nil                         // sound handled separately via NSSound
```

**Permission request:** On first launch (or when user enables the toggle), call:
```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
```

No `.sound` in authorization — sound is handled independently via `NSSound`, which doesn't require permission.

If the user denies notification permission at the OS level, the toggle remains in the UI but macOS silently drops the notifications. This is standard macOS behavior.

**Note:** `UNUserNotificationCenter` on macOS uses the binary path as the bundle identifier for non-sandboxed SPM executables. Notifications will work but may appear as a different "app" in System Preferences if the binary path changes between builds. This is acceptable for development; a stable bundle ID would be needed for distribution.

**Files changed:**
- New: `Sources/TBDApp/Services/MacNotificationManager.swift`
- `Sources/TBDApp/AppState.swift` — handle incoming deltas to fire sound/notification

### 5. Settings UI

Expand `GeneralSettingsTab` notifications section:

```
Notifications
├─ Toggle: "Enable macOS notifications"
│    help: "Show system notifications when background tasks complete"
├─ Toggle: "Enable notification sounds"
│    help: "Play a sound when background tasks complete"
├─ Picker: "Sound" [enabled only when sound toggle is on]
│    Options: [all files from /System/Library/Sounds/] + "Custom..."
│    Default: "Blow"
│    "Custom..." opens NSOpenPanel for .aiff/.mp3/.wav/.m4a
└─ Button: "Test" (plays selected sound immediately)
```

The sound picker enumerates `/System/Library/Sounds/` at runtime, strips file extensions for display names, and sorts alphabetically.

**Settings storage:**
- `@AppStorage("enableNotifications")` — Bool, default `true` (already exists)
- `@AppStorage("enableNotificationSounds")` — Bool, default `true` (new)
- `@AppStorage("notificationSoundName")` — String, default `"Blow"` (new)
- `@AppStorage("notificationSoundCustomPath")` — String, default `""` (new)

When "Custom..." is selected, `notificationSoundCustomPath` is populated via NSOpenPanel and `notificationSoundName` is set to `"custom"` as a sentinel. The picker shows the custom filename when this sentinel is active.

**Note:** The existing `SettingsView` frame height (360px) will need to increase to accommodate the new controls.

**Files changed:**
- `Sources/TBDApp/Settings/SettingsView.swift` — expand GeneralSettingsTab

### 6. Visibility Check

The trigger condition for sound/notification is the same as the unread badge (blue dot + bold worktree name in sidebar). The app already tracks which worktrees are "visible" for auto-marking notifications as read. Reuse that exact logic:

- Worktree is the currently selected tab → visible → no sound/notification
- Worktree has a pinned terminal currently shown → visible → no sound/notification  
- All other worktrees → not visible → fire sound/notification

**Files changed:**
- Refactor visibility check into a shared helper if not already extracted

### 7. Real-Time State Subscription

The app subscribes to daemon state deltas via a persistent socket connection for instant notification delivery. The daemon's `StateSubscriptionManager` already broadcasts `StateDelta` events — this component connects the app to that stream.

#### Daemon Side: `state.subscribe` RPC

Add a new RPC method that holds the socket open and streams deltas:

1. Client sends `{"method": "state.subscribe", "params": "{}"}` 
2. Daemon registers the socket as a subscriber via `StateSubscriptionManager.addSubscriber()`
3. The callback writes newline-delimited JSON to the socket for each delta
4. The socket stays open indefinitely — no response is sent until a delta occurs

When a write fails (broken pipe / client disconnected), the subscriber is automatically removed. This is the key invariant that prevents leaks.

**Cleanup on write failure:** Update `StateSubscriptionManager.broadcast()` to catch write errors and call `removeSubscriber()` for the failed ID. Currently it fire-and-forgets to callbacks — the callback itself needs to signal failure so the manager can clean up.

Approach: change the callback signature to return a Bool (success/failure), or have the RPC handler wrapper catch the write error and call `removeSubscriber()` directly using the stored subscriber ID.

**Files changed:**
- `Sources/TBDDaemon/Server/RPCRouter.swift` — add `state.subscribe` handler
- `Sources/TBDShared/RPCProtocol.swift` — add `RPCMethod.stateSubscribe` constant
- `Sources/TBDDaemon/Server/StateSubscription.swift` — update broadcast to handle dead subscribers

#### App Side: Persistent Subscription in DaemonClient

`DaemonClient` opens a second, long-lived socket connection dedicated to the subscription stream:

1. On connect (in `connectAndLoadInitialState()`), open a persistent socket and send the `state.subscribe` RPC
2. Spawn an async task that reads newline-delimited JSON from the socket in a loop
3. Decode each line as `StateDelta` and dispatch to a handler on `@MainActor`
4. On read failure (daemon restarted, socket closed), tear down and let the existing reconnect logic in `startPolling()` re-establish the subscription

The subscription is a **supplement** to polling, not a replacement. Polling continues for full state refresh (worktree list, terminal list, etc.). The subscription adds instant delivery for notifications specifically (and any future delta-driven features).

**Handling reconnection:**
- When the persistent socket disconnects, set a flag so the polling loop knows to re-subscribe on next successful connection
- The subscription task uses `[weak self]` to avoid retain cycles — if `DaemonClient` is deallocated, the task ends naturally
- Only one subscription socket is active at a time; reconnect tears down the old one first

**Files changed:**
- `Sources/TBDApp/DaemonClient.swift` — add persistent subscription socket, delta reading loop, reconnect logic
- `Sources/TBDApp/AppState.swift` — add delta handler that checks visibility and fires sound/notification

## Non-Goals

- Per-worktree mute/notification settings (can add later)
- Clicking notification to switch to worktree (v2 stretch goal)
- Notification grouping/throttling (if it becomes noisy, address then)
- Custom bundled sounds (system sounds + file picker is sufficient)

## Testing

- `NotifyCommand` env var resolution: unit test that `TBD_WORKTREE_ID` is preferred over CWD
- Sound picker: verify it enumerates system sounds correctly
- Settings persistence: verify toggles and sound name round-trip through `@AppStorage`
- Visibility logic: verify notifications only fire for non-visible worktrees
- State subscription: verify subscriber is auto-removed on broken pipe (daemon-side unit test)
- State subscription: verify reconnect after daemon restart re-establishes subscription

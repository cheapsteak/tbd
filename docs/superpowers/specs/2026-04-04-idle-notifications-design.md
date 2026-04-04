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
  → daemon stores notification in DB
  → app polls refreshNotifications() every ~2s, detects new unread entries
  → compares against previous snapshot to identify newly arrived notifications
  → checks worktree visibility (same logic as unread badge: blue dot / bold)
  → if not visible: plays sound (NSSound) and/or posts macOS notification (UNUserNotificationCenter)
```

**Note:** The app does not have a real-time subscription to daemon state deltas. `StateSubscriptionManager` exists in the daemon but is consumed only by daemon-internal code. The app discovers new notifications via its existing 2-second polling loop in `refreshNotifications()`. This means up to ~2s latency between Claude stopping and the sound/notification firing, which is acceptable.

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

Triggered from `refreshNotifications()` when new unread entries appear for non-visible worktrees (compared against previous polling snapshot):
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

Triggered alongside sound from `refreshNotifications()` for non-visible worktrees with new unread entries. When `enableNotifications` is on:

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
- `Sources/TBDApp/AppState.swift` — hook into `refreshNotifications()` to detect new entries and fire sound/notification

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

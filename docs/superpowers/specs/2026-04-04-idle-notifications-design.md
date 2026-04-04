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
  → daemon stores notification, broadcasts StateDelta.notificationReceived
  → app receives delta
  → checks worktree visibility (same logic as unread badge: blue dot / bold)
  → if not visible: plays sound (NSSound) and/or posts macOS notification (UNUserNotificationCenter)
```

## Components

### 1. Stop Hook Update

The existing `tbd setup-hooks` command installs a Stop hook in Claude Code's `settings.json`. Update the hook command to extract and pass the response message.

**Current hook command:**
```bash
tbd notify --type response_complete 2>/dev/null || true
```

**Updated hook command:**
```bash
MSG=$(cat | jq -r '.last_assistant_message // empty' 2>/dev/null | head -c 500); tbd notify --type response_complete --message "$MSG" 2>/dev/null || true
```

Claude Code passes Stop hook data as JSON on stdin with these fields:
- `last_assistant_message` — full response text
- `stop_reason` — `"end_turn"`, `"max_tokens"`, `"stop_sequence"`, or `"tool_use"`
- `session_id`, `cwd`, `transcript_path`, `permission_mode`, `hook_event_name`

The hook truncates the message to 500 chars at the shell level. The app further truncates for display (~200 chars in the notification body).

**Files changed:**
- `Sources/TBDCLI/Commands/SetupHooksCommand.swift` — update `tbdNotifyCommand` string

### 2. Worktree Resolution (Already Implemented)

`NotifyCommand` already resolves worktree ID from:
1. `--worktree` flag (explicit UUID)
2. `PathResolver` using CWD (matches against daemon's worktree list)

Additionally, set `TBD_WORKTREE_ID` in the tmux environment when TBD creates a terminal, so the hook can pass it explicitly for faster resolution. The CLI checks the env var first, falls back to CWD resolution.

**Files changed:**
- `Sources/TBDCLI/Commands/NotifyCommand.swift` — check `TBD_WORKTREE_ID` env var before PathResolver fallback
- Terminal creation code — set `TBD_WORKTREE_ID` in tmux session environment

### 3. App-Side: Sound Playback

When the app receives a `notificationReceived` delta:
1. Check if the worktree is visible (same logic as unread badge — selected tab or visible pinned terminal)
2. If not visible and `enableNotificationSounds` is on, play the configured sound

Sound playback via `NSSound`:
- System sounds: `NSSound(named: NSSound.Name("Blow"))` (loads from `/System/Library/Sounds/`)
- Custom sounds: `NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)`

**Settings:**
- `@AppStorage("enableNotificationSounds")` — Bool, default `true`
- `@AppStorage("notificationSoundName")` — String, default `"Blow"`

**Files changed:**
- New: `Sources/TBDApp/Services/NotificationSoundPlayer.swift`

### 4. App-Side: macOS Notification Banners

When the app receives a `notificationReceived` delta for a non-visible worktree and `enableNotifications` is on:

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

**Files changed:**
- New: `Sources/TBDApp/Services/MacNotificationManager.swift`
- `Sources/TBDApp/AppState.swift` or notification handling code — wire up delta handler

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

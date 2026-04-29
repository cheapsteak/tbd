# Deep-linkable worktrees in TBD

**Status:** design accepted
**Date:** 2026-04-29

## Problem

Open a TBD worktree from anywhere by clicking a URL. Use case is personal —
links sit in notes, browser bookmarks, Slack-to-self, and clicking them should
focus the TBD app on the linked worktree.

The link must remain valid even if internal state has changed since it was
generated, as long as the worktree itself still exists.

## Out of scope (deferred)

- **Terminal-precision anchors.** Earlier draft included `&terminal=<uuid>`.
  Dropped to keep v1 small. URL format below leaves room to add it later.
- **Cross-machine sharing.** UUIDs are local; teammates clicking your link
  won't land on their equivalent worktree. Personal use only.
- **App-side "Copy Link" UI.** No right-click affordance in v1. CLI-only
  generation.
- **Clipboard / auto-open flags** on the CLI. Pipe to `pbcopy` if you want
  clipboard. No `--open` either.

## URL format

```
tbd://open?worktree=<uuid>
```

- Scheme: `tbd`
- Host: `open` (acts as a verb; leaves room for additional verbs later
  without colliding)
- Required query item: `worktree` (canonical lowercased UUID string)
- Query-string form chosen over path segments so future params (e.g.
  `&terminal=`, `&tab=`, `&note=`) extend without breaking parsers

## Click contract

When the OS hands `tbd://open?worktree=X` to TBDApp:

1. Parse `URLComponents`. Validate scheme is `tbd`, host is `open`,
   `worktree` query item parses as a `UUID`. On any failure → log + no-op.
2. Look up the worktree in `appState.worktrees`.
   - If not found (unknown UUID, or worktree was deleted) → log a warning,
     no UI side-effect, no error popup. Stale links should fail quietly.
3. If found:
   - Set `appState.selectedWorktreeIDs = [worktreeID]`
   - Bring the main window to front and activate the app
     (`NSApp.activate(ignoringOtherApps: true)`)
   - Default tab-selection behavior takes over for terminals — we do not
     touch `activeTabIndices`.

If the app is not running when the link is clicked, macOS launches it via
the bundled `.app` registration described below. SwiftUI's
`.onOpenURL { ... }` on the main `Window` scene fires for both
already-running delivery and cold-launch delivery on macOS 13+, so a
single wiring point is sufficient. (If a future regression shows
cold-launch URLs being dropped, add a buffering `application(_:open:)`
fallback in `AppDelegate` — not implemented in v1.)

## Architecture: bundling TBDApp

This is the load-bearing change. macOS LaunchServices resolves `tbd://`
clicks via `CFBundleURLTypes` in an `Info.plist`. TBDApp currently runs as
a bare SPM executable with no bundle, so the URL scheme cannot be
registered.

### Bundle layout

Created at build/restart time inside the existing build output dir:

```
.build/debug/TBD.app/
  Contents/
    Info.plist                  ← copied from Resources/TBDApp.Info.plist
    MacOS/
      TBDApp                    ← symlink → ../../../TBDApp
```

- `Resources/TBDApp.Info.plist` is committed to the repo and is the source
  of truth for bundle identity.
- `Contents/MacOS/TBDApp` is a **symlink** (not a copy) so every
  `swift build` automatically updates what the bundle launches without
  requiring a copy step. Iteration speed unchanged.
- The bundle dir lives under `.build/` and is gitignored along with the
  rest of build output.

### Info.plist contents

Minimum keys for URL handling and proper macOS app behavior:

- `CFBundleIdentifier` = `com.tbd.app`
- `CFBundleName` = `TBD`
- `CFBundleExecutable` = `TBDApp`
- `CFBundlePackageType` = `APPL`
- `CFBundleVersion` / `CFBundleShortVersionString` = `1.0` (placeholder; not
  user-visible in this dev tool)
- `LSMinimumSystemVersion` = matches `Package.swift` deployment target
- `CFBundleURLTypes`:
  ```
  CFBundleURLName    = com.tbd.deeplink
  CFBundleURLSchemes = [ "tbd" ]
  ```

### restart.sh changes

`scripts/restart.sh` learns to:

1. After `swift build`, ensure `.build/debug/TBD.app/` exists (mkdir -p).
2. Copy `Resources/TBDApp.Info.plist` to `Contents/Info.plist` if the
   source is newer (or doesn't exist in the bundle yet).
3. Maintain `Contents/MacOS/TBDApp` as a symlink to `../../../TBDApp`
   (idempotent `ln -sf`).
4. If the `Info.plist` was just (re)written, run
   `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f .build/debug/TBD.app`
   to inform LaunchServices about the URL scheme registration. This is a
   no-op the rest of the time.
5. Launch via `open .build/debug/TBD.app` instead of executing the bare
   `.build/debug/TBDApp`.

Restart timing is unchanged in steady state — the symlink trick avoids
copies, plist registration only re-runs when the plist actually changes.

### Cleanup that falls out of bundling

In scope, since we're already touching this surface:

- Delete the manual `NSApp.setActivationPolicy(.regular)` call in
  `Sources/TBDApp/TBDApp.swift:7`. A bundled app gets the right activation
  policy from its bundle by default.
- The `setActivationPolicy`-before-icon-set workaround noted in the
  project CLAUDE.md (re: `NSApp.applicationIconImage` ordering) becomes
  unnecessary; preserve current behavior but a follow-up can simplify.

Future fixes that bundling **enables** but are *not* implemented here:

- `UNUserNotificationCenter.current()` no longer crashes (the existing
  guard in code can be removed in a later cleanup pass).
- `Info.plist`-dependent APIs become available without case-by-case
  guards.

These are noted only to motivate the bundling cost — they are out of scope
for this spec.

## App-side implementation

### New file: `Sources/TBDApp/DeepLinkHandler.swift`

A small, isolated unit. Two responsibilities:

```swift
enum DeepLinkHandler {
    /// Parse and dispatch a tbd:// URL. Logs and returns silently on any
    /// failure (invalid format, unknown worktree). Never throws, never
    /// surfaces UI errors.
    static func handle(_ url: URL, appState: AppState)
}
```

Internal helpers:

- `parse(_ url: URL) -> UUID?` — validates scheme/host, extracts and
  parses `worktree` query item. Returns nil on any malformed input.
- Calls `appState.navigateToWorktree(_:)` (new method, see below) on
  success.
- All log lines use the existing `os.Logger` infrastructure under
  subsystem `com.tbd.app`, category `deeplink`.

### Wiring

Single site: `.onOpenURL { url in DeepLinkHandler.handle(url, appState:
appState) }` on the main `Window` scene in `Sources/TBDApp/TBDApp.swift`.
On macOS 13+ this fires for both cold-launch URLs and URLs delivered to
an already-running app. AppState is already in scope at that call site
via `@StateObject`.

If we later discover a case where cold-launch URLs are dropped (e.g. the
scene isn't mounted by the time the URL is delivered), the fallback is
to add `application(_:open urls:)` in `AppDelegate` that buffers URLs
into an array, and drain the buffer once AppState is reachable. Not
implemented in v1.

### New AppState method

In `Sources/TBDApp/AppState+Worktrees.swift` (already the home for
worktree-related extensions):

```swift
func navigateToWorktree(_ id: UUID) {
    guard worktrees.contains(where: { $0.id == id }) else {
        // Logged at handler layer; this is a defensive guard.
        return
    }
    selectedWorktreeIDs = [id]
    NSApp.activate(ignoringOtherApps: true)
    // Bring the main window to front. SwiftUI's window restoration
    // handles re-showing if it was minimized.
}
```

The existing `selectedWorktreeIDs` setter already maintains
`selectionOrder` invariants (see `Sources/TBDApp/AppState.swift:16`), so
nothing else needs to change.

## CLI-side implementation

### New file: `Sources/TBDCLI/Commands/LinkCommand.swift`

```
tbd link             # zero-arg form: read TBD_WORKTREE_ID from env
tbd link <worktree>  # explicit form: UUID, name, or displayName
```

Behavior:

- **Zero-arg.** Read `TBD_WORKTREE_ID` from the process environment. If
  unset, exit 1 with stderr message:
  `error: not inside a TBD terminal; pass a worktree name or UUID`.
  No daemon roundtrip — env var is the source of truth and is already
  injected by `RPCRouter+TerminalHandlers.swift:31` and
  `WorktreeLifecycle+Reconcile.swift:254`.
- **Explicit form.** Reuse the existing
  `resolveWorktreeNameOrID(_:client:)` helper in
  `Sources/TBDCLI/Commands/WorktreeCommands.swift:298`. It handles UUID,
  `name`, and `displayName` matching, and emits a clear error on
  ambiguous `displayName` matches.

Output: one line to stdout, no trailing decoration:

```
tbd://open?worktree=<uuid>
```

No flags in v1.

### Shared URL utilities: `Sources/TBDShared/DeepLinks.swift`

A new tiny module so app and CLI agree on format:

```swift
public enum DeepLink {
    public static let scheme = "tbd"
    public static let openHost = "open"

    /// Build a tbd://open URL pointing at a worktree.
    public static func makeOpenWorktreeURL(_ id: UUID) -> URL

    /// Parse a tbd:// URL. Returns the target worktree UUID if the URL is
    /// well-formed and recognized; nil otherwise. Does NOT validate that
    /// the worktree exists — that's the caller's job.
    public static func parseOpenURL(_ url: URL) -> UUID?
}
```

Per the project CLAUDE.md note on TBDShared, no migration is needed for
this addition — it's a new file, not a model change.

## Testing

In-scope test surface:

- `DeepLink.makeOpenWorktreeURL(_:)` returns a URL with the expected
  components.
- `DeepLink.parseOpenURL(_:)` happy path: round-trips a `make`d URL.
- `DeepLink.parseOpenURL(_:)` rejects: wrong scheme, wrong host, missing
  query item, malformed UUID, extra unrelated query items (the last
  should still parse — extra params are forward-compatible).
- `DeepLinkHandler.handle(_:appState:)` test against a stub `AppState`
  populated with one worktree:
  - Known UUID → `selectedWorktreeIDs` becomes `[id]`.
  - Unknown UUID → no mutation to selection.
  - Malformed URL → no mutation.
- CLI: zero-arg with no `TBD_WORKTREE_ID` exits non-zero with a
  recognizable message; with the env var set, prints the expected URL.
- CLI: explicit form resolves a worktree by `name` and prints the URL;
  ambiguous `displayName` produces the existing helper's error.

Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) per project
convention.

Out-of-scope (manual verification): the actual LaunchServices round-trip
(clicking a `tbd://` link in a browser launches/focuses the app). Worth a
manual check after first build, but not automatable.

## File-level change list

**New files:**

- `Resources/TBDApp.Info.plist`
- `Sources/TBDShared/DeepLinks.swift`
- `Sources/TBDApp/DeepLinkHandler.swift`
- `Sources/TBDCLI/Commands/LinkCommand.swift`
- Tests for the above (locations follow existing test layout)

**Modified files:**

- `scripts/restart.sh` — bundle creation, `lsregister`, launch via `open`
- `Sources/TBDApp/TBDApp.swift` — `.onOpenURL` on the main Window scene
- `Sources/TBDApp/AppState+Worktrees.swift` — `navigateToWorktree(_:)`
- `Sources/TBDCLI/TBD.swift` — register the new `link` subcommand

The `Resources/TBDApp.Info.plist` file is read by macOS at app launch
(not by Swift code), so no `Package.swift` change is needed.

**Removed:**

- `NSApp.setActivationPolicy(.regular)` from
  `Sources/TBDApp/TBDApp.swift:7` (now redundant with bundle)

## Risks and mitigations

- **LaunchServices caches.** macOS sometimes caches a stale URL handler
  registration. If clicks open the wrong app after first run, manually
  re-run the `lsregister -f` command from restart.sh. Documented in
  troubleshooting comments inside the script.
- **Multiple TBD checkouts.** If the user has multiple worktrees of the
  TBD repo itself, each has its own `.build/debug/TBD.app`. Whichever
  was registered most recently with `lsregister` wins. This is the same
  behavior as today's "which TBDApp launches" question — restart.sh
  re-registers on every restart, so the most-recently-restarted checkout
  is the URL handler. Documented as a known quirk.
- **Stale links.** Worktrees can be archived or deleted. The click
  contract handles this silently per the design above.

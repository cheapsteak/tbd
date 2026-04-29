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
2. **First lookup — active worktrees.** Search `appState.worktrees`. If
   found:
   - Set `appState.selectedWorktreeIDs = [worktreeID]`
   - Bring the main window to front and activate the app
     (`NSApp.activate(ignoringOtherApps: true)`)
   - Default tab-selection behavior takes over for terminals — we do not
     touch `activeTabIndices`.
3. **Second lookup — archived worktrees.** Active miss → fire an
   `RPCMethod.worktreeList` RPC with `WorktreeListParams(repoID: nil,
   status: .archived)`. The daemon returns all archived worktrees across
   all repos; client finds the matching UUID. If found:
   - Set `appState.selectedRepoID = worktree.repoID` (opens that repo's
     archived pane in the content area — see `AppState.swift:42` and
     `ArchivedWorktreesView`)
   - Set `appState.highlightedArchivedWorktreeID = id` so
     `ArchivedWorktreesView` can scroll the row into view and flash it
     (see "Archived row highlight" below)
   - Activate the app and bring main window to front
   - Clear `selectedWorktreeIDs` (archived view replaces the active
     worktree detail pane in this layout)
4. **Both lookups miss** (truly deleted, or never existed) → log a warning
   to `os.Logger`, no UI side-effect.

This two-stage lookup runs on every deep-link click. The active-worktree
path is synchronous against in-memory state; only the archived fallback
involves a daemon roundtrip. Worst-case (truly stale link) is one
roundtrip plus a log line — acceptable for a user-initiated action.

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

### New AppState methods

In `Sources/TBDApp/AppState+Worktrees.swift` (already the home for
worktree-related extensions):

```swift
/// Active-worktree path. Synchronous; assumes id is in self.worktrees.
private func navigateToActiveWorktree(_ id: UUID) {
    selectedWorktreeIDs = [id]
    NSApp.activate(ignoringOtherApps: true)
}

/// Archived-worktree path. Async; issues an RPC to find the worktree
/// across all archived ones, then opens the archived pane and flashes
/// the row.
private func navigateToArchivedWorktree(_ id: UUID) async {
    let archived: [Worktree]
    do {
        archived = try await daemonClient.listWorktrees(
            repoID: nil, status: .archived
        )
    } catch {
        logger.error("Deep-link archived lookup failed: \(error)")
        return
    }
    guard let wt = archived.first(where: { $0.id == id }) else {
        // Final miss — truly stale link.
        return
    }
    selectedWorktreeIDs = []
    selectedRepoID = wt.repoID
    archivedWorktrees[wt.repoID] = archived.filter { $0.repoID == wt.repoID }
    highlightedArchivedWorktreeID = id
    NSApp.activate(ignoringOtherApps: true)
}

/// Public entry point. Tries active first, falls through to archived.
func navigateToWorktree(_ id: UUID) {
    if worktrees.contains(where: { $0.id == id }) {
        navigateToActiveWorktree(id)
    } else {
        Task { await navigateToArchivedWorktree(id) }
    }
}
```

The existing `selectedWorktreeIDs` setter already maintains
`selectionOrder` invariants (see `Sources/TBDApp/AppState.swift:16`), so
nothing else needs to change there.

### New AppState property

```swift
/// Set briefly when a deep link lands on an archived worktree. The
/// ArchivedWorktreesView observes this and scrolls/flashes the matching
/// row, then clears the value after the flash animation completes.
@Published var highlightedArchivedWorktreeID: UUID?
```

### Archived row highlight

In `Sources/TBDApp/ArchivedWorktreesView.swift`:

- Wrap the existing `ForEach(archived) { ... }` row list in a
  `ScrollViewReader` so we can call `proxy.scrollTo(id, anchor: .center)`.
- Add `.onChange(of: appState.highlightedArchivedWorktreeID)` on the
  outer view: when it transitions to a non-nil value matching a row in
  this repo's archived list, scroll to it and trigger a brief background
  flash (e.g. 800ms `.background(...)` animation that fades from accent
  color back to clear).
- After the animation completes, set
  `appState.highlightedArchivedWorktreeID = nil` so a re-click on the
  same link re-triggers the flash.

Use the project's existing animation/color conventions — no new
dependencies.

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
- `DeepLinkHandler.handle(_:appState:)` test against a stub `AppState`:
  - Known active UUID → `selectedWorktreeIDs` becomes `[id]`.
  - Known archived UUID (stub daemon returns it) → `selectedRepoID` is
    set to the worktree's repoID, `highlightedArchivedWorktreeID` is
    set to the worktree id, `selectedWorktreeIDs` is cleared.
  - Unknown UUID (active miss + archived miss) → no mutation to
    selection or repo focus.
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
- `Sources/TBDApp/AppState+Worktrees.swift` — `navigateToWorktree(_:)`,
  `navigateToActiveWorktree(_:)`, `navigateToArchivedWorktree(_:)`
- `Sources/TBDApp/AppState.swift` — new
  `@Published var highlightedArchivedWorktreeID: UUID?`
- `Sources/TBDApp/ArchivedWorktreesView.swift` — `ScrollViewReader`
  wrapper, `.onChange` reaction, row flash animation
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

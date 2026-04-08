# Per-Repo Startup Hooks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up the already-scaffolded `appHookPath` slot in `HookResolver` so per-repo hooks stored at `~/tbd/repos/<repo-id>/hooks/<event>` are picked up first, and add a UI section in `RepoSettingsView` to author those scripts inline.

**Architecture:** `TBDConstants` gains a `hookPath(repoID:event:)` helper that computes the deterministic file path. The two lifecycle call sites that currently pass `appHookPath: nil` are updated to pass the real path. A new SwiftUI component (`RepoHooksSettingsView`) reads/writes those files directly from the app — no RPC, no DB changes — and is embedded in the existing `RepoSettingsView`.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test`, `#expect`), Foundation (`FileManager`, `Process`), `TBDShared`, `TBDDaemonLib`, `TBDApp`

---

## File Map

| Action | File | What changes |
|--------|------|--------------|
| Modify | `Sources/TBDShared/Constants.swift` | Add `reposDir` + `hookPath(repoID:event:)` |
| Modify | `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:269-273` | Pass real path instead of `nil` |
| Modify | `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift:54-58` | Pass real path instead of `nil` |
| Create | `Sources/TBDApp/Settings/RepoHooksSettingsView.swift` | New UI component for hook editing |
| Modify | `Sources/TBDApp/RepoDetailView.swift:49-94` | Embed `RepoHooksSettingsView` in `RepoSettingsView` |

---

## Task 1: Add `hookPath` to `TBDConstants`

**Files:**
- Modify: `Sources/TBDShared/Constants.swift`
- Test: `Tests/TBDSharedTests/ConstantsTests.swift` (create new file)

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDSharedTests/ConstantsTests.swift`:

```swift
import Testing
import Foundation
@testable import TBDShared

@Test func hookPathComponents() {
    let repoID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let path = TBDConstants.hookPath(repoID: repoID, event: .setup)
    #expect(path.hasSuffix("/tbd/repos/12345678-1234-1234-1234-123456789abc/hooks/setup"))
}

@Test func hookPathArchive() {
    let repoID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let path = TBDConstants.hookPath(repoID: repoID, event: .archive)
    #expect(path.hasSuffix("/tbd/repos/AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA/hooks/archive"))
}
```

- [ ] **Step 2: Check there's a TBDSharedTests target**

```bash
grep -r "TBDSharedTests\|TBDShared" Package.swift
```

If no `TBDSharedTests` target exists, check which test target imports TBDShared and add the test file there instead. Proceed to Step 3 once you know where to put the test.

- [ ] **Step 3: Run test to verify it fails**

```bash
swift test --filter hookPathComponents 2>&1 | tail -20
```

Expected: compile error — `hookPath` doesn't exist yet.

- [ ] **Step 4: Add `reposDir` and `hookPath` to `TBDConstants`**

In `Sources/TBDShared/Constants.swift`, after the `conductorsDir` line, add:

```swift
    public static let reposDir = configDir.appendingPathComponent("repos")

    public static func hookPath(repoID: UUID, event: HookEvent) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(event.rawValue)
            .path
    }
```

Note: `HookEvent` is defined in `Sources/TBDDaemon/Hooks/HookResolver.swift` and is `public`. `TBDConstants` is in `TBDShared`. `HookEvent` is in `TBDDaemonLib`. Check whether `TBDShared` depends on `TBDDaemonLib` — if not, move `HookEvent` to `TBDShared`, or pass the raw event string as a parameter instead:

```swift
    public static func hookPath(repoID: UUID, eventName: String) -> String {
        reposDir
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }
```

Check the dependency: `grep -A 30 "\.target(name: \"TBDShared\"" Package.swift`

- [ ] **Step 5: Run tests to verify they pass**

```bash
swift test --filter hookPath 2>&1 | tail -20
```

Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDShared/Constants.swift Tests/
git commit -m "feat: add hookPath helper to TBDConstants"
```

---

## Task 2: Wire `appHookPath` in lifecycle call sites

**Files:**
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:269-273`
- Modify: `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Archive.swift:54-58`

Both call sites currently pass `appHookPath: nil`. Replace with the computed path. The `resolve()` method already checks `FileManager.default.fileExists(atPath:)` — if the file isn't there it falls through, so passing a non-existent path is safe.

- [ ] **Step 1: Update `WorktreeLifecycle+Create.swift`**

At line ~269, change:

```swift
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: worktreePath,
            appHookPath: nil
        )
```

to:

```swift
        let setupHookPath = hooks.resolve(
            event: .setup,
            repoPath: worktreePath,
            appHookPath: TBDConstants.hookPath(repoID: worktree.repoID, eventName: "setup")
        )
```

(Use `eventName:` or `event:` depending on the signature you landed on in Task 1.)

`worktree` is a parameter of `setupTerminals(worktree:repo:...)` — it's in scope at line ~269.

- [ ] **Step 2: Update `WorktreeLifecycle+Archive.swift`**

At line ~54, change:

```swift
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.path,
                appHookPath: nil
            )
```

to:

```swift
            let archiveHookPath = hooks.resolve(
                event: .archive,
                repoPath: worktree.path,
                appHookPath: TBDConstants.hookPath(repoID: worktree.repoID, eventName: "archive")
            )
```

`worktree` is a parameter of `completeArchiveWorktree(worktree:repo:force:)`.

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 4: Run existing hook tests**

```bash
swift test --filter HookResolver 2>&1 | tail -20
```

Expected: all pass, including `appConfigTrumpsAll`.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Lifecycle/
git commit -m "feat: wire app per-repo hook path in lifecycle call sites"
```

---

## Task 3: Create `RepoHooksSettingsView`

**Files:**
- Create: `Sources/TBDApp/Settings/RepoHooksSettingsView.swift`

This view reads/writes hook script files directly. No RPC. No AppState mutation needed.

File write helper behavior:
- Non-empty content → create parent dirs + write + chmod 0o755
- Empty/whitespace-only content → delete file if it exists (resolver treats missing = no hook)

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import TBDShared

struct RepoHooksSettingsView: View {
    let repoID: UUID

    @State private var setupDraft: String = ""
    @State private var archiveDraft: String = ""
    @State private var setupSaved = false
    @State private var archiveSaved = false

    private var setupPath: String { TBDConstants.hookPath(repoID: repoID, eventName: "setup") }
    private var archivePath: String { TBDConstants.hookPath(repoID: repoID, eventName: "archive") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hookSection(
                    title: "Setup hook",
                    description: "Runs in Terminal 2 when a new worktree is created.",
                    draft: $setupDraft,
                    filePath: setupPath,
                    showSaved: $setupSaved
                )

                Divider()

                hookSection(
                    title: "Archive hook",
                    description: "Runs before a worktree is archived. Must complete within 60 seconds.",
                    draft: $archiveDraft,
                    filePath: archivePath,
                    showSaved: $archiveSaved
                )
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupDraft = readHook(at: setupPath)
            archiveDraft = readHook(at: archivePath)
        }
    }

    @ViewBuilder
    private func hookSection(
        title: String,
        description: String,
        draft: Binding<String>,
        filePath: String,
        showSaved: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .fontWeight(.medium)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                if draft.wrappedValue.isEmpty {
                    Text("e.g. npm install && brew bundle")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                // File path display
                HStack(spacing: 4) {
                    Text(filePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(filePath, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy full path")
                }

                Spacer()

                if showSaved.wrappedValue {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("Save") {
                    writeHook(content: draft.wrappedValue, to: filePath)
                    withAnimation(.easeInOut(duration: 0.3)) { showSaved.wrappedValue = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeInOut(duration: 0.3)) { showSaved.wrappedValue = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func readHook(at path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func writeHook(content: String, to path: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build. Fix any compile errors (most likely: `eventName` vs `event` parameter name mismatch from Task 1).

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDApp/Settings/RepoHooksSettingsView.swift
git commit -m "feat: add RepoHooksSettingsView for per-repo hook editing"
```

---

## Task 4: Wire into `RepoSettingsView`

**Files:**
- Modify: `Sources/TBDApp/RepoDetailView.swift:49-94`

`RepoSettingsView` currently has a single `Picker` for Claude token override. Add a `Divider` and `RepoHooksSettingsView` below it.

- [ ] **Step 1: Add `RepoHooksSettingsView` to `RepoSettingsView`**

In `Sources/TBDApp/RepoDetailView.swift`, find `RepoSettingsView.body`. Replace the inner content:

```swift
    var body: some View {
        if let repo = repo {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Claude token", selection: tokenOverrideBinding(repo: repo)) {
                        Text("Inherit global default").tag(UUID?.none)
                        ForEach(appState.claudeTokens, id: \.token.id) { entry in
                            Text(entry.token.name).tag(UUID?.some(entry.token.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let caption = tokenOverrideCaption(repo: repo) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    RepoHooksSettingsView(repoID: repoID)
                }
                .padding()
            }
        }
    }
```

- [ ] **Step 2: Build to verify**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build.

- [ ] **Step 3: Restart and manually verify**

```bash
scripts/restart.sh
```

After restart, open TBD, navigate to any repo → Settings tab. Verify:
- "Setup hook" and "Archive hook" sections appear below the Claude token picker
- File path row shows `~/tbd/repos/<uuid>/hooks/setup`
- Copy button copies the full (unexpanded) path to clipboard
- Typing a command and clicking Save creates the file at that path (check with `ls ~/tbd/repos/<uuid>/hooks/`)
- Clearing the field and saving deletes the file
- Creating a new worktree in that repo runs the hook in Terminal 2

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/RepoDetailView.swift
git commit -m "feat: embed RepoHooksSettingsView in repo settings panel"
```

---

## Task 5: Final build + test pass

- [ ] **Step 1: Full build and test**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -20
```

Expected: clean build, all tests pass.

- [ ] **Step 2: Verify hook resolution order manually**

In a repo that has `conductor.json`, verify the app hook (if set) takes priority over it: set a setup hook via UI, create a worktree, confirm the app hook runs (not conductor). Then clear the app hook, create another worktree, confirm conductor runs.

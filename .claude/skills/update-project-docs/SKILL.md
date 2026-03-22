---
name: update-project-docs
description: Regenerate TBD project documentation (architecture.md, file-map.md) from current source code. Use when significant structural changes have been made — new files, renamed modules, new RPC methods, changed architecture. Invoke with "/update-project-docs".
---

# Update Project Docs

Regenerates the reference documentation in `.claude/skills/tbd-project/references/` by scanning the current source tree.

## When to Run

- After adding new source files or directories
- After adding new RPC methods
- After changing the package structure (new targets, dependencies)
- After significant architectural changes

## What to Update

### 1. File Map (`references/file-map.md`)

Scan `Sources/` for all Swift files. For each file, write a one-line description of what it does. Group by target directory. Read each file briefly to determine its purpose — don't guess from the filename alone.

Check for:
- New files not yet documented
- Deleted files still listed
- Files that moved directories
- New CLI commands in `Commands/`

### 2. Architecture (`references/architecture.md`)

Review these sections and update if they've drifted from the code:
- **RPC Methods list** — compare against `RPCMethod` constants in `Sources/TBDShared/RPCProtocol.swift`
- **Data model tables** — compare against migrations in `Sources/TBDDaemon/Database/Database.swift`
- **Hook events** — compare against `HookEvent` enum in `Sources/TBDDaemon/Hooks/HookResolver.swift`
- **Tmux architecture** — compare against `Sources/TBDApp/Terminal/TmuxBridge.swift`
- **Lifecycle flows** — compare against `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle.swift`

### 3. SKILL.md

Only update if conventions have changed (e.g., new testing framework, new naming conventions, changed RPC protocol format). The SKILL.md should be stable — it describes patterns, not specific files.

## Process

1. Read `Package.swift` to understand current targets
2. List all Swift files under `Sources/`
3. For new/changed files, read them briefly to understand purpose
4. Update `references/file-map.md`
5. Read the key source files listed above to verify architecture.md accuracy
6. Update `references/architecture.md` if anything changed
7. Commit with message: `docs: update project references`

## Do NOT

- Rewrite SKILL.md unless conventions actually changed
- Add speculative documentation for features not yet built
- Remove entries for files that exist (only remove for deleted files)
- Change the document structure/formatting — keep it consistent

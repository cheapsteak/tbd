# `.build` reclaimer (dev tooling)

Keeps each TBD worktree's SwiftPM `.build` small. **Not part of the shipped product** — it is developer machine tooling, like `scripts/restart.sh`.

## What it does (hourly, via launchd)
Only acts on worktrees containing a `Package.swift` (SwiftPM packages) — `tbd worktree list` spans every repo TBD manages, including non-Swift ones (e.g. longeye-app, longeye-docs, agent-channels), which are skipped entirely.

SourceKit-LSP background-indexing suppression is a **committed** `.sourcekit-lsp/config.json` (`"backgroundIndexing": false`) at the repo root, present in every worktree the moment it's checked out — the script no longer seeds it. Trade-off: cross-file LSP (workspace symbols, global find-references, cross-module go-to-definition) is disabled on TBD worktrees; live single-file diagnostics still work.

The script itself only reclaims disk from **active, idle** worktrees:
- **Tier 1** — `index-build/` idle > 6h → deleted (regenerates on demand).
- **Tier 2** — whole `.build` idle > 48h AND no live Claude session → deleted (one cold rebuild next time).

Worktrees with a running `swift-*` build process are never touched. Archived worktrees are already reclaimed by `git worktree remove`.

### Re-enabling background indexing
A project-local `.sourcekit-lsp/config.json` takes precedence over user-global SourceKit-LSP config. To get cross-file LSP back on your machine without affecting the committed default: set `"backgroundIndexing": true` in the file locally, then run `git update-index --skip-worktree .sourcekit-lsp/config.json` so the flip is never committed. Alternatively, just delete the file locally.

### Migration note
Worktrees created before this change may have an untracked `.sourcekit-lsp/config.json` left over from the old per-worktree seeding, which git will flag as colliding with the newly-tracked file on pull. Remove it (`rm .sourcekit-lsp/config.json`) and re-checkout, or leave it — its contents are identical to the committed version.

## Install / uninstall
```sh
# run from a STABLE checkout (e.g. ~/projects/tbd), not a throwaway worktree
scripts/install-reclaim-agent.sh install
scripts/install-reclaim-agent.sh uninstall
```

## Manual use
```sh
scripts/reclaim-build.sh --dry-run   # preview; deletes/seeds nothing
scripts/reclaim-build.sh             # reclaim now
```

## Tuning
`RECLAIM_T1_SECONDS` (default 21600) and `RECLAIM_T2_SECONDS` (default 172800) override the thresholds.

## Future
The ~4.6 GiB of compiled artifacts can only be de-duplicated across worktrees via SwiftPM compilation caching (LLVM CAS + prefix mapping) on the new Swift Build engine — currently an opt-in pitch. Track and pilot when it lands.

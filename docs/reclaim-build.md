# `.build` reclaimer (dev tooling)

Keeps each TBD worktree's SwiftPM `.build` small. **Not part of the shipped product** — it is developer machine tooling, like `scripts/restart.sh`.

## What it does (hourly, via launchd)
Only acts on worktrees containing a `Package.swift` (SwiftPM packages) — `tbd worktree list` spans every repo TBD manages, including non-Swift ones (e.g. longeye-app, longeye-docs, agent-channels), which are skipped entirely.
1. Seeds a **gitignored** `.sourcekit-lsp/config.json` (`"backgroundIndexing": false`) into every active worktree, so SourceKit-LSP never builds the ~2.6 GiB `index-build/`. Trade-off: cross-file LSP (workspace symbols, global find-references, cross-module go-to-definition) is disabled on TBD worktrees; live single-file diagnostics still work. Reversible — delete the `.sourcekit-lsp/` dirs.
2. Deletes stale build artifacts from **active, idle** worktrees:
   - **Tier 1** — `index-build/` idle > 6h → deleted (regenerates on demand).
   - **Tier 2** — whole `.build` idle > 48h AND no live Claude session → deleted (one cold rebuild next time).
   Worktrees with a running `swift-*` build process are never touched. Archived worktrees are already reclaimed by `git worktree remove`.

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

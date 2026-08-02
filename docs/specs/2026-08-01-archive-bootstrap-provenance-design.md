# Archive Bootstrap Provenance

Issue: [#564](https://github.com/cheapsteak/tbd/issues/564)

## Problem

Archive currently hands every worktree to `git worktree remove --force`. Git cannot distinguish reproducible agent bootstrap files from unpublished work, so a generated overlay either blocks conservative cleanup forever or disappears with unique files when archive proceeds.

Paths do not prove provenance. `.agents`, `.codex`, `.Codex`, hooks, and `AGENTS.md` can contain generated files, user edits, or product work. TBD must classify content from an exact producer declaration and current bytes, never from a path-wide allowlist.

## Provenance contract

An injector may write `.codex/bootstrap-provenance.json` in the worktree, but that copy is advisory and can never make deletion eligible by itself. A trusted registration service outside the worktree must attest the worktree ID, exact HEAD SHA, producer version, and exact manifest bytes before the classifier accepts it. TBD does not yet own that producer/registration boundary, so production archive and GC fail closed on all dirty overlays until the external injector supplies a trusted attestation. The UTF-8 JSON document has this versioned shape:

```json
{
  "schemaVersion": 1,
  "producer": "agent-bootstrap",
  "producerVersion": "2026-08-01.1",
  "artifacts": [
    {
      "path": ".agents/skills/example/SKILL.md",
      "kind": "runtime",
      "sha256": "<current file digest>"
    },
    {
      "path": ".codex/config.toml",
      "kind": "trackedMutation",
      "sha256": "<current file digest>",
      "baseSha256": "<HEAD version digest>"
    },
    {
      "path": "generated/index.json",
      "kind": "generatedOutput",
      "sha256": "<current file digest>"
    }
  ]
}
```

The manifest is metadata, not an artifact entry, because hashing itself would be recursive. The advisory file must byte-match its out-of-tree attestation, and the attested worktree ID, HEAD, and producer version must all match current state. A valid trusted attestation is non-blocking only while every dirty runtime artifact that it declares has the declared bytes and status. Unknown schemas, malformed documents, duplicate paths, absolute paths, parent traversal, symlinks, unreadable files, and an unattested/self-authored manifest fail closed.

`runtime` covers untracked, reproducible session scaffolding. `trackedMutation` requires the current digest plus identical digests for `HEAD:path` and `:path` in the index; this proves the exact base-plus-result identity and rejects staged user work. `generatedOutput` stays reviewable even when its digest matches because a digest alone does not prove that committed inputs reproduce the file.

The producer must stop modifying tracked repository files when it can use an out-of-tree or session overlay. The tracked-mutation form is a compatibility rail for known existing injectors, not a preferred bootstrap mechanism.

## Classification

The classifier reads every tracked and untracked dirty path with `git status --porcelain=v1 -z --untracked-files=all` and disables rename detection so each record names one path. It produces three groups:

1. **Generated runtime residue**: exact `runtime` entries, exact `trackedMutation` entries with a verified base digest, and the valid manifest itself.
2. **Reviewable generated output**: exact `generatedOutput` entries. Drift in a generated entry moves it to unique unpublished work.
3. **Unique unpublished work**: any dirty path outside the manifest, any digest or status mismatch, any unsafe file type, or all dirt when provenance cannot be verified.

The report collapses runtime residue into one count. It lists reviewable and unique paths individually so an archive error identifies what a person must inspect, truncating each category at twenty paths because this string reaches a GUI alert through an RPC error.

### Ignored paths are outside the boundary

The classifier does not enumerate ignored files, and snapshots do not force-add them. `.gitignore` is the user's own standing declaration that those bytes are reproducible, and it is the only signal available: nothing in Git distinguishes a build tree from an ignored file someone would want back.

Folding them in was considered and rejected. It fails closed in the wrong direction — the honest cost is not "slightly stricter" but three concrete harms measured on this repository's own worktree, which holds 11,453 ignored files totalling 668 MB:

- Non-force archive becomes impossible for any worktree that has ever been built. The app has no force affordance at all; `--force` exists only in the CLI, so the primary interface would offer an action that always fails.
- The refusal message would carry every one of those paths through an RPC error into an alert.
- GC would commit the entire build tree into `refs/tbd/snapshots/…`. Snapshot refs stay reachable, so `git gc` never prunes them and the user's repository grows by hundreds of megabytes per reaped worktree while preserving no work.

Excluding them costs nothing this design was built to buy. Bootstrap scaffolding — `.agents`, `.codex`, `.Codex`, hooks, `AGENTS.md` — is not gitignored by convention, so it still arrives as untracked `??` and remains subject to the full provenance check. An ignored file has been removed along with its worktree since long before this change; that behavior is unchanged, not newly introduced.

The alternative to this exclusion is not a stricter system but a bypassed one: an archive that always refuses trains every user to reach for `--force`, which skips the unpublished-commit check this work exists to enforce.

## Archive eligibility

Normal and automatic archive run an initial classifier before changing state. The archive hook then runs, metadata needed for restoration is captured, and classification runs again as the immediately preceding worktree operation before forced removal. Physical removal errors propagate, path absence is verified, and only then may the database become archived-final, terminals be torn down, events broadcast, or removal callbacks fire. Archive is eligible only when:

- no reviewable generated output exists;
- no unique unpublished work exists; and
- `HEAD` is reachable from at least one remote-tracking branch.

This makes archive RPCs and merge-triggered archive synchronous through the hook, final verification, and removal. A caller may therefore wait for the archive hook's timeout budget (currently up to 60 seconds) plus Git removal latency. That deliberate UX cost is the price of returning success only after physical absence and of preventing a detached task from invalidating the final safety check.

An exact runtime overlay therefore does not block a merged, pushed branch. One changed byte, an extra untracked file, a generated output, or an unpublished commit blocks before any mutation.

The existing explicit `--force` action remains the human escape hatch. It bypasses content and publication eligibility, as its CLI contract already promises, but it does not make automatic archive permissive. RPC callers pass the force bit through both phases; merge-triggered archive never infers publication from the merge event and performs both current-HEAD checks normally.

Archive rechecks the target by worktree ID and path immediately before classification. The classifier never deletes or rewrites artifacts. Only the existing archive phase removes an eligible worktree.

## Cleanup behavior

The provenance classifier is a shared daemon component rather than an archive-only path heuristic. Until trusted registration is integrated, GC treats every advisory overlay as preservation-required. Snapshot creation uses a scratch `GIT_INDEX_FILE`, so it never stages the user's real index, and stages with `git add -A`, which omits ignored paths for the reasons above. GC compares status before and after snapshot and rechecks registration, lock, HEAD, and live CWD after snapshot immediately before deletion. This change does not weaken its grace, snapshot, or target-verification gates.

## Tests

Focused tier-2 tests create isolated temporary Git repositories and cover:

- a pushed branch plus an exact manifest for `.agents`, `.codex`, `.Codex`, hooks, and `AGENTS.md` is archive-safe;
- one modified byte in a declared runtime artifact blocks;
- one unlisted infrastructure file blocks;
- a declared generated index is reviewable and blocks;
- an exact tracked mutation requires both current and `HEAD` digests;
- malformed or unknown provenance blocks;
- an unpublished commit blocks;
- archive refusal leaves the database, terminals, and worktree directory intact;
- explicit force retains its existing override semantics.

No test reads or writes `~/tbd`, and no test touches a real worktree.

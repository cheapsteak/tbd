# docs/

## Implementation and design plans are not committed

Plans produced by planning skills (`writing-implementation-plans`, `writing-design-plans`, etc.) are local scratch artifacts — they go stale fast and have no place in the source tree. Three plan directories are gitignored; write plans there and never `git add -f` them:

- `docs/plans/`
- `docs/superpowers/plans/`
- `docs/implementation-plans/`

When committing, do not stage plan files. If a plan's content is worth keeping, summarize it in the PR description or promote it to a proper doc (an ADR, a `docs/specs/<date>-<topic>-spec.md`, or a section in the relevant `docs/*.md`).

**A `.gitignore` "paths are ignored" error on `git add` is intent, not an obstacle.** It means "this is scratch — don't commit it." Do NOT relocate the file to a non-ignored directory (e.g. `docs/specs/`) to force the commit. If you think a plan genuinely belongs in the tree, stop and ask.

This is enforced mechanically by the `pre-commit` git hook (`scripts/git-hooks/pre-commit`, installed via `scripts/install-hooks.sh`): it refuses to commit any newly-added file carrying the writing-plans header marker, no matter where it's placed. Rare intentional override: `ALLOW_PLAN_COMMIT=1 git commit ...`.

Because that hook only runs when installed locally, the same policy is also enforced in CI by the `plans-guard` job (`scripts/check-no-committed-plans.sh`), which scans the whole tracked tree on every PR and push — so a plan can't slip in from an environment that never installed the hook.

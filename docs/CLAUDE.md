# docs/

## Implementation and design plans are not committed

Plans produced by planning skills (`writing-implementation-plans`, `writing-design-plans`, etc.) are local scratch artifacts — they go stale fast and have no place in the source tree. Two plan directories are gitignored; write plans there and never `git add -f` them:

- `docs/superpowers/plans/`
- `docs/implementation-plans/`

When committing, do not stage plan files. If a plan's content is worth keeping, summarize it in the PR description or promote it to a proper doc (an ADR, or a section in the relevant `docs/*.md`).

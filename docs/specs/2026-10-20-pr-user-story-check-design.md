# PR user-story check

## Problem

A feature PR whose description never says who the change is for, or what it lets them do, can only be reviewed as code. The reviewer cannot judge whether the change does the right thing, only whether it does the thing it does. The PR template has always asked for this in its Summary guidance, but nothing checks it, and agents writing descriptions skip it as readily as people do.

## Decision

Every feature PR description carries a `## User story` section with real prose in it. Two mechanisms hold that line:

- **A CI check that fails the PR** – the `PR user story` job in `.github/workflows/pr-user-story.yml`. It is the enforcement: advisory text and template guidance were already in place and did not hold.
- **A guardrail nudge at `gh pr create`** – the `pr-user-story` rule under `.claude/hooks/guardrails/rules/`. It is informational and never blocks. It exists so an agent writes the section on the first try, rather than pushing a PR that goes red and then editing its description.

Both call one module, `.github/workflows/pr-user-story/check_user_story.py`: the workflow runs it as a script, and the guardrail loads it by path. The exemption list and the section rule therefore live in one place and cannot drift between the nudge and the check. The guardrail reuses the `gh pr create` tokenizer from `pr_worktree_link.py`, which already handles heredoc bodies, `$(…)` substitutions and chained commands.

## Exemption rule

The PR title decides. A title whose conventional-commit type is `fix`, `docs`, `chore`, `test`, `ci`, `build` or `revert` needs no story; the type matches case-insensitively and may carry a `(scope)` and a `!`, so `Fix(app)!:` is exempt. GitHub's own Revert button writes `Revert "…"` with no colon, and that form is exempt too. Every other title needs a story: `feat:`, `refactor:`, `perf:`, and an untyped title alike.

Bug fixes are exempt because a bug fix restores the system to its existing theory; its "why" is the broken behavior, which the bug-fix template variant already asks for. The other exempt types change no behavior a user would see. Refactors are not exempt, because the repo's convention already puts refactors on the feature skeleton with Summary carrying the motivation, and a refactor that cannot name who benefits is worth questioning.

## Format rule

The description must contain a heading reading `User story`, `Job to be done` or `JTBD` (case-insensitive, any heading level) whose section is non-empty once HTML comments and whitespace are removed. The section ends at the next heading. Comments are stripped before headings are looked for, so a heading quoted inside a guidance comment opens nothing, and the template's untouched section, which holds only a guidance comment, fails.

Either sentence form is fine inside, and neither is enforced:

- As a \<who\>, I want \<what\>, so that \<why\>.
- When \<situation\>, I want to \<motivation\>, so I can \<outcome\>.

## Workflow trigger

The workflow runs on `pull_request` with types `opened`, `edited`, `synchronize` and `reopened`. `edited` is what lets fixing the title or description re-run the check without a push; `synchronize` keeps a result attached to the newest head commit, which is what branch protection reads.

It uses `pull_request`, not `pull_request_target`, and `contents: read`. The check needs nothing but the event payload and a checkout of its own script, so it never needs a write token or secrets, and the fork-safety questions `pull_request_target` raises do not arise. The title and body reach the script through `env:` and are never interpolated into the `run:` shell, since both are author-controlled text.

Making the check required is a branch-protection setting, an admin step outside the repository. Until an admin adds `PR user story` to the required checks, a red result is visible but does not block merging.

## Rejected alternatives

- **Enforcing in the claude-review gate** – the review pipeline is already a required check and reads the description. But its verdict is computed by load-bearing scripts with documented traps (`docs/pr-review-gate.md`), it runs on `pull_request_target`, and a model-driven review is a slow, costly place for a check a regex answers. A separate, cheap job fails fast and fails for one reason.
- **Enforcing the exact sentence pattern** – matching "As a … I want … so that …" is brittle against ordinary phrasing and punctuation, and it pushes authors toward filling the pattern rather than saying something true. The check enforces that the section exists and has content; review judges its quality.
- **Detecting which template variant the description uses** – the variants differ only in headings an author is free to rename or delete. The title already follows conventional commits, so its type is a cleaner and more honest signal of what kind of change the PR claims to be.

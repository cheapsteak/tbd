# PR user-story check

## Problem

A feature PR whose description never says who the change is for, or what it lets them do, can only be reviewed as code. The reviewer cannot judge whether the change does the right thing, only whether it does the thing it does. Agents writing descriptions skip that context as readily as people do.

## Decision

Every feature PR description carries a `## User story` section with real prose in it. Two mechanisms carry that rule, and a third is built and held in reserve:

- **The PR template** – `.github/PULL_REQUEST_TEMPLATE.md` puts a `## User story` section at the top of the feature skeleton, with a guidance comment naming both sentence forms and the exempt title types.
- **A guardrail nudge at `gh pr create`** – the `pr-user-story` rule under `.claude/hooks/guardrails/rules/`. It is informational and never blocks. It exists so an agent writes the section on the first try, which is when it is cheapest to write.
- **A CI check, off** – the `PR user story` job in `.github/workflows/pr-user-story.yml` fails a feature PR without a filled section. It is not triggered on pull requests. The template and the nudge are expected to be enough, and a failing check costs every author a red PR and an edit; that cost is worth paying only once there is evidence the cheaper mechanisms do not hold.

The nudge and the check agree because they call one module, `.github/workflows/pr-user-story/check_user_story.py`: the workflow runs it as a script, and the guardrail loads it by path. The exemption list and the section rule therefore live in one place and cannot drift between the nudge and the check. The module's tests run in the `test.yml` workflow whether or not the check is on, so the reserve stays working. The guardrail reuses the `gh pr create` tokenizer from `pr_worktree_link.py`, which already handles heredoc bodies, `$(…)` substitutions and chained commands.

## Exemption rule

The PR title decides. A title whose conventional-commit type is `fix`, `docs`, `chore`, `test`, `ci`, `build` or `revert` needs no story; the type matches case-insensitively and may carry a `(scope)` and a `!`, so `Fix(app)!:` is exempt. GitHub's own Revert button writes `Revert "…"` with no colon, and that form is exempt too. Every other title needs a story: `feat:`, `refactor:`, `perf:`, and an untyped title alike.

Bug fixes are exempt because a bug fix restores the system to its existing theory; its "why" is the broken behavior, which the bug-fix template variant already asks for. The other exempt types change no behavior a user would see, and a revert's story is the one the reverted PR already told. Refactors are not exempt, because the repo's convention already puts refactors on the feature skeleton with Summary carrying the motivation, and a refactor that cannot name who benefits is worth questioning.

## Format rule

The description must contain a heading reading `User story`, `Job to be done` or `JTBD` (case-insensitive, any heading level, a trailing colon allowed) whose section is non-empty once HTML comments and whitespace are removed. The section ends at the next heading. Comments are stripped before headings are looked for, so a heading quoted inside a guidance comment opens nothing, and the template's untouched section, which holds only a guidance comment, fails.

Either sentence form is fine inside, and neither is enforced:

- As a \<who\>, I want \<what\>, so that \<why\>.
- When \<situation\>, I want to \<motivation\>, so I can \<outcome\>.

## The CI check and when to turn it on

**When.** Turn the check on only if field evidence shows feature PRs merging without a filled user story despite the template and the nudge – for example, a run of merged `feat:` PRs whose descriptions leave the section empty or delete it. Absent that evidence, the check stays off.

**How.** In `.github/workflows/pr-user-story.yml`, replace the `workflow_dispatch:` trigger with

```yaml
on:
  pull_request:
    branches: [main]
    types: [opened, edited, synchronize, reopened]
```

and delete the job's `if: github.event_name == 'pull_request'` line. While the check is off, `workflow_dispatch` is its only trigger, and that `if:` makes a manual dispatch skip the job cleanly, since a dispatch carries no PR title or body to judge. For a red result to block merging, an admin also adds `PR user story` to the required checks in branch protection, a setting outside the repository; without that step the check is visible but advisory.

**Trigger design.** `edited` is what lets fixing the title or description re-run the check without a push; `synchronize` keeps a result attached to the newest head commit, which is what branch protection reads.

The workflow uses `pull_request`, not `pull_request_target`, and `contents: read`. The check needs nothing but the event payload and a checkout of its own script, so it never needs a write token or secrets, and the fork-safety questions `pull_request_target` raises do not arise. The title and body reach the script through `env:` and are never interpolated into the `run:` shell, since both are author-controlled text. The checkout persists no credentials, since nothing after it needs the token.

The script that judges a PR is the PR's own copy, so a PR could loosen the check that judges it. That is accepted rather than defended against: the change sits in the diff in front of the reviewer, as any edit to a test would, and checking out the base branch's copy instead would leave a PR that changes the check unable to exercise its own version.

## Rejected alternatives

- **Turning the CI check on from the start** – the template and the nudge reach every author at the moment the description is written, at no cost to a correct PR. A failing check adds a red PR and an edit to every miss, and it is worth that only if the cheaper mechanisms are shown not to hold.
- **Enforcing in the claude-review gate** – the review pipeline is already a required check and reads the description. But its verdict is computed by load-bearing scripts with documented traps (`docs/pr-review-gate.md`), it runs on `pull_request_target`, and a model-driven review is a slow, costly place for a check a regex answers. A separate, cheap job, if one is needed, fails fast and fails for one reason.
- **Enforcing the exact sentence pattern** – matching "As a … I want … so that …" is brittle against ordinary phrasing and punctuation, and it pushes authors toward filling the pattern rather than saying something true. The check enforces that the section exists and has content; review judges its quality.
- **Detecting which template variant the description uses** – the variants differ only in headings an author is free to rename or delete. The title already follows conventional commits, so its type is a cleaner and more honest signal of what kind of change the PR claims to be.

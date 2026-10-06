# Human design confirmation in the PR review gate

## Summary

The repo's rule is that a human answers the brainstorming questions behind a
spec, and that work which revises the system's theory ships with a spec. A gate
that checks only that a spec is referenced cannot tell who chose the design: a
spec whose questions an agent answered for itself passes, even when the PR
discloses that "a human needs to confirm" it. Field evidence showed a second
gap in the same lens: a script framed around one project's database naming rule
passed because the conventions specialist accepted user-land placement and a
required `--prefix` argument as evidence of generality, and grepped the diff
instead of reading it.

This design makes three changes:

- **Generality.** User-land placement or a required parameter does not make a
  change general. A script or doc that encodes one project's naming, layout or
  tooling convention is Medium severity unless that convention is itself
  configurable. The conventions specialist reads new scripts and docs in the
  diff in full rather than grepping them.
- **Human design confirmation.** A spec the PR adds or modifies does not satisfy
  the spec requirement until a human has confirmed its design. A spec whose
  brainstorming questions an agent answered, or that no human has confirmed, is
  Medium severity. A PR's own disclosure that a human must still confirm is the
  finding, not a waiver of it.
- **Agents cannot confirm.** The confirmation is a fact the pipeline computes,
  and a guardrail stops agent sessions from posting it.

The repo owner made each of these decisions; this spec transcribes them.

## The confirmation gesture

A human clears the finding by leaving an **inline review comment on the spec
file** (a file under `docs/specs/` that the PR changes) whose body says they
confirmed the design. Each spec the PR adds or modifies needs its own
confirmation; the computed fact names every confirmed spec path, and the
conventions specialist clears only those. The phrase is matched by
`\bI\s+(?:have\s+)?confirmed\s+the\s+design\b`, case-insensitively: "I
confirmed the design" or "I have confirmed the design". A negation ("I have not
confirmed the design") does not match.

Nothing else clears it:

- **PR-level comments** – a confirmation belongs on the design itself, where it
  is anchored to the text being confirmed.
- **The PR description** – the author can rewrite it at any moment, and the gate
  already denies it the power to clear findings.
- **Text inside the spec** – an agent can write that text.
- **Discussion** – the merge step may weigh discussion against other findings,
  but never against this one.

A comment does not trigger the review workflow, and re-running the check
replays the old event, so a confirmation takes effect on the next pushed commit;
an empty commit is enough. The gate normally skips re-review while the diff is
unchanged and re-asserts the previous verdict, but `prepare.py` computes the
confirmation before that decision and does not re-assert a prior `REJECT` while
a confirmation exists. The prior verdict's marker does not record which
confirmations that review saw, so every push of an unchanged, rejected diff with
a confirmation present gets a full review — spending a review, the cheap
direction to fail.

## Computing the fact

Agents post through their human's own GitHub account, so neither the model nor a
login check can tell an agent's comment from the human's. Leaving the judgment
to the model would also make it vary run to run. `prepare.py`, the deterministic
step that runs before the review session, therefore computes the fact:

- **Fetch** – `GET /repos/{owner}/{repo}/pulls/{n}/comments`, paginated, through
  the pipeline's single `gh` boundary.
- **Filter** – keep a comment only when all of these hold:
  - its `path` starts with `docs/specs/`;
  - its author is not a bot: `user.type` is not `Bot` and the login does not end
    in `[bot]`;
  - its body matches the confirmation phrase;
  - its body carries no agent marker: `claude.ai/code/session_`,
    `Claude-Session:`, `Generated with [Claude Code]`, `Co-Authored-By: Claude`,
    or the robot emoji (matched case-insensitively).
- **Report** – write `design-confirmation.txt` to the workspace root in one of
  three states: `CONFIRMED` with each confirming login and spec path, `NONE`, or
  `UNAVAILABLE` when the fetch failed. `UNAVAILABLE` is treated as not confirmed
  and reported in the review diagnostics, so a failed fetch can never pass a
  spec.

The conventions specialist reads that file and is told that only `CONFIRMED`
clears the finding. Like every other file the pipeline reads back, a copy the PR
commits is deleted before anything runs, so a PR cannot forge the result.

## The guardrail

Marker detection is heuristic, so the agent side has its own control. The
`design-confirmation` rule in `.claude/hooks/guardrails/` denies a Bash command
that posts to a PR's review surface (`gh pr review`, `gh pr comment`, or
`gh api` against `pulls/<n>/comments`, `pulls/<n>/reviews`,
`pulls/comments/<id>` for replies and edits, or GraphQL, matched whole because
the query can sit in a file) when the phrase appears in the command text or in a body file
the command names. Its deny message tells the agent that a human must leave the
comment. The rule shares the gate's phrase regex, and a test pins the two
together.

Posting commands are detected only in the command's own lines, after heredoc
bodies are split off, so writing a doc or script that describes the rule is not
a post. The phrase is searched everywhere, heredoc bodies included, because
`--body "$(cat <<'EOF'` is the usual way to compose a review body.

## Known limits

- **The guardrail binds only sessions that load this repo's guardrails.** An
  agent running outside this checkout, or a harness that ignores
  `.claude/settings.json`, is not stopped. It also matches only the Bash tool: an
  MCP GitHub tool that posts review comments is not intercepted.
- **Marker detection is heuristic.** An agent that omits the markers and runs
  where the guardrail does not load can post a comment the gate counts. The gate
  reduces the risk; it cannot prove who typed a comment posted from a human's
  account.
- **Earlier confirmations persist.** A confirmation stays counted after the spec
  is edited further in the same PR, including on an outdated diff line.
- **Specs merged earlier are out of scope.** The check covers specs the PR adds
  or modifies; a spec merged by an earlier PR was gated there.
- **This PR cannot exercise its own gate changes.** The review workflow runs on
  `pull_request_target` and restores the pipeline from the base branch, so the
  new behavior first runs on the PR after this one merges.

## Rejected alternatives

- **The spec records the human's answers in-file** – an agent can write that
  text as easily as a human, so it proves nothing about who chose.
- **A PR-level comment** – the owner wants the confirmation on the design itself,
  anchored to the spec rather than floating in the PR conversation.
- **An author-login check alone** – agents post through the human's own account,
  so the login is the human's either way.
- **Letting the model judge authorship from the thread** – it has no more
  information than the filter, and a computed fact applies the same rule on
  every run.

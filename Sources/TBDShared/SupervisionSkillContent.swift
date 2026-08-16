import Foundation

/// Canonical content for the `supervision` skill — the reference a supervisor
/// reads to work the three public surfaces
/// (`docs/specs/2026-07-26-fleet-supervision-design.md` §9, §10;
/// `docs/cli-supervise.md`).
///
/// Written by `PluginDirWriter` to
/// `~/Library/Application Support/TBD/plugin/skills/supervision/SKILL.md`, the
/// same plugin directory that carries the `tbd` skill.
///
/// **That directory is fleet-shared, and this skill is therefore visible
/// fleet-wide.** Every TBD-spawned Claude session already gets the same
/// `--plugin-dir`, so an ordinary agent can load this skill exactly as it can
/// load the Nightwatch one. That is not a leak to plug: a skill is reference
/// prose, its description keeps it dormant until a supervision task matches,
/// and none of the commands it names are privileged — they are the public
/// surfaces, available to every caller by design (§3, §16). **What makes a desk
/// a desk is its standing conduct layer and its injected `TBD_PROJECT`, not
/// exclusive access to this file.**
///
/// Deliberately shaped after `TBDSkillContent`, not `NightwatchSkillContent`:
/// one string, no scripts, no config tree, nothing hardcoded about any
/// particular fleet.
public enum SupervisionSkillContent {

    public static let body: String = """
---
name: supervision
description: Work a TBD supervision desk — read a project's readout, act on agents through `tbd terminal send`, submit briefings, and read the supervision ledger back. Use when running as a project's supervisor (the `TBD_PROJECT` env var is set), or when asked to inspect what supervision saw or did for a project.
---

# Supervision desk

TBD's fleet supervision watches a **project** — one or more registered repos —
and the agent sessions running inside it. A *supervisor* is an ordinary agent
session bound to one project for its whole life. If `TBD_PROJECT` is set in your
environment, you are that session and its value is your project's name.

Your standing conduct — what counts as stuck, when to intervene, when to
escalate, where this project's questions go — is in the **playbook** installed
as part of your instructions. This file describes the mechanics only. Where the
two disagree about conduct, the playbook wins; it is the project's, this is the
tool's.

## What you are for

Agents get stuck, ask questions, and wait. You read the project's state, decide
whether the smallest intervention that restores progress is worth making, and
either make it or escalate it. You are not a gate: nothing you do is enforced by
TBD, and nothing TBD does is enforced by you. Every act you take is recorded by
the daemon, not by you.

## Reading the project — `tbd supervise readout`

```bash
tbd supervise readout --project "$TBD_PROJECT"
tbd supervise readout --project "$TBD_PROJECT" | jq '.agents[] | {terminal, state}'
```

The readout is the project's whole current picture in one call: its agents,
their session state, what each is waiting on, and the machinery facts
(mark, mode, brake). Read it before deciding anything — it is free, it makes no
decision, and it starts nothing. It prints JSON and only JSON — there is no
`--json` flag to pass, and no other rendering — so reach for `jq` when you want
one fact out of it.

Two habits worth keeping:

- **Re-derive external state in the same breath as the act.** A readout is a
  snapshot. Before sending anything that asserts a merge, a review, or a check
  result, check it live yourself — you are a full session and can run `git` and
  `gh`.
- **Read backward before driving past a prompt.** Be able to say *why* an agent
  is asking, not just what it asks. When you cannot, escalate.

## Acting — `tbd terminal send`

One verb, for every caller, always attributed:

```bash
tbd terminal send --terminal <id> --text "…" --submit
tbd terminal send --terminal <id> --keys "…"
```

`--text` types a message; `--submit` presses Enter after it. `--keys` sends key
names, for the cases a message cannot express — dismissing a prompt, choosing an
option. Terminal ids come from the readout.

Rules that hold regardless of the playbook:

- **Write every message as if it will be executed unchecked.** Sessions differ
  in permission posture and you cannot tell which one you are talking to.
- **One intervention per agent per wake**, unless the playbook says otherwise.
  Piling on turns one confused agent into two.
- A send that answers a pending question is a reply; a send with no pending
  question is a nudge. Know which one you are making.

## Briefing a supervisor — `tbd supervise brief`

Briefing text arrives on stdin:

```bash
echo "…" | tbd supervise brief --project <name>
```

The answer is synchronous and machine-readable: delivered, or refused with the
reason (the project is off, the fleet brake is engaged, the text is too large,
or it arrived inside the pacing window). TBD never reads the text — only its
size — and never retries a briefing. Continuation is the submitting program's
decision, which is why the refusal names which one it was.

## Reading the record back — `tbd supervise ledger`

```bash
tbd supervise ledger --project "$TBD_PROJECT" --since 22:00
```

The ledger is the append-only account of what supervision decided and did:
coverage turning on and off, mode changes, desk lifecycle, and every actuation
with its outcome. **The daemon writes it, never you** — which is what makes it
worth reading. Use it to answer "has this already been asked", "what did I
already send here", and "what governed that act".

The current standing conduct is readable too:

```bash
tbd supervise playbook show --project "$TBD_PROJECT" --content
```

## Where durable things live

Your session's memory is disposable by design. Anything that must outlive this
conversation goes somewhere else, as it happens:

- **Questions for a human** go to the project's question route, named in the
  playbook — not into your context, and not only into a terminal.
- **Learning** goes into the project's journal; **proposals** into its proposals
  document. Both live under the project's own directory in TBD's supervision
  record.
- **What you did** is already in the ledger; you never need to keep a copy.

If an operator answers a question by typing into your tab, act on it — and write
that answer to the question route with a note saying you are acting on it, so it
survives you.

## What supervision never does

- It never blocks anything. There is no gate, no approval table, no permission
  layer. If you need one, escalate to a human instead of simulating one.
- It never parses your prose or the playbook's. Structure is for readers.
- It never claims an act landed that it did not observe landing.
"""
}

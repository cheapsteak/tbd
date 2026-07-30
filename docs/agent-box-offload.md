# Offloading TBD sessions to the agent box

**Date:** 2026-07-30
**Status:** Plan + measured baseline. Nothing is offloaded yet — the box cannot
clone (see "What still blocks a live trial").
**Companion:** [`docs/remote-provider-contract.md`](remote-provider-contract.md)
— the contract this rides on. The provider itself (`agentbox`) lives in the
longeye monorepo and is not referenced by TBD's code.

## Why offload at all

Not wall-clock. The laptop is out of memory.

Measured 2026-07-30 01:42 PDT, with the fleet up:

| Metric | Value |
|---|---|
| Physical memory | 24 GB, 32% free |
| **Swap** | **11.58 GB used of 12.29 GB — 707 MB free** |
| `claude` processes | 38, ~5.5–5.8 GB RSS total, mean ~150 MB |
| `node` processes | 29, 1.42 GB |
| `tmux` processes | 19, 0.02 GB |
| TBD app + daemon | 2, 0.09 GB |
| All processes | 14.68 GB |
| Active worktrees | 46 (41 monorepo, 4 TBD, 1 scratch), 8 tmux servers |

Swap is 94% consumed. That is the number the offload is trying to move, and it
is why "keep the busy, move the idle" is the right split: an idle session costs
essentially the same resident memory as a busy one (~150 MB) while producing
nothing. Idle sessions are pure carry cost.

This baseline is perishable — it describes one particular night's fleet. Retake
it the same way before and after any trial rather than comparing to this table
months later.

### What a remote session actually saves

A remote session has **no local agent process**. TBD holds only a row and polls
the provider. So the saving per moved session is the whole ~150 MB `claude` RSS
plus its share of the 1.42 GB of `node`, not a fraction of it. Moving 10 idle
sessions should return roughly 1.5–2 GB of resident memory — which, at 707 MB of
free swap, is the difference between thrashing and not.

## The split

Decided already, recorded here so it is reviewable:

- **Move:** idle, patient, API-bound work — long-poll watching, PR triage,
  review-thread replies, docs and knowledge harvesting.
- **Keep local:** anything interactive, anything on the local toolchain
  (`just dev`, Storybook, a browser, the local DB), and desk/CI work.

Two constraints stand, and neither is negotiable per session:

- **No production CJI on the box, ever.**
- **No untrusted-content ingestion while the plaintext token is in play.** The
  Claude setup token is injected as `CLAUDE_CODE_OAUTH_TOKEN` into every
  per-repo tmux server, so any child process an agent spawns can read it.

### One structural limit that is not a problem

The provider's `create` allow-lists exactly one repo shorthand, `longeye-app`.
That sounds restrictive but 41 of 46 active worktrees are monorepo-based, so it
covers ~89% of the fleet. (`longeye-app` is a redirect alias for the renamed
`longeye-ai/monorepo` — confirmed via `gh repo view longeye-ai/longeye-app`,
which resolves to `monorepo`. The minter's tokens are scoped to `monorepo`, so
the alias and the token scope agree.)

The 4 TBD-repo worktrees **cannot** be offloaded at all: TBD's own repo is not
an allow-listed shorthand, and adding one is a provider-side change.

## Candidate workloads

Chosen from the live fleet, not hypotheticals. Predictions recorded before any
trial runs, so they can be scored honestly afterward.

| # | Candidate (live worktree) | Needs from the laptop | Verdict |
|---|---|---|---|
| 1 | **PR babysitting** — `🍼 Babysit Open PRs` | GitHub API + git only. No DB, no browser, no local toolchain. | **Move.** Best shape in the fleet: all API latency, long idle gaps, no local dependency. |
| 2 | **PR backlog triage** — `📋 PR Cleanup Plan` | GitHub API only. | **Move.** Same shape as #1; bursty reads, long think time. |
| 3 | **Docs / ADR review** — `🔐 Staff Access ADR Review`, `🧵 Chat Summarization Design` | Repo checkout for reading and writing. | **Move, with care.** Cheap to move. Verify the specific doc carries no CJI before moving. |
| 4 | **Repo research sweeps** | The embedding store at `~/Desktop/proj/longeye-embeddings` is **local**. | **Keep local for now.** Looks like an ideal candidate — pure API latency — but the corpus is a local artifact. Moving the workload without the store just makes it slower. Reconsider if the store is ever hosted. |
| 5 | **Monitor / chat UI work** — `monitor-ui-polish`, `panel-width-floor`, `search-unlock`, `🖼️ Details image drop-ins` | `just dev`, Storybook, a browser. | **Keep local.** Disqualified by the local toolchain. |
| 6 | **`📌 RDS Proxy Pinning Triage`** | The read-only prod Postgres proxy on `127.0.0.1:5433`. | **Keep local.** Needs a local port, and it is prod data. |
| 7 | **CJI-adjacent work** — `🚔 San Bernardino Triage`, `🔎 San Bernardino Review`, `🎓 SBPD Training Materials`, `🔍 OKC Dig Audio Discrepancy` | — | **Never move.** Excluded by the standing CJI constraint regardless of how patient they are. |

Candidates 1–3 are the trial set: three sessions, ~450 MB, enough to measure
without betting much on an unproven path.

## How we would know it worked

Measure the same way, before and after:

```sh
ps -axo rss=,comm= | awk '$2 ~ /claude$/ {n++; s+=$1} END {printf "%d procs, %.2f GB\n", n, s/1048576}'
sysctl vm.swapusage
```

Success is **free swap recovering**, and resident `claude` count dropping by
exactly the number of sessions moved. Wall-clock per task is explicitly not the
metric — a remote session is expected to be no faster, and the 60s provider poll
makes it feel slower.

Failure to move the needle would most likely mean the moved sessions were not
actually the resident ones. Check count, not just bytes.

## Failure modes

The question that decides whether a workload is a good candidate is not "is it
patient" but **"if it wedges, will anyone notice?"** A workload that can fail
invisibly is a bad candidate however patient it is.

| Failure | Detectable? | Recoverable without a human? |
|---|---|---|
| **Token revoked / invalid** | Poorly. `claude-auth-health` pages on 401, but it currently returns 403 for a healthy setup token and DMs the owner every 30 min (#18126) — so a real alert arrives inside a stream of false ones. | No. Needs `agentbox set-token` (a browser step). |
| **Clone / auth breakage** | Yes — `create` returns a `failed` record carrying the error text. This is exactly how the current minter gap was found. | No. The current instance needs an IAM change. |
| **Session invisible to TBD** | Yes, once the daemon is running: provider health surfaces in Settings, and absence from two consecutive snapshots reads as gone. | Partly — TBD re-describes on its poll. |
| **Permission prompt on a remote session** | Yes. `agent_state: waiting_input` comes from Claude Code lifecycle hooks, not screen scraping. | Yes — the `send` capability answers it without attaching. This is the failure mode that most threatened the whole idea, and it is genuinely covered. |
| **Provisioner dies mid-create** | Yes. A `starting` record whose pid is dead is reclassified `failed`. | Yes — a later create reclaims a `failed` slot. |
| **Box reboots** | Yes. Session ids are `<repo>/<slug>`, derived from the on-disk layout, so they survive reboots. | Sessions do not auto-restart; `agentbox restart` rebuilds tmux from meta. |

No `events` capability is implemented, so **60s polling is the floor** for every
state change above. Nothing here is real-time.

## What still blocks a live trial

Two blockers, both outside this document's reach, plus findings from dry-running
everything that is not blocked.

1. **No session can be created.** `agent-box-zionts-role` is missing the
   `invoke-agent-box-github-minter` policy that the working box's role has, so
   `git clone` fails and every `create` lands as `failed`. The fix is a
   monorepo terragrunt change already authored on another branch; after it
   merges someone must comment
   `atlantis apply -p management-agent-box-github-minter` — merging alone
   changes nothing. **This is a management-account IAM change and is Adam's
   call.**
2. **Remote sessions are invisible in TBD.** The running daemon binary predates
   the feature entirely — no `config.setRemoteBackends`, no `remote.providers`,
   no `RemoteProviderManager` — so the Settings toggle cannot even be set. Needs
   a rebuild + restart, which suspends ~52 live sessions at one instant and
   moves the machine-wide `tbd://` handler. **Held for Adam.**

### Findings from the parts that could be dry-run

The provider was exercised end to end against the rebuilt box under a stripped
environment (`env -i`), which is the case that matters because TBD's daemon is
GUI-launched and inherits almost nothing:

- `describe`, `list`, and `create` all behave per contract. `create` returns in
  seconds with `state: "starting"`, as required.
- **`stop` violates the contract two ways** (filed, monorepo #18142): stopping an
  already-dead session exits **1** with an error envelope instead of exiting 0
  with a terminal Session, and stopping an *unknown* id **creates a real
  session directory and `meta.json` on the box**, squatting that slug and adding
  a phantom entry to `list`. For TBD the first is the worse one: a user clicking
  stop on a visibly-dead session gets a hard permanent-failure error.
- **Session grouping will likely not work for this laptop.** The box reports
  `meta.repo` as `longeye-ai/longeye-app`, and TBD groups remote sessions by
  matching that against the local origin. This machine's monorepo origin is
  `longeye-ai/monorepo`, not `longeye-app`, so the match should fail and remote
  sessions will render ungrouped. Cosmetic, but it will look broken on first
  contact — worth knowing before the restart rather than after.

Related monorepo issues: #18126 (health check false alarm), #18128 (the token
does not self-expire), #18142 (the `stop` defects).

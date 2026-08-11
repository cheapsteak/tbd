# Cross-session messaging

Claude Code sessions can talk to each other directly. A session lists its
peers with `ListAgents` and sends one of them plain text with
`SendMessage`. On a single machine delivery is peer-to-peer: each session
binds its own Unix socket and publishes a small registry row on disk, and
messages travel socket-to-socket. No servers are involved, and neither is
TBD's daemon.

TBD's part is small: it names the sessions it spawns after the worktree
name you see in the sidebar, and it makes the peer registry whole across
TBD profiles. Everything else — the transport,
throttling, and inbound-safety rails — belongs to Claude Code. Upstream
reference: [Message your other Claude Code
sessions](https://code.claude.com/docs/en/cross-session-messaging).

## Versions

Two different floors apply, and they are not the same number.

- **TBD's Claude spawn path requires CLI ≥ 2.1.76.** TBD always passes
  `--name` when it spawns Claude, and `-n` / `--name` shipped in 2.1.76.
- **Messaging itself requires CLI ≥ 2.1.224.** That is when `ListAgents`
  and `SendMessage` arrived.

A session on anything in between (2.1.76 through 2.1.223) is perfectly
healthy — it gets a correct name and simply has no messaging tools.
Coordinate through `tbd terminal send` / `tbd terminal output` instead.

Below 2.1.76 the failure is loud rather than subtle: every Claude spawn
exits 1 in the pane with

```
error: unknown option '--name'
```

Fix it by updating the CLI (`claude --version` to see where you are;
Claude Code self-updates by default, so this is unusual).

## Confirming a session has it

Inside the session, run `/list-agents`. If messaging is active you get a
listing of peer sessions; if it is absent the command is not there.
`/status` is the other check — with messaging active it shows a
peer-address row for the session.

## Naming

TBD spawns each Claude session with `--name` set to the worktree's
**display name** — the human-visible, renamable name in the app — so the
names in `/list-agents` are the ones you already know from the sidebar.

Without that flag a session names itself after its working-directory
folder: a slug plus a random suffix, which never matches a name you chose
in the app.

`--name` is fixed at spawn. Renaming a worktree therefore applies at that
session's **next respawn or resume**; until then the running session
still answers to its spawn-time name. Nothing breaks in the meantime —
the listing tells the two apart, as described next.

## Addressing a peer when names collide

A name is a label, not a unique address. Two things make one name answer
for several sessions:

- **One worktree, several Claude terminals.** Every Claude session spawned
  in a worktree gets that worktree's display name, so a worktree running
  three Claudes shows three rows under one name.
- **Two worktrees, one name.** Display names are yours to choose and
  nothing stops you reusing one.

`/list-agents` handles this. Each row carries a short `[ref]` — an
identifier unique to that live session — alongside the name, working
directory, and status. Read the listing first, then:

- if exactly one row answers to the name you want, address it by name;
- if more than one does, address the one you want by its `[ref]`. The
  working directory and status in the row are how you tell which is
  which.

Pull a fresh listing rather than reusing one from earlier in a long
conversation — the pool changes as sessions spawn, respawn, and exit.

## Reach

- **On this machine** — the boundary is the OS user, not the Anthropic
  account. Every TBD session under your user is reachable from every
  other, across all TBD profiles, even when those profiles are logged
  into different Anthropic accounts. Your own plain-terminal `claude`
  sessions are in the same pool: TBD sessions can see them and they can
  see TBD sessions.
- **Expect CLI sessions.** Every registry row observed in practice has
  come from a terminal (`claude` on the command line, which is what TBD
  spawns).
- **Beyond this machine** — remote and web sessions are reachable through
  Anthropic's servers, same account only, and **reply-only**: a local
  session can answer a message from a remote or web session, but can
  never initiate one.

### When a peer you expected is missing

`/list-agents` is the authority. A session that does not appear in the
listing cannot be addressed, no matter what you know about it being
alive — so check the listing before concluding a message was lost.

Common reasons a session is absent:

- **It has no messaging.** Its CLI is below 2.1.224, or a killswitch
  variable is set in its environment (see [Killswitches](#killswitches)).
  Such a session never registers and never appears.
- **Its profile's registry was not unified.** TBD links each profile's
  registry to the shared host one when it seeds the profile, and that
  step is best-effort: if it fails, the profile keeps a private registry
  and its sessions see only peers spawned on the same profile. Respawn
  the session to retry the seeding; the daemon log records the failure.
- **It exited.** Rows are per live process; a session that ended is gone
  from the listing.

Falling back is always available: `tbd terminal send` /
`tbd terminal output` reaches any TBD-managed session through the
daemon, regardless of whether messaging is present.

## Killswitches

Messaging depends on a feature-flag evaluation, and several environment
variables switch that evaluation off:

- `DISABLE_TELEMETRY`
- `DO_NOT_TRACK`
- `DISABLE_GROWTHBOOK`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`

TBD's own spawn environment sets none of them. But TBD's free-form
[environment overrides](env-overrides.md) — settable at global, repo, or
profile scope — will happily set any of them, and the result is silent:
sessions spawn fine and simply have no messaging tools, with no error to
point at the cause.

To check, run this inside a session that is missing the tools:

```sh
env | grep -E 'DISABLE_TELEMETRY|DO_NOT_TRACK|DISABLE_GROWTHBOOK|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
```

Any hit is the explanation. Clear it in whichever override scope set it
(Settings → General for global, the repo settings pane for repo, the
model-profile sheet for profile) and respawn the session.

## Inbound policy

With no policy set, Claude Code delivers a message when sender and
receiver are in the same permission class. TBD spawns every Claude
session with permissions bypassed, so TBD↔TBD messages deliver with no
approval dialog out of the box.

A repo that wants something stricter sets `crossSessionInbound` in its
per-repo [Claude settings overlay](claude-settings-overlay.md) — a plain
JSON file at `~/tbd/repos/<repoID>/claude-settings.json`, editable in the
repo's settings pane, which deep-merges into the `--settings` overlay TBD
passes on every spawn:

```json
{
  "crossSessionInbound": "hold"
}
```

The three values are `accept` (deliver without prompting), `hold` (queue
for your approval), and `refuse` (reject inbound messages). The setting
is read fresh at spawn time, so it takes effect on the repo's next
session — fresh create, resume, wake, or profile swap alike.

## Not in TBD's actuation record

Native peer messages travel session-to-session over Claude Code's own
sockets and never transit TBD's daemon. They are therefore **outside
TBD's actuation record, in both directions, by design**. The record
attests everything sent through TBD's own transport (`tbd terminal send`
and the supervision paths built on it) and nothing else.

The practical consequence: a peer message is evidenced only by the
transcripts of the two sessions that exchanged it. If you need an act to
be in the record — for supervision, audit, or after-the-fact
reconstruction — send it through TBD's transport instead.

## The peer registry

Each live session publishes one small JSON file, `<pid>.json`, in the
`sessions/` directory of its Claude config dir. A row holds the pid, the
session id, the working directory, the tmux pane, the path of the
session's message socket, the session's name and where that name came
from, and a coarse status (`idle` / `busy` / `waiting` / `shell`) with a
timestamp. **It holds no transcript content** — it is an address book,
not a log. The sockets themselves live at `/tmp/cc-socks/<pid>.sock` and
are shared across the OS user.

Because the directory hangs off `CLAUDE_CONFIG_DIR`, each TBD profile
would otherwise keep a private registry and sessions on different
profiles would be invisible to each other. TBD prevents that by
symlinking each profile's `claude/sessions` to the `sessions` directory
of the host Claude config dir (`~/.claude` by default) when it seeds the
profile — the same host-mirror mechanism it already uses for `projects`,
`plugins`, `hooks`, `skills`, and `settings.json`. One shared index,
credentials still isolated per profile.

If the profile already had a registry of its own, its rows are **moved
into the shared one** before the link is made, so sessions that were
running at that moment keep their listing and simply become visible to
everyone else. Nothing is set aside or hidden: rows are named after the
process id, which is unique on your machine, so they merge without
clashing. The upgrade adopts your running sessions rather than
interrupting them.

That symlink is also why your plain-terminal sessions and TBD's sessions
see each other: the shared target is the host directory those sessions
already use. Since the mirror moves no transcript content, and
`projects/` (where transcripts do live) is already mirrored, this changes
discovery and nothing else.

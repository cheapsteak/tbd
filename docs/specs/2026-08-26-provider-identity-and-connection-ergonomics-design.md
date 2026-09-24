# Provider identity and connection ergonomics — design

**Date:** 2026-08-26
**Status:** Proposed; TBD half implemented, provider half filed as a dependency.
**Scope:** TBD-side only — the remote-provider desk, sidebar header, attach
resolution, and one optional additive field on the provider contract's
`describe` response. No provider repository is edited by this work.

## The problem

TBD lets a user register several entries against the same provider binary — an
`agentbox` pointed at one control plane and an `agentbox-staging` pointed at
another are the motivating pair. Four things then go wrong, and all four share
one root cause: **the surfaces answer a question the user did not ask.**

1. **Which provider am I looking at?** The sidebar header and the desk masthead
   both render `describe.name ?? config.name`. `describe.name` is the
   provider's *machine identifier for its own kind* — two registry entries
   running the same binary report the same one. Both rows therefore read
   "agentbox", the desk title reads "agentbox", and the only unique identity in
   the system, the registry key, is never on screen. A green badge over an
   empty list then reads as "staging is idle" when it is in fact "you are
   looking at management, which has no sessions."
2. **Is that session working?** `state: running` and `agent_state: unknown` is
   an explicitly specified combination in the contract, and it means *only*
   that a terminal exists. The desk tinted terminal-Running green — the same
   green the eye reads as progress — while the honest reading is "no machine
   interface reported what the agent is doing." A session blocked at a
   permission prompt and a session churning through a build are indistinguish-
   able at a glance.
3. **What did attach just do?** `RemoteAttachPager` resolves the provider
   config by exact registry name and, when the lookup fails, `continue`s: no
   tab, no error, no log line. A missing local transport dependency behaves
   the same way one step later — the PTY opens, the exec fails, the pane is
   blank. Both read as "attach is broken" rather than naming the cause.
4. **Is this list current, empty, or the wrong list?** Stale, never-
   snapshotted, successfully-empty and populated inventories collapsed into
   two empty-state strings.

## Principles this follows

- **The registry key is the identity.** `config.name` is unique by
  construction (`RemoteProviderRegistry.loadEntries` rejects duplicates) and
  is what every other subsystem keys on — the mirror's primary key, the attach
  selection, the notification route. It is therefore what the user must see.
  `describe.name` is a *kind*, and is shown as such or not at all.
- **The three axes stay separate.** Terminal liveness, agent attention, and
  filing are independent in the contract and stay independent on screen. This
  work adds a fourth reading — *attention explanation* — layered on the agent
  axis, never substituted for it.
- **A caller states what it knows, not what it hopes.** Every new string
  distinguishes an observation from an absence: "reports no sessions" is a
  different sentence from "no inventory yet", which is different again from
  "showing the last good inventory."
- **Never fall back to another provider.** Not for attach, not for identity,
  not for diagnosis. Where a resolution fails, it fails by name.

## Design

### 1. Provider identity block

The desk masthead leads with `config.name` — the registry key — and carries a
secondary identity block beneath it. Rows, in order, each omitted when its
source is absent:

- **Registered as** — `config.name`. Always present.
- **Provider kind** — `describe.name`, rendered **only when it differs** from
  the registry key, as "reports as <kind>". Two entries of the same kind then
  differ visibly on the line that matters and agree silently on the line that
  does not.
- **Identity pairs** — the new optional `describe.identity` map (below), well-
  known keys first (`account`, `environment`, `region`, `box`, `host`,
  `endpoint`) in that order, then every other key alphabetically. Rendered
  opaquely: TBD interprets nothing but the ordering.
- **Command** — the registry entry's `exec` (tilde-abbreviated) and its
  first argument when that is a subcommand or path, with every later argument
  redacted (see "Redacting the
  command line"). A reminder of what the entry runs, not a disambiguator: the
  registry key already tells two entries apart, and `describe.identity` names
  the backend each one is pointed at.
- **Version** — `provider_version` and the negotiated contract major.

#### `describe.identity` (new, optional, additive)

The contract has no field carrying *which backend account or environment a
registry entry is pointed at*, and TBD cannot derive it: the registry entry is
an executable path and a flag list, and the mapping from flags to control
plane is the provider's private business. So the honest TBD half is to specify
the field, decode it, render it, and degrade to the locally-derivable rows
above when it is absent.

Its shape deliberately reuses the pattern the contract already has for
provider-defined display data — `meta`'s flat string-to-string map with a
well-known key list — rather than inventing a rigid schema for facts that
differ per vendor. A provider that has an account id and an environment name
says so; one that has a box handle and a region says that instead.

**Non-secret by construction, and by belt-and-braces.** The contract states
the field carries display identity only and MUST NOT carry credential
material. TBD additionally filters what it renders: a key whose name matches
the secret vocabulary (`token`, `secret`, `password`, `passwd`, `key`,
`credential`, `auth`, `session_token`, `signature`, `cookie`) is dropped
entirely rather than shown, and a rendered value is truncated to 96
characters. The filter is TBD's, not the contract's — a provider violating the
contract should not be able to put a bearer token on a user's screen. Registry
args, which are user-authored and outside the contract's reach altogether, get
a stricter rule of their own, below.

#### Redacting the command line

The **Command** row shows the registry entry's args, which are user-authored
and can carry credentials the contract never sees. The rule is positional: the
row shows the command name, the first argument under the rule below, and one
`‹redacted›` marker for every argument after it, so the count of arguments
stays visible while none of their contents do. A redacted value never renders
as a prefix of itself, because a prefix of a secret is still part of the
secret.

The first argument is judged by one exhaustive rule, never by its content:

- **Contains `=`** – `--token=abc`, `-Dkey=value`, an env-style `TOKEN=abc`:
  the part before the first `=` is kept and the rest is redacted, whatever
  the name.
- **Starts with `-`, no `=`** – redacted whole, whether it is `--verbose`,
  `-t`, or `--tokenSECRET`. A value can be glued onto a flag of any length,
  and hiding a harmless flag costs only context.
- **Anything else** – shown verbatim: a subcommand or a path.

So `agentbox serve --control-plane staging` renders as
`agentbox serve ‹redacted› ‹redacted›`, and `agentbox --control-plane staging`
as `agentbox ‹redacted› ‹redacted›`.

**The trade.** The argv display is a convenience, and a leak is its only real
cost. Telling two registrations of the same kind apart is the registry key's
job, which is unique by construction, and "which backend is this entry
pointed at" is what `describe.identity` exists to answer. What the rule gives
up is reading a value such as `staging` off the desk. It deliberately does not
try to tell a secret from an ordinary value: no argv rule can decide that in
general, since a flag's value may itself begin with `-`, may be letters-only,
or may be any length, and any rule that judges shape is one shape away from
showing a credential. The rule does not show flag names after the first
argument either, because by position alone a flag name cannot be told apart
from a dash-prefixed value, and it hides a dash-prefixed first argument whole
for the same reason: a flag glued to its value has no separator to split on. This follows the fixed-position approach the
daemon already takes for tmux argv in `TmuxManager.redactedArguments`, which
hides the operand of tmux's `-e` by structure rather than by what the value
looks like.

One residual remains by construction: a credential placed bare in first
position, with no dash and no `=`, is shown. A registry entry whose first
argument is a secret should move it behind a flag or into the provider's own
configuration.

Rendered identity values, though not command args, are cut at 96 characters.
Identity values are account ids, region names and box handles, so anything
longer is either not identity or not readable, and the cut bounds the damage
in both cases.
It is never used to shorten a secret: a secret-keyed identity pair is dropped
entirely, not truncated.

### 2. Attention, distinct from liveness

`RemoteProviderDeskSummary` gains two derived readings over the mirror rows it
already counts:

- **`needsAttention`** — sessions whose agent axis is `waiting_input`. These
  are the rows a human has to act on, and the desk lists them by name with
  their explanation rather than leaving them as a digit in a strip.
- **`unattributedRunning`** — sessions with a live terminal and `agent_state:
  unknown`. The desk states the count in words: these are running terminals
  whose agent progress is not reported, and terminal liveness is not agent
  progress. Terminal-Running loses its green tint; green now means the agent
  axis says `working`, and nothing else does.

**The explanation.** `RemoteAgentAttention` turns one mirror row into one
sentence, most specific source first:

1. `pending_question` — the contract's structured blocked-on-a-question field,
   now decoded TBD-side for the first time. "Blocked on a question: <prompt>"
   plus the option labels.
2. `agent_state_reason` — the free-form provider string, with the contract's
   own example value `permission_prompt` humanized to "Blocked on a permission
   prompt" and anything else rendered verbatim.
3. The bare `waiting_input` state — "Waiting for input."

`pending_question` belongs to the liveness axis, so `projectedForStaleSnapshot`
clears it alongside `agent_state`: a cached "blocked on a question" over a
provider that has stopped answering is a claim about right now that TBD cannot
make.

### 3. Attach preflight

`RemoteAttachPreflight` resolves a selection to a spawnable command, or to a
named diagnosis, as a pure function over the provider list, the mirror, and an
executable-probe closure. Its resolution is exact-match-or-fail on the registry
key — the type has no way to express a fallback, which is how "never silently
fall back to another provider" becomes a property of the code rather than a
rule someone must remember.

Diagnoses, each with a title and an actionable sentence naming the provider:

- `providerNotRegistered` — the selection names a provider no registry entry
  matches (a renamed or removed entry, or a mirror row that outlived it).
- `sessionBelongsToAnotherProvider` — this session id exists, under a
  different registry entry. Names both.
- `attachUnsupported` — the provider does not declare the `attach` capability.
- `executableMissing` / `executableNotRunnable` — the registry entry's `exec`
  is absent or not executable. This is the missing-local-transport-dependency
  case, and it is the one that previously produced a blank pane.

`RemoteAttachPager` renders the diagnosis in the pane instead of skipping the
mount, so the failure appears where the user was looking.

### 4. Inventory state

`RemoteProviderInventoryState` collapses (health, snapshot timestamp,
freshness readability, row count, other providers' row counts) into one of
five readings, each with its own sentence:

- **`noInventoryYet`** — no successful snapshot has ever been accepted.
- **`freshnessUnknown`** — the daemon could not read the freshness record, so
  it cannot say whether what is on screen is current.
- **`stale`** — a prior good inventory, now unrefreshed; quotes its age.
- **`emptySuccess`** — a snapshot succeeded and this provider reports nothing.
  This is the reading that was missing, and it is the exact state the
  motivating confusion produced.
- **`populated`** — count and age.

`emptySuccess` and `noInventoryYet` additionally carry a **cross-provider
note** when other registered providers do hold sessions: "3 sessions are
registered under other providers (agentbox-staging: 3)." That sentence is the
direct answer to "did I just inspect the wrong provider", stated by TBD at the
moment the question arises rather than left to the user to reconstruct.

## What is deliberately not here

- **No answering of pending questions.** The contract makes the field display
  data with no answer verb; answering stays `attach`/`send`.
- **No feature flag.** Nothing here acts autonomously, mutates persisted
  state, or replaces a load-bearing path — the gate the repo's flag rule names.
  The behavior changes are: additional read-only rows, changed wording, a
  changed tint, and an error surfaced where a silent skip used to be.
- **No provider-side work.** The `identity` field is specified and consumed;
  emitting it is a provider dependency, filed separately.
- **No new durable external resource**, so no reconciler question to answer:
  every path here reads the existing mirror and spawns nothing that outlives
  its pane.

## Rejected alternatives

- **Deriving environment from the exec path or args.** Pattern-matching
  "staging" out of a flag list is a guess that is wrong precisely when it
  matters (an entry named `agentbox-staging` pointed, by a stale flag, at
  production). The command line is shown verbatim instead and left for a human
  to read.
- **A rigid `identity` schema (`account`/`environment`/`box` as typed
  fields).** Every vendor's identity has a different shape; a fixed schema
  forces providers to either lie or leave it empty. The flat map with a
  well-known ordering matches what the contract already does for `meta`.
- **Suppressing `describe.name` entirely.** It is genuinely useful when it
  differs from the registry key (a registry entry named `staging` running the
  `agentbox` binary), and useless noise when it matches. Conditional rendering
  keeps the signal and drops the noise.
- **Blocking attach when the provider looks unhealthy.** Already considered
  and rejected in `AppState+RemoteAttach`: a failing `list` says nothing about
  whether `attach` can connect. The preflight added here only reports facts
  local to the laptop — registration, capability, and the executable itself.

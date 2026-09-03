# Deleting a remote session, and moving transcripts between machines

**Date:** 2026-09-02
**Status:** Approved, not yet built.
**Depends on:** [`docs/remote-provider-contract.md`](../remote-provider-contract.md)
(the verb/capability model, the Session object, the error model, and the
`transcript` format), and
[`2026-08-16-remote-lane-archive-design.md`](2026-08-16-remote-lane-archive-design.md)
(archive and revive, whose deliberate cut this design reverses).

## Summary

A remote agent session cannot be destroyed. It can be stopped, which ends its
compute, and archived, which retires it from the working set, but nothing
removes it — so sessions accumulate forever, and the ones a user has finished
with are the ones that accumulate fastest.

Destroying a session would also destroy the only copy of its conversation,
because a remote session's transcript lives on the remote machine and TBD keeps
nothing. So this design adds two things at once, and they are one thing: a
`delete` verb, and a transcript exchange that gives a conversation an identity
independent of the machine that hosted it. A transcript can be retained on the
provider's own store and read back by an opaque key long after its session is
gone; a transcript from anywhere — including a local session on this Mac — can
be put into that store and used to seed a new remote session.

Delete is then destruction with a receipt, and the receipt is not a special
form: it is an ordinary exchange key.

## The gap

Three separate absences meet here.

**Nothing removes a session.** `stop` ends compute and explicitly does not
retire the session; `archive` retires it from the working set and explicitly
does not end compute. The contract names no third act, and
[`2026-08-16-remote-lane-archive-design.md`](2026-08-16-remote-lane-archive-design.md)
recorded that as a deliberate cut: retiring and destroying are different acts,
and only the first was specified. That reading was right about the distinction
and wrong about the consequence — a fleet with no reclaim path fills up.

**Archived sessions render anyway.** The contract requires a provider to keep
archived sessions in `list` and leaves it to the caller to decide which a human
sees: display policy applied to a complete inventory. TBD never wrote that
policy. `RepoSectionView.matchedRemoteSessions` and `RemoteSectionView.sessions`
filter on `dismissed` alone, and `payload.isArchived` has exactly one consumer
in the tree, in the daemon. So archiving a remote lane retires the worktree row
and the session immediately reappears beneath it as a bare session row, which
the only removal gesture — Dismiss, offered only for a `gone` session — cannot
touch. Archiving a lane creates a row nothing can remove.

**No transcript ever reaches this machine.** The contract defines a
`transcript` verb returning Claude Code JSONL, and TBD has never invoked it:
`"transcript"` as a capability string appears nowhere in `Sources/`. `log` is
fetched on demand and rendered without being stored. TBD's `remote_session` row
holds the last `list` payload — id, title, state, `meta`, `created_at` — and no
conversation. A session destroyed today takes its history with it.

## Contract additions

All additive within contract major 2: four capability-gated verbs and one
capability-gated field on an existing verb. No required verb changes, no field
is removed or renamed, and no existing semantics move, so no major bump. None of
this touches `stop`'s status; "delete ends compute" is a statement about
`delete`, and a provider's `stop` declaration is unaffected.

| Verb | Gate | Invocation | stdin | stdout | Timeout |
|---|---|---|---|---|---|
| `delete` | capability `delete` | `<exec> delete <id> [--retain]` | — | JSON result | 30s |
| `retain` | capability `retain` | `<exec> retain <id>` | — | JSON receipt | 60s |
| `import` | capability `import` | `<exec> import` | JSONL | JSON receipt | 60s |
| `recall` | capability `recall` | `<exec> recall <key>` | — | JSONL | 60s |

### `delete <id> [--retain]`

Destroys the session: ends its compute if it is running, and removes it from the
inventory permanently.

- **A provider MUST NOT declare `delete` unless a successful `delete` of a
  running session also ends that session's compute.** A provider that cannot end
  compute for a given session MUST refuse with exit 1 rather than remove the
  record. The contract already recognizes backends with no client-facing kill
  and forbids them from declaring `stop`; such a backend declaring `delete`
  would leave compute running that nothing enumerates and no reconciler can
  reach.
- **Response is `{"id": "<id>", "deleted": true|false}`** — `true` when this call
  destroyed a session, `false` when there was nothing to destroy. Deliberately
  **not** a Session object: a caller that has just been told a session no longer
  exists must not be handed inventory-shaped data, which the adoption path would
  read as a session to adopt.
- **Idempotent.** Deleting an unknown or already-deleted id exits 0 with
  `"deleted": false`, matching `stop` and `archive` and the `rm -f` convention.
- **Filing is orthogonal.** An archived session may be deleted; archive state
  never gates it.
- **`delete` overrides the exited-session retention SHOULD.** Providers keep
  exited sessions listable for at least 24 hours so a disappearance can be told
  apart from transport drift; a deleted session is exempt, because its
  disappearance was requested rather than observed.
- **A provider declaring `events` MUST emit `{"event": "removed", "id": ...}`**
  after a successful delete. `removed` already means "stop tracking this at
  all", which is exactly the fact.
- **`--retain` retains before destroying**, and is valid only where the provider
  also declares `retain`. With the flag, the response carries
  `"retained": {"key": ..., "expires_at"?: ..., "bytes": ...}`; without it, no
  retention happens and no such object appears. Retention is never implied by
  capability presence — a caller that did not ask for storage must not cause
  storage to be allocated, and a response shape must not depend on which
  capabilities the provider happens to hold.

There is no `--force` at the contract layer. Refusing to destroy live or dirty
work is a caller policy, and the caller already has `stop` to sequence.

### `retain <id>` and `import`

Both put a transcript into the provider's durable store and return a receipt:

```json
{"key": "opaque-provider-string", "expires_at": "2026-10-01T00:00:00Z", "bytes": 148213}
```

`retain <id>` stores the transcript of a session this provider owns. `import`
reads Claude Code transcript JSONL on stdin and stores it, with no session on
this provider involved at all — that is how a conversation from another machine,
including a local one, enters the store.

They are two verbs and two capabilities rather than one verb with an operand or
a `--stdin` flag. Every capability string except `profile` names the verb of the
same name, and the two acts have genuinely different prerequisites: a backend
may be able to snapshot its own sessions while being unable to accept a foreign
blob, and there is no way to say that with one capability. Separately, stdin is a
property of a verb throughout this contract — `create`, `send`, and `set-profile`
read it unconditionally and nothing else reads it at all — so a flag that
switches it on would be the only one of its kind. Detecting a tty instead would
be worse: TBD always invokes providers without one, so the heuristic would be
constant-true in the only caller that matters.

- **`bytes` is required** and is the count of transcript bytes stored. It is how
  a caller detects a truncated `recall`.
- **`expires_at` is optional, and absent means the provider makes no claim** —
  never "this is kept forever". A caller MUST NOT render an absent value as a
  guarantee of permanence.
- Malformed JSONL on `import` is `invalid_params`.
- Providers SHOULD expire retained transcripts nobody recalls. Retention is
  storage the caller asked for, and a store with no expiry policy grows without
  bound.

### `recall <key>`

Writes the retained transcript to stdout as JSONL, in `transcript`'s format,
for any key — whether or not the session that produced it still exists.

- **`recall` writes nothing to stderr.** It does not inherit `transcript`'s
  cursor envelope: a cursor exists because a live transcript grows and is fetched
  incrementally, and a retained transcript is immutable. `--since` would be
  meaningless. Truncation, the cursor's other job, is detected against the
  `bytes` in the receipt. The contract keeps exactly one stderr exception.
- It is a separate verb rather than `transcript --key`, because the operand is a
  different identifier namespace and because the `transcript` capability must
  keep meaning "live transcripts work" rather than becoming ambiguous about
  which of two paths a provider implements.
- Unknown key: exit 1, `code: "not_found"`. A key the provider recognizes but has
  aged out: exit 1, `code: "expired"` — a new well-known code, added so a caller
  can say when a record lapsed instead of claiming it never existed. Both are
  permanent errors. Callers treat unrecognized codes as opaque strings already,
  so no caller breaks on it.

### Keys

A key is an opaque provider-issued string. Callers MUST NOT parse, construct, or
pattern-match one, exactly as with a `transcript` cursor or a `credential_ref`.

- **Keys are provider-scoped.** A key is meaningful only to the provider that
  issued it. TBD stores every key against `(provider name, key)` and MUST NOT
  present a key to a different provider.
- **A key is an identifier, not an authorization.** `recall` authenticates the
  way every other verb does; holding a key grants nothing on its own. This is
  stated so that neither side treats keys as bearer secrets, which would make
  them unloggable and unprintable and would put a credential in TBD's database.

### `seed` on `create`

`create`'s stdin gains an optional top-level field, a sibling of `profile` and
`idempotency_key` rather than a member of the provider-defined `params`:

```json
{"params": {...}, "profile": {...}, "seed": {"retained_key": "..."}, "idempotency_key": "tbd-9a1c..."}
```

The new session begins with that retained conversation as its history. It is
gated by a capability named `seed`, matching the field it gates — the same shape
`profile` already has, and the only precedent for a capability that gates a
field rather than a verb.

The gate is not optional politeness. The contract requires providers to ignore
stdin fields they do not recognize, so an ungated `seed` would be silently
dropped by a provider that does not implement it, producing an empty session the
caller believed was seeded. A caller MUST NOT send `seed` to a provider that has
not declared it. `create`'s idempotency dedupe covers seeded creates unchanged.

`seed` is an object rather than a bare key string so that a future inline source
— `{"transcript": [...]}` — needs no new field and no new capability.

### Format scope

`import`, `recall`, and `seed` all fix the payload as Claude Code transcript
JSONL, matching `transcript`. The contract otherwise assumes no particular
agent, so this is a real narrowing: a provider whose sessions are not Claude
Code sessions simply does not declare these capabilities. Other agents' formats
are out of scope here.

## Daemon

**RPC.** `remote.delete`, `remote.retain`, `remote.import`, `remote.recall`,
following the existing shape in `RPCRouter+RemoteHandlers`. `remote.create`
gains an optional seed key.

**A caller that issued the delete drops its row immediately.** The drift rule
needs two consecutive complete absences before a session is `gone`, which is
right for an observed disappearance and wrong for a requested one. On a
successful `delete` the daemon removes the `remote_session` row at once. Without
this the UI shows a session the user just deleted as live, then stale, then
gone, over two poll intervals.

**A new table, `retained_transcript`**: provider, key, `expiresAt`, `bytes`,
source session id, source title, resolved repo, originating worktree, local
path, `createdAt`. Rows are written by every path that obtains a key —
`retain`, `import`, and `delete --retain`. Without it a key printed once is
unrecoverable. Migration plus GRDB record plus the `TBDShared` Codable model
land in one commit, with every new model field optional or defaulted.

**Flag.** `remote_delete_enabled`, added by migration with no SQL `DEFAULT` so
NULL remains a third state, shipped default-off, graduating by a one-line change
to `Config.remoteDeleteDefault`. It gates the destructive verb only; `retain`,
`import`, and `recall` are non-destructive and are gated by their capabilities
alone.

**Expiry uses the date seam, not the clock seam.** `expires_at` is a persisted
timestamp compared against now, so the types that read it take
`now: @Sendable () -> Date`. `Duration` is behavior; `Date` is data.

## App

**Delete is offered on both surfaces a remote session can wear.**
`RemoteSessionActionMenu` gains a destructive `delete` after `stop`, and
`RowActionMenu` gains the same for a remote-location lane, beside Archive. Where
the provider has not declared `delete`, the item is present but disabled and
reads `Delete (provider can't delete)` with help text naming the missing
capability — the treatment `RowActionMenu` already gives an unarchivable lane,
and the hook a later design will use to offer implementing the capability.

**Confirmation fires unless nothing is at stake.** It is skipped only when the
session is `exited`, does not claim `meta.workspace_dirty`, and a receipt is
coming. Anything running, anything claiming uncommitted work, and any delete
that will keep no record is confirmed, and the dialog states what is destroyed
and whether a transcript is kept and until when.

**A deleted lane keeps its place.** Deleting an adopted lane archives its
worktree row and points the receipt at it, so the row stays in the repo's
Archived tab with its branch and PR context. Revive on such a row means
`create` with `seed` — the gesture, the place, and the word already mean this.
Past `expires_at`, Revive is disabled and names the date; the row remains as
history. A never-adopted session's receipt surfaces in the Provider Desk's
session ledger, marked deleted.

**Recalled transcripts land at `~/tbd/transcripts/<provider>/<key>.jsonl`**,
derived from `TBDConstants` so the test fence covers it, and render read-only in
the existing transcript pane.

**The display fix.** Both sidebar filters drop sessions whose payload reports
`archived`, which is the display policy the contract assigns the caller. Dismiss
becomes available when a session is `gone` **or** `exited`, so a session the
provider keeps enumerating after death is removable even from a provider that
never implements `delete`.

## CLI

A `tbd remote` group, whose abstract opens by naming provider-hosted agent
sessions — in a worktree manager "remote" reads as git remote first.

```
tbd remote list [--provider <name>] [--archived] [--json]
tbd remote create --provider <name> [--param key=value]...
                  [--continue <terminal-id> | --from-key <key> | --from-file <path|->] [--json]
tbd remote stop <session> [--json]
tbd remote archive <session> [--json]
tbd remote unarchive <session> [--json]
tbd remote delete <session> [--retain] [--force] [--json]
tbd remote transcript <session> [-o <path>]
tbd remote retain <session> [--json]
tbd remote import --provider <name> [<path>|-] [--json]
tbd remote recall --provider <name> <key> [-o <path>]
tbd remote retained list [--provider <name>] [--json]
tbd remote dismiss <session>
```

- **`<session>` accepts a worktree name, a TBD UUID, or `<provider>/<id>`** —
  the compound a human reads off `tbd remote list`. Key-addressed commands take
  `--provider` explicitly, because keys are provider-scoped and may contain any
  character.
- **`create` names no identity.** TBD's `remote.create` composes the provider's
  stdin as `{params, [seed], idempotency_key}` and never sends the contract's
  optional `profile` object, so both an ordinary and a seeded create run under
  the provider's default identity — which is exactly what an absent `profile`
  means to a provider. Nothing on this path carries an identity to expose, so
  there is no flag for one: sending `profile` is separate work, taking a profile
  projection all the way from the app and the CLI through the RPC to the
  composed body, and it belongs with `set-profile` rather than here.
- **`create --continue <terminal-id>` is the teleport.** TBD reads that
  terminal's local Claude transcript, `import`s it on the chosen provider, then
  `create`s seeded from the returned key. `--from-key` and `--from-file` are the
  other two seed sources; the three are mutually exclusive. It is not named
  `teleport`, because `claude --teleport` means cloud-to-local — the opposite
  direction — and TBD already says `tbd terminal continue-in-codex` for "carry
  this conversation elsewhere".
- **Teleport moves a branch, never files.** TBD refuses when the worktree has
  uncommitted changes or unpushed commits, naming what would be left behind, and
  each refusal is overridable with `--force`; for unpushed commits it offers to
  push. Carrying files would mean shipping the untracked and ignored ones that
  make a checkout work — `.env`, local databases, credentials — which is a
  per-repo policy question, not a transport question, and is out of scope.
  `meta.workspace_dirty` is the same fact in the other direction.
- **`delete` refuses without `--force`** when the session is running or claims
  `workspace_dirty`. `--retain` prints the key.
- **A missing capability is a one-line refusal naming it, exit 1**, decided
  before any provider call — never a provider error surfaced raw.
- **Key-returning commands print the bare key on stdout** and everything else on
  stderr, so `KEY=$(tbd remote retain my-lane)` composes. `--json` returns
  `{"provider", "key", "expires_at", "bytes"}`.
- **`transcript` and `recall` write JSONL to stdout** with no `--json` flag —
  the output is already machine format — and `-o` writes to a file. `import`
  takes a path operand or `-` for stdin.
- **`dismiss`'s help must contrast with `delete`**: dismiss changes nothing on
  the provider. Without the contrast users reach for whichever they find first.
- No interactive prompts anywhere: agents drive this CLI and cannot answer them.

## Reclamation

Retained transcripts are a new kind of durable resource on both sides.

On the provider side, `expires_at` plus the SHOULD that providers expire what
nobody recalls is the whole mechanism; TBD cannot reclaim another machine's
storage.

On TBD's side there are two: `retained_transcript` rows, and the JSONL files
under `~/tbd/transcripts/`. **`OrphanGC` gains a leg** that deletes files no row
references and rows whose `expiresAt` has passed, gated by
`gcRetainedTranscriptsEnabled`, default-off during soak, following the
profile-dir and holder-rendezvous legs. The teleport flow is what makes this
load-bearing rather than tidy: `import` succeeding and `create` then failing
leaves a retained blob and a row nobody will ever use.

## Testing

- Both branches of `remote_delete_enabled`, and the three-state config check: a
  pre-migration row reads NULL, an explicit `false` survives a change to the
  default constant, NULL follows it.
- Both branches of `gcRetainedTranscriptsEnabled`.
- Pure menu composition: `delete` present, disabled-with-reason, and omitted;
  Dismiss offered for `gone`, for `exited`, and for neither.
- Sidebar filters: an archived session renders in neither section, and an
  unarchived one still does.
- Decode: `delete`'s response with and without `retained`; a receipt with and
  without `expires_at`; an `expired` error code round-tripping as a known code.
- CLI: `<session>` resolution by all three forms; mutually exclusive seed
  sources; the refusal path for a missing capability, asserted on composed
  output rather than on absence.
- A mock provider declaring each subset of the four capabilities. The built-in
  claude-cloud provider declares none of them, so nothing here is end-to-end
  testable against a real backend inside this repo; agentbox is the first
  implementation.

## Build order

1. Contract document, and rewriting the archive spec's "Deliberate cuts"
   paragraph to state the current design.
2. Sidebar display fix and the Dismiss gate — independent of everything else,
   and it clears the accumulated rows on its own.
3. `retain`, `import`, `recall` end to end: RPC, table, migration, CLI.
4. `delete`: RPC, flag, both menus, confirmation, immediate row drop.
5. `seed` on create, Revive-as-reseed, and `create --continue`.
6. The `OrphanGC` leg.

## Rejected alternatives

**One `retain` verb with `<id>` XOR `--stdin`.** Rejected on capability
granularity: a provider able to snapshot its own sessions but not accept foreign
blobs cannot be described. Also the only flag-switched stdin in the contract, and
it needs error paths for neither-operand-nor-flag and for both that two verbs
make unreachable.

**Retention implied by capability rather than by `--retain`.** Rejected because
it makes a response shape depend on capabilities rather than on the request, and
allocates storage the caller never asked for.

**The session id as the retrieval key.** Smallest possible addition — `transcript
<id>` keeps answering after deletion — but it forbids id reuse forever and
conflates "this session exists" with "this session's record exists".

**A general `retain`-then-`delete` sequence with no atomic flag.** Kept as the
composable form; `--retain` exists as well because a caller that means "destroy
this but keep the record" should not have a state where the first call succeeded
and the second did not.

**`reseed` as the capability name.** It describes nothing — the session was
never seeded before — and it breaks the one precedent for a field-gating
capability, which names the field.

**Naming the local-to-remote path `teleport`.** Collides head-on with
`claude --teleport`, which moves a conversation cloud-to-local.

**Capturing scrollback instead of transcripts.** `log` bytes are a terminal
recording; poured into a transcript view they lose every tool card. The contract
is explicit that `log` and `transcript` are different data, not two encodings of
one.

**Teleporting files.** See the CLI section: the files that make a checkout work
are the ones git does not track, and shipping them by default exfiltrates
secrets.

**Hiding archived sessions behind a per-provider toggle.** More surface and a
persisted preference for a state that already has two homes — the repo's
Archived tab and the Provider Desk ledger.

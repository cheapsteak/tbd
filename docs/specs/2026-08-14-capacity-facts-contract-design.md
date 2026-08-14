# Capacity facts as a stated contract — design

Status: **implemented**. The resulting reference document is
[`../capacity-facts.md`](../capacity-facts.md); this spec records why that
document says what it says.

## Problem

Story P1-1 of
[`2026-07-26-fleet-supervision-requirements.md`](2026-07-26-fleet-supervision-requirements.md)
asks for a capacity-aware supervisor: one that holds interventions when several
agents are rate-capped at once, and never nudges an individually rate-limited
agent. The story splits along the Built/Enabled line. Holding is **Built** for
the desks TBD runs. For a wake program — a script TBD does not run, does not
schedule, and cannot repair — it is **Enabled**: TBD's obligation is that the
facts a program needs to hold on its own are public, documented, and stable.

[`2026-07-26-fleet-supervision-wake-program.md`](2026-07-26-fleet-supervision-wake-program.md)
states the same obligation from the consumer's side, and states its limit: TBD
guards nothing at actuation. There is no compiled capacity choke point every
wake must pass through, because such a point would make TBD the guarantor of a
program it does not own. What TBD owes instead is sufficiency.

The daemon already holds every fact required. It polls per-profile usage, keeps
buckets with provenance, and stamps each session with the profile it was spawned
under. `tbd profile list --json` already printed most of it. What did not exist
was the *promise*: nothing said the shape would hold, nothing defined what a
missing field meant, and one join a holding program cannot avoid — from a
session to the account whose quota governs it — was undocumented at exactly the
point where it is easiest to get wrong.

The gap was therefore never collection. It was that incidental output is not an
interface. This design closes it with two decisions.

## Decision 1 — the version lives on the envelope

`tbd profile list --json` prints a JSON object carrying a top-level
`schemaVersion`, stamped by the CLI at print time. Its value is `1`.

Three properties of the surface force that placement:

- **One binary emits one shape.** The CLI that prints a listing prints every
  entry in it. A version attached to each profile could never legitimately
  differ between entries, so per-entry versions would be a field that is either
  always redundant or always a bug.
- **The contract's join spans the envelope.** Reading capacity for a session
  needs `profiles[]` and `defaultID` together, and the rule about what a
  consumer may *not* do with `defaultID` (Decision 2) is a statement about the
  pair. A version scoped to a snapshot, or to a profile, cannot cover a rule
  whose subject is the object containing both.
- **The printed output is the contract surface.** The daemon's RPC result is an
  internal seam between two binaries shipped together; it carries no promise to
  anyone outside the process pair, and versioning it would state a commitment at
  a boundary no external program observes. The CLI stamps the version because
  the CLI's stdout is what a program reads.

This also matches the convention
[`../cli-supervise.md`](../cli-supervise.md) states for the planned supervision
surfaces — JSON output carries a top-level `schemaVersion`, and changes within a
version are additive only. This command is that convention's first shipped
instance rather than a second convention.

### What the version promises

- **Additive within a version.** Fields may be added at any level — top level,
  per profile, per snapshot, and new bucket kinds. A consumer must tolerate keys
  it does not recognize. Unknown bucket kinds flow through from the usage API by
  design, so a new rate-limit window appears without a TBD release.
- **Meanings are fixed within a version.** A field TBD computes keeps computing
  the same thing; timestamps stay ISO 8601; an enum value already emitted keeps
  its sense.
- **Removal or a meaning change requires a bump.** A consumer that branches on
  `schemaVersion == 1` is never silently surprised.
- **Provider-originated values are pass-through data.** `percent`, `severity`,
  and bucket `kind` come from the usage API and are emitted verbatim. TBD
  promises only not to reinterpret or rescale them. The observed scale for
  `percent` is 0–100 utilization; an upstream scale change would surface as-is
  rather than be silently converted, which is why the reference document steers
  consumers toward relative judgments over hard-coded absolute thresholds.

The envelope is built by encoding the payload into the same keyed container the
version is then written to, so any field the underlying result gains flows
through with no envelope-side mirror to maintain. The version is written last
and therefore wins over a payload key of the same name — deliberate, since the
printed contract version is the CLI's to state.

### Rejected alternatives

- **A version on each profile entry.** Rejected because entries in one listing
  cannot legitimately carry different versions, and because the rules being
  versioned are not per-entry rules.
- **A version on each usage snapshot.** Rejected for the same reason, plus a
  sharper one: the absence of a snapshot is itself contractual information
  (below), and a version living inside the snapshot says nothing in exactly the
  case that most needs saying.
- **A version stamped by the daemon into the RPC result.** Rejected because it
  versions the wrong boundary. It would also make the promise the daemon's to
  keep while the CLI is what composes and prints the bytes a consumer parses.
- **Versioning `tbd terminal list --json` too.** Rejected because that command
  prints a bare JSON array at top level. There is nowhere additive to put a key,
  and wrapping the array in an object to make room would break every existing
  consumer — the precise harm versioning exists to prevent. It stays
  unversioned and documented as-is; only its `profileID` field participates in
  this contract. To keep that reasoning enforceable rather than advisory, the
  envelope type accepts only payloads marked as encoding to a JSON object, so
  wrapping an array is a compile error instead of an encoder crash.

## Decision 2 — a session's profile is documented, never synthesized

`Terminal.profileID` is documented as it is. TBD does not add a computed
"effective profile" field that fills in a missing value from the global default.

The argument is entirely about what the stored value already means. The daemon
runs the full precedence chain at spawn time — explicit per-spawn override, then
the repo's override, then the scratch override for repo-less spawns, then the
global default — and stamps the result on the terminal row. Waking a hibernated
session pins to that stamp, and ordinarily refuses to wake at all when the
pinned profile no longer resolves rather than quietly resuming on some other
account. Reviving a *closed* terminal re-runs the chain, so it may come back
stamped differently, which is honest: it is a different spawn.

So a present `profileID` is **already the effective answer**. There is no
resolution left to perform, and nothing for a synthesized field to add.

Which means an absent one is not an unfinished computation either. It says
resolution produced nothing — no override and no global default configured — or
that the session is not a Claude session at all. In the first case the session
runs on the machine's ambient credentials: a real account, doing real work,
whose quota TBD's poller does not track and has no way to track.

### Why an effective profileID would be wrong

Synthesizing `defaultID` into the empty slot would produce a number that looks
like an answer and is not one. `defaultID` is what the *next* session would be
spawned under. A session started before a default was configured, or under
ambient credentials TBD never sees, would be reported as running on an account
whose usage numbers describe a different quota entirely — and a holding program
would then hold, or decline to hold, on the wrong account's remaining capacity.
That is the exact mistake P1-1 exists to prevent, dressed as a convenience.

It would also erase a distinction the daemon depends on. Ambient-versus-profile
is what the wake-refusal path tests: a parked session pinned to a profile that
no longer resolves is refused precisely because resuming it on ambient
credentials would be resuming it on the wrong account. A surface that reports
every session as having a profile makes that distinction unobservable from
outside.

### The resulting contract reading

`profileID` has three states, and only one of them yields capacity facts:

- **Present and it joins** to an entry in `profiles[]` — that entry's snapshot
  governs the session.
- **Present but it joins to nothing.** Deleting a profile dangles the stamp
  immediately on every terminal row referencing it, awake or parked or closed.
  Nothing rewrites those stamps, deliberately: the stamp records which account a
  session was started under, and an already-running process keeps using the
  credentials it was handed, so overwriting the record would misreport what that
  process is doing.
- **Absent** — not a Claude session, or spawned with nothing to resolve.

Both non-joining states mean the same thing to a consumer: **no capacity facts
exist for this terminal.** Neither is an error or a corrupt payload; both are
normal states with normal causes. A holding program treats them as *unknown* —
which is neither "exhausted" nor "free" — and decides which way to fail from its
own conduct, not from a guess TBD made on its behalf.

## Consequences for the rest of the surface

Three smaller rulings follow from the same principle — say what is true,
including about what is missing — and are stated in the reference document.

- **Absence is not failure, and it is not one state.** A missing `usageSnapshot`
  can mean the profile is durably untracked (`kind` is not `oauth`, or
  `loginIdentity` is absent — nothing to poll), or tracked but not yet fetched
  (an OAuth profile with a login identity whose first poll has not landed —
  transient, self-resolving, retry later). A *present* snapshot whose last fetch
  failed is a third state, carrying possibly-stale buckets from an earlier
  success. All three are discriminable from fields already in the payload, so
  the surface owes no new field — only the documentation that makes the
  discrimination visible. A consumer that collapses them treats an untracked
  Bedrock lane, a daemon that has been up ten seconds, and an expired token
  identically, though only the last warrants telling an operator anything.
- **Refresh tolerance ends where the daemon's answer does.** `--refresh` is an
  optimization, not a precondition: when the daemon answered and refused, or
  answered unreadably, the cause goes to stderr, the listing still prints, and
  the exit code stays 0. An unreachable daemon fails the command like any other
  invocation, because promising a listing on stderr and then exiting nonzero
  with empty stdout is worse than failing plainly. The note itself must not
  overpromise: the refusal a daemon sends is that it has no usage poller, and
  the listing draws snapshots from that same poller, so in exactly that case the
  listing carries no snapshots at all — the not-yet-fetched state, not stale
  numbers.
- **Secret-bearing fields stay, with a warning.** The envelope's env-override
  fields are the values the daemon routes through tmux's sensitive environment
  channel specifically to keep them out of `ps`, and they routinely carry auth
  tokens and proxy keys. Removing them would break the additive promise, so they
  remain — but a capacity consumer needs none of them, and the reference
  document tells programs to drop or redact them before logging or persisting
  the envelope. A contract that documents a field's presence should also
  document when holding onto it is a hazard.

## Scope

This design adds no collectors and changes no daemon behavior, no persisted
state, and no defaults. Everything it promises was already computed; the work is
stating it, versioning the statement, and making the two rules above impossible
to misread. Compiled behavior stays where it was — consistent with placing
capability outside the daemon until field evidence argues it inward.

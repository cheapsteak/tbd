# Holder legs ride their subsystem's switch

## Summary

Holder-ness is a transport property, not a separate opt-in. A session row
records which transport it runs on, `tmux` or `holder`, and every subsystem
that acts on sessions has a leg for each transport. This design states the
rule those legs follow: **if a subsystem is on and the session is
holder-backed, the holder leg runs.** No holder leg carries a switch of its
own.

Concretely, five `config` switches are removed and their legs derive their
gate from the subsystem they belong to:

- **Hibernation** – the idle sweep arms a holder row on `auto_hibernate_enabled`,
  exactly as it arms a tmux row. Manual "Hibernate now" is unflagged on every
  transport. The merge-triggered park rides the same per-worktree setting as
  tmux. The limit-resume rail is served on a holder row and gates on what
  gates it on tmux. Formerly `holder_hibernation_enabled`.
- **Rendezvous file reclamation** in `OrphanGC` – runs under `gc_enabled`, the
  same outer guard as the agent-worktree loop. Formerly
  `gc_holder_rendezvous_enabled`.
- **Row-less holder reclamation** in `OrphanGC` – runs under `gc_enabled`.
  Formerly `gc_rowless_holders_enabled`.
- **The reaper's holder leg** – runs on every pass, like the reaper's tmux leg,
  which has never had a switch. Formerly `reap_holder_children_enabled`.
- **The reconcile holder arm** – judges on every pass, like the reconcile tmux
  arm. A finished, resumable holder row is parked, preserving its session id,
  exactly as a finished tmux row is. Formerly `holder_row_reconcile_enabled`.

The transport itself stays behind `pty_holder_enabled`, default off. That flag
gates spawning, not servicing: it decides which transport a new session gets,
and every leg above runs whenever a row of its transport exists.

## The decision, and who made it

The human ruling this design transcribes:

> `holder_hibernation_enabled` shouldn't be a separate flag — should be the
> same flag as holder. Everything gets auto hibernate if auto hibernate is on.
> If holder is active, and if auto hibernate is active, then holder should auto
> hibernate. Are there other duplicate state flags that should instead be
> derived for holder? Let's fix all of them.

The survey that answered the second question found the four reclaimer
switches, and the ruling covers them: each was a holder-specific twin of a
gate the subsystem already had, or of no gate at all.

## Why a per-leg switch is duplicate state

Each holder leg is the holder-transport half of a behavior the user already
controls through one switch. A second switch for the holder half creates a
state the user cannot see from the switch they are looking at: auto-hibernate
on, holder sessions in the fleet, and those sessions never parking; GC on, dead
holders' sockets never unlinked. The two switches can only agree or disagree,
and the disagreeing state is the defect, not a feature.

The per-leg switches were the right shape for one purpose: introducing
destructive reclaimers one at a time while the transport was new. That is a
rollout argument, not an architectural one, and it ends when the last leg has
landed and been exercised. Two facts make the collapse safe:

- `Config.ptyHolderDefault` is `false`. Nobody who has not deliberately opted
  into holder sessions has a holder row for any of these legs to act on.
- Every leg has been exercised on a live fleet, and the transport's own soak,
  described in the transport spec's Rollout section, is the gate that remains.

## Consequences the design accepts

- **Explicit opt-outs are discarded.** An install that had written `0` or `1`
  to one of the five columns loses that as a distinct setting. Nothing reads
  the column. An opt-out from a holder leg while its subsystem stays on is
  exactly the disagreement this design removes, so preserving it would preserve
  the defect.
- **Two legs answer to no switch at all.** The reaper's holder leg and the
  reconcile holder arm run unconditionally, matching their tmux counterparts.
  Setting `gc_enabled = 0` stops the two `OrphanGC` holder arms and nothing
  else, exactly as it stops nothing in the reaper or the reconcile pass today.
  Both legs keep whenever process identity is uncertain.
- **An unparked holder row asked to wake is classified**, against the process
  table rather than a tmux pane, and never refused for its transport.
- **A finished holder row is parked even when the daemon cannot currently
  start a holder** because the `TBDHolder` helper is missing. The wake path
  names that state and keeps the row parked, so the session id survives until
  the helper is back. Deleting the row would destroy a resumable session over a
  transient helper absence.
- **An older app talking to a newer daemon** still renders the removed
  hibernation toggle and, if flipped, gets an unknown-method error. The
  capabilities payload decodes leniently, so nothing else in that skew breaks.

## Database columns

The five columns stay in the schema, unread. No migration is added or changed:
`DROP COLUMN` support is version-dependent, and an unread column is harmless.
`ConfigRecord` carries a one-sentence note naming them as vestigial, which is
where a reader wondering about them will look.

## Testing

The repo rule that each branch of a gating conditional has a test applies to
the derived conditions:

- a holder row with `auto_hibernate_enabled` on is auto-hibernation eligible,
  and with it off is refused for the same reason a tmux row is;
- manual "Hibernate now" is permitted on a holder row with auto-hibernate
  explicitly off, exactly as on tmux;
- the two `OrphanGC` holder arms run under `gc_enabled`, touch nothing with it
  off, and still plan under dry-run;
- the reaper's holder leg and the reconcile holder arm act with no config
  gesture at all.

Each test was verified to fail with its piece of the change reverted. The
tests that pinned the five switches' tri-state resolution have no subject left
and are removed.

## Rejected alternatives

- **Flip each switch's default to on, delete later.** The two-step protects
  explicit opt-outs, which is the wrong thing to protect here: the opt-out is
  the disagreeing state. It would also leave five switches in the schema and
  the CLI for one more release, advertising a choice that no longer means
  anything.
- **Fold the five into `pty_holder_enabled`.** That flag gates spawning. Tying
  servicing to it would strand every existing holder row the moment the flag
  was turned off: no park, no reclamation, no reconcile, for rows that still
  exist. Servicing has to follow the row's transport, not the spawn policy.
- **One holder-wide servicing switch.** A single "service holder rows" flag is
  the same duplicate state with one name instead of five. The user's switch
  for hibernation is the hibernation switch; a second one for the holder half
  recreates the disagreeing state.

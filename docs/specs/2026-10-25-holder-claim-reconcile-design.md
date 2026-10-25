# Holder viewer-claim reconcile

## Problem

Under the pty-holder transport, a panel that shows a session gets the session's pty descriptor from the daemon, and the daemon records a **viewer claim**. While the claim stands, the daemon does not read the pty, and it refuses every other attach for that session with "a viewer owns the pty". That refusal is deliberate: a descriptor in another process cannot be taken back, so while one may be outstanding, the only safe answer to a second attach is no (see `beginAttach` in `HolderRegistry`).

Three events clear a claim: the app's handback (`pane.detach`), a confirmed death of the app that owns it (the sidecar arbiter), and a daemon restart. Two lost messages leave a claim standing while its app lives:

- **A lost handback.** `pane.detach` travels on a one-shot RPC connection, and a transport error loses it, for example an instant `ECONNREFUSED` from a full accept queue while the daemon stalls.
- **A lost attach reply.** The daemon mints the attach and sends the descriptor, but the `attach.request` reply never reaches the app. The app never learns the generation, so it cannot hand the attach back, and the daemon's ready timeout turns the pending attach into an unacknowledged claim.

Either way, nothing reads the pty until the app quits. A job stops once the kernel's pty buffer fills, a job that is exiting cannot finish, and every attach to the session is refused.

The app's handback resend retries a failed `pane.detach` in the background for a bounded schedule, and only for generations at or above `AttachRequestResult.uniqueGenerationFloor`. It covers the first case until its schedule runs out. It cannot cover the second case at all.

The claim is a durable resource, a descriptor held in another process, and only event messages clear it. CLAUDE.md's reconciler doctrine names the gap: creation cannot be transactional, so the standing guarantee is a sweep that compares ground truth against intent. Here only the app knows the ground truth.

## Decision

The app tells the daemon, every poll tick, which sessions it holds. The daemon takes back the claims that app owns on every other session. The sweep is the named reconciler for viewer claims; the sidecar arbiter keeps covering an app that exits.

- The orderly handback stays the fast path, because it carries the app's screen back to the daemon.
- The sweep ships behind `holder_claim_reconcile_enabled`, default off, because it is a background timer that takes ptys back.
- When the flag graduates, the app's handback resend is deleted.

The sweep is compiled, not user-land: it decides who reads a pty, which is the integrity of the single-reader record, and no user-land surface can arbitrate that (see [`docs/theory-placement.md`](../theory-placement.md)).

## Protocol

- **`attachSeq`.** `AttachRequestParams` gains `attachSeq: UInt64?`. The app numbers every `attach.request` it sends, starting at 1 and counting up by one, per app process. The daemon records the value on the pending attach and keeps it on the claim the attach becomes. It is optional for wire compatibility; a claim without one is never swept, so an older app's claims behave as before.
- **`holder.reconcileClaims`.** A new RPC.
  - Params `HolderReconcileClaimsParams`:
    - `appPID: Int32` – the app's process;
    - `held: [UUID]` – the terminals the app holds a descriptor for, or has an attach in flight for;
    - `throughSeq: UInt64` – the highest `attachSeq` the app had sent when it built `held`.
  - Result `HolderReconcileClaimsResult`:
    - `takenBack: [UUID]` – the sessions the daemon took back;
    - `wouldTakeBack: [UUID]` – the sessions it would have taken back while the flag is off.
- **App identity.** Before it takes anything back, the daemon resolves `appPID` to a `ProcessIdentity` with the check it already applies to sidecar peers: pid, start time and executable. A pid it cannot resolve sweeps nothing, and a reused pid matches no claim owner. Resolving spawns `ps` twice and blocks, so the daemon first asks the registry whether any claim matched by pid alone meets the other conditions, and resolves only when one does and the flag is on. In the steady state every live panel's session is in `held`, and a sweep costs no database read and no `ps`.

### Why `throughSeq`

`attach.request` and `holder.reconcileClaims` travel on separate one-shot connections, so the daemon can receive them in either order. The app builds `held` and reads the highest `attachSeq` in one main-actor step.
- An attach numbered after that step has a higher `attachSeq` than `throughSeq`, so this sweep cannot touch its claim, whatever order the two arrive in.
- An attach numbered before that step is in `held` until its attempt ends.

## Daemon

- `PendingAttach` and `ViewerClaim` gain `attachSeq: UInt64?`.
- A sweep takes back a claim only when all four hold:
  1. its owner is the identity `appPID` resolved to. A pending attach whose owner is not recorded yet, because its descriptor has not been sent, is skipped;
  2. it has an `attachSeq`, at or below `throughSeq`;
  3. its terminal is not in `held`;
  4. no take-back of that attach is already in flight, the existing one-take-back-per-attach guard.
- The sweep covers acknowledged claims and sent-but-unacknowledged pending attaches alike. Its authority is the one a handback carries: the app's own statement that it holds no descriptor for the session, made only after it closed any it received.
- A take-back goes through `takeBackFromViewer` with no preamble, the path the dead-app seizure uses. The reader resumes, and the job is jiggled so a program that repaints on SIGWINCH redraws.
- Each take-back logs at `.notice` in category `holder`, naming the session, the attach generation and the app.
- **Flag off:** the daemon does not resolve the app's identity. A candidate is never taken back while the flag is off, so it stays one on every tick until the app quits, and resolving the pid on each tick would spawn `ps` twice every 2 s. The daemon selects by the same four conditions, the first matching the owner by pid alone. It returns the set in `wouldTakeBack` and changes nothing.
  - Each attach is logged once per daemon life, at `.notice` in category `holder`, as "would take back". Every sweep's result still lists it in `wouldTakeBack`.
  - Matching by pid can also list a claim whose owner is an earlier process that held the same pid. It is only listed: with the flag on, the resolved identity's start time tells the two apart, and that claim is left alone.

## App

- **The held set.** The handback ledger (`HolderHandbackLedger`) owns it, because the ledger already orders a closing panel against its successor, and one structure should decide both.
  - A terminal enters the set before its `attach.request` is sent, in the same main-actor step that mints its `attachSeq`.
  - It leaves only after both: its descriptor is closed (or never arrived), and its handback or release attempt has ended, answered or given up.
  - Keeping a terminal in the set until its handback attempt ends means a sweep acts only on a handback that was truly lost, so the orderly path keeps its screen snapshot.
- **Sending.** On every tick of `AppState`'s 2 s poll, and right after the app connects, while it is connected.
  - The app does not read the flag; the daemon decides whether to act.
  - A failed call is ignored; the next tick sends again.
  - An "unknown method" answer from an older daemon stops the sweeps until the next connect or the next start of the state subscription. RPCs ride one-shot connections, so a daemon replaced under a running app may never register as a disconnect; a restarted subscription is the visible sign of a new daemon.
  - Nothing is sent before the app numbers its first attach. A sweep through `throughSeq` 0 can cover no claim, since every `attachSeq` is 1 or more.
- **Settings.** A toggle beside the pty-holder toggle in `SettingsView` reads the flag from `daemon.capabilities` and writes it with `config.setHolderClaimReconcileEnabled`.

## Flag and graduation

- **Column.** A new migration, `20261025182152_config_holder_claim_reconcile.sql`, runs `ALTER TABLE config ADD COLUMN holder_claim_reconcile_enabled INTEGER;`, with no SQL default, so NULL means nobody chose. `ConfigRecord.toModel()` resolves it with `?? Config.holderClaimReconcileEnabledDefault` (false), and `Models.swift` gains the optional field, all in one commit.
- **Soak.** Turn the flag on for the developer's install. Watch the `.notice` take-back lines and the reader census (`holder-reader-census violations=0`).
- **Graduation.** Flip `holderClaimReconcileEnabledDefault` after a soak with at least one observed take-back and zero census violations. The same change deletes the app's handback resend:
  - the resend schedule;
  - the ledger's resend registry and `awaitResends`;
  - the generation-floor check in `HolderAttachClient`.
  
  The daemon's random generation base stays, because it still protects a detach that crosses a daemon restart.

## What this gives up

- **No screen snapshot on a sweep.** A plain shell's daemon-side screen stays as it was at the attach until new output arrives, as after an app death. Only a lost handback takes this path.
- **Recovery waits for a tick.** It takes up to one poll tick, 2 s, plus however long a stalled app takes to tick. A slow app delays recovery and never causes a second reader.
- **The held set must be right.** An app bug that leaves a terminal out of `held` while a panel still reads it would put the daemon on that pty too. So the set is built from the structure that owns the descriptors, never from view state.
- **Older apps get no sweep.** An app that sends no `attachSeq` gets no sweep, and its claims behave as before.

## Testing

- **Daemon (unit):**
  - each of the four conditions refuses a take-back on its own;
  - an owned, unheld, covered claim is taken back and its job jiggled;
  - a sent pending attach is covered;
  - flag off logs each attach once, changes nothing, and never resolves the app's pid;
  - flag on acts;
  - unset follows the default constant.
- **Migration:** a pre-migration row reads NULL, not 0, and an explicit false survives a change to the default.
- **App:**
  - a terminal is in `held` from before its request until its handback attempt ends;
  - `attachSeq` counts up;
  - a sweep goes out on each tick and after connect;
  - an older daemon's "unknown method" stops the sweeps until a connect or a restarted subscription;
  - no sweep goes out before the first attach is numbered;
  - an attach started after a sweep was built is never taken back by that sweep.

## Rejected alternatives

- **Leases** (a claim expires unless the app renews it). An app that is only slow would lose claims while it still reads, for example when App Nap coalesces its timers or its main thread stalls. That is two readers.
- **Resends plus replace-on-attach.** Event-driven patches need one fix per lost message. A lost handback leaves the session undrained until its tab is shown again. Replace-on-attach also relaxes the daemon's refusal, which is the safety net against an app mounting one session twice.
- **The daemon replacing a claim whenever the same app attaches again.** It has the same objection, with no opt-in at all.
- **Ordering sweeps by arrival instead of `attachSeq`.** The two RPCs use separate connections, so arrival order says nothing about send order.

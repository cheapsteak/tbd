# Provider Desk read-only overview

**Date:** 2026-08-01  
**Status:** Approved in issue #565; implementation scope is milestone 2 only.  
**Issue:** [#565 — Provider Desk](https://github.com/cheapsteak/tbd/issues/565)

## Summary

Selecting a remote provider header opens a read-only Provider Desk. The desk
answers three questions from data TBD already mirrors: Is this provider
reachable? How much work does it own? Which sessions need attention?

This slice adds no provider verbs, background work, database state, or remote
execution. It does not implement status telemetry or typed jobs. Those remain
separate milestones because their facts do not exist in the current provider
contract.

## Chosen approach

Issue #565 considered a provider-level detail surface, a provider status
capability, and a typed job capability. This slice chooses the smallest useful
boundary: a deterministic projection of `RemoteProviderStatus` and
`RemoteSessionInfo` into a selectable desk.

Two broader approaches are deferred:

- Extending the provider contract with `status` would provide capacity and
  resource telemetry, but requires daemon and provider changes plus freshness
  semantics. It belongs to milestone 3.
- Adding Local CI controls would require typed `job-*` verbs and provider-owned
  isolation, concurrency, logs, and cancellation. It belongs to milestone 4.
  Calling a shell command from this desk would violate the approved contract.

## Experience

The provider header becomes a normal selectable sidebar row. Selecting it
clears worktree, repository, scratch, and remote-session selections and opens
the Provider Desk without attaching to a session.

The desk uses a compact operational layout:

1. A provider masthead shows its display name, health, and a refresh action.
2. A two-axis status strip counts terminal states and agent states separately.
3. A session ledger lists title, repository, branch, terminal state, agent
   state or reason, age, and last mirror update.

The status strip is the design signature: two parallel rows make it impossible
to collapse process liveness and agent activity into one misleading status.
The surrounding interface stays quiet and uses TBD's native materials, system
type, spacing, and status colors.

On narrow windows, summary groups wrap vertically and session metadata flows
under the title. The row remains keyboard accessible, and every icon-only
control has an accessibility label and help text.

## Data and freshness

The desk filters `AppState.remoteSessions` by provider and excludes dismissed
rows. Counts are pure projections:

- terminal: starting, running, exited, gone, and unknown;
- agent: working, waiting for input, idle, exited, and unknown.

`gone` is a mirror condition and therefore takes precedence over the payload's
terminal state in the terminal totals. Provider health never rewrites a
session's state.

Freshness comes from `RemoteProviderStatus.lastSuccessfulSnapshotAt` — the
provider-wide timestamp of the last complete inventory the mirror accepted,
added by #571 — shown as **Inventory as of 2h ago**. This is the same fact the
sidebar caption and session detail pane quote, so no two surfaces can disagree
about how stale a provider is.

Per-session `lastSeen` is only a fallback for a daemon old enough not to send
that timestamp, and it is labelled **Latest mirror update** rather than being
called an inventory. It is deliberately not the primary source: it is a lower
bound over whichever rows happened to appear, so it cannot tell a successful
*empty* snapshot from no snapshot at all, and a provider whose rows all stopped
being reported would keep quoting an age that describes no inventory. When
neither exists the desk says “No successful inventory yet” rather than
inventing a timestamp.

Because #571 also gates session creation on `hasStaleSnapshot`, the empty state
stops pointing at the sidebar `+` while that gate is closed.

Provider health copy comes from `RemoteProviderStatus`:

- healthy: “Provider responding”;
- stale: “Provider unreachable; mirrored sessions may be stale”;
- needs authentication: the existing auth remediation component;
- error: the provider's reported message when available.

The refresh button calls the existing `refreshRemote()` RPC sequence. No new
poller or timer is introduced.

## Session navigation

Selecting a ledger row uses the existing `selectRemoteSession` path. Attach,
log, send, stop, rename, and pin remain in the existing session detail and
action menu; the desk does not create a second action vocabulary.

The provider selection is app-local view state. It participates in mutual
exclusion with existing top-level selections. Back/forward support is deferred
because adding a new persisted navigation entry expands the slice without
improving the desk's core read-only value.

## Error and empty states

An unreachable or unauthenticated provider remains selectable. Its mirrored
sessions stay visible and keep their last reported states. Authentication uses
the existing provider remediation UI; generic errors remain informational.

An empty provider shows its health and a directed empty state. It does not
offer session creation in the desk. The sidebar's existing `+` action remains
the creation path.

## Testing

Focused tests cover the pure projection:

- terminal and agent totals remain independent;
- `gone` overrides the payload's terminal state;
- dismissed rows are excluded;
- latest mirror update is derived only from visible rows;
- provider selection chooses the remote host without a session selection.

Build validation is `swift build`. The implementation adds no daemon or shared
model behavior, so the focused app tests are sufficient before the full build.

## Deferred decisions

- Provider capacity and resource cards require milestone 3's typed `status`
  contract.
- Local CI visibility, kickoff, logs, and cancellation require milestone 4's
  typed job contract.
- A local-provider aggregate that treats local worktrees as a provider needs a
  separate product decision; issue #565 describes registered remote providers.
- Back/forward history for provider-level selection may be added when the
  navigation model gains a provider entry.

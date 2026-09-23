# Nightwatch deprecation and the pty-holder gate

## Summary

Nightwatch and Daywatch (the Watch Desk, `Sources/TBDDaemon/Nightwatch/`) are
**deprecated**. The fleet-supervision redesign
([`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md))
replaces them, and the tmux removal
([issue #851](https://github.com/cheapsteak/tbd/issues/851), Phase 2 item 11)
does not port them to the pty-holder transport. A port is recorded, deferred,
in [issue #907](https://github.com/cheapsteak/tbd/issues/907).

Until the redesign cuts over, Nightwatch stays in the tree and keeps working on
the tmux transport. On the pty-holder transport it does not work, and this
document specifies how that is made loud rather than silent: **a watch mode and
the pty-holder transport are never both on.** The rule is enforced by refusals
at the two switches that could combine them, and by a one-time boot reconcile
for installs that already have.

Three human rulings shaped this design:

- **Deprecate, do not retire.** The Watch Desk stays compiled and usable on tmux
  until the redesign's path holds up.
- **Refuse at the switch, do not idle.** There is no "on but inactive" state: a
  watch mode that is persisted is a watch mode that runs.
- **Refuse in both directions.** Turning the holder on while a watch mode is
  active is refused the same way; no setting is rewritten by another setting's
  switch.

## Why a gate is needed at all

With `pty_holder_enabled` on and a watch mode active, the desk manager spawns
its desk terminal through the ordinary spawn gate, so the desk lands on the
holder. Its liveness check is `windowExists` on the row's tmux window id, which
is the empty string on a holder row, so the desk is skipped as stale
(`DeskSessionManager.liveDeskTerminals`). The pre-nudge recovery then spawns a
fresh desk terminal, which the next tick skips for the same reason. **Every
tick leaks one running Claude session.** The gate makes that state unreachable
by construction; nothing in `DeskSessionManager` changes.

## The rule

A watch mode (`nightwatchMode` other than `.off`) and the pty-holder transport
are never both on. "On" for the holder means the flag's **effective** value,
`config.ptyHolderEnabled` resolved through `Config.ptyHolderDefault`, so the
rule reaches installs that never touched the toggle when Phase 3 graduates the
default.

### The refusal text

One shared constant in `TBDShared` carries the sentence every surface uses, so
the app, the CLI, the RPC error, and the log say the same thing. It names the
holder flag, states that Nightwatch is deprecated and replaced by fleet
supervision, and says which switch to flip first. A second constant carries the
mirror sentence for the holder switch ("turn Nightwatch off first"). Both are
plain prose without org, host, or person names.

### Enforcement point 1: `nightwatch.setMode`

`RPCRouter.handleSetNightwatchMode` reads the config before writing. If the
requested mode is not `.off` and the effective holder flag is on, it returns an
RPC error carrying the refusal text and writes nothing. Requests for `.off` are
never refused.

### Enforcement point 2: `config.setPtyHolderEnabled`

`RPCRouter.handleConfigSetPtyHolderEnabled` reads the config before writing.
If `enabled` is true and the persisted `nightwatchMode` is not `.off`, it
returns an RPC error carrying the mirror text and writes nothing. Turning the
holder **off** is never refused.

### Enforcement point 3: boot reconcile

`Daemon.swift`'s boot step that re-applies the persisted watch mode to the
`DaywatchRunner` gains a check before `runner.apply`. If the effective holder
flag is on and the persisted mode is not `.off`, the daemon:

1. writes `nightwatchMode = .off` through the config store,
2. logs at notice level with the refusal text,
3. creates a daemon notification of type `attentionNeeded` carrying the
   refusal text, so the sidebar shows why the moon went dark,
4. broadcasts the config-change delta the app already reloads on, and
5. does not start the runner.

This state can only be reached by an install that combined the two on a daemon
older than this change; the two refusals mean it can never be entered again,
so the reconcile runs once per such install and is otherwise a no-op.

## App surfaces

All fed by the `Config` the app already reloads on the config-change delta.

- **Settings help copy.** The paragraph under the "Nightwatch / Daywatch"
  toggle gains the deprecation sentence: deprecated, replaced by fleet
  supervision, does not run with the pty-holder transport. Shown regardless of
  the holder flag.
- **Mode controls while the holder is on.** The daywatch and nightwatch
  segments of the sidebar toggle and the matching menu-bar items render
  disabled, with the refusal text as their tooltip. The `off` segment stays
  enabled. `NightwatchModePresentation` gains `isEnabled(_:holderOn:)` and
  `disabledHelp` so the rule is unit-testable without a view.
- **Holder switch while a watch mode is active.** The pty-holder Settings
  switch shows the mirror sentence as a footnote, and a refused flip surfaces
  the RPC error the way other refused settings do.
- **CLI.** `tbd nightwatch set` reaches the refusal through `nightwatch.setMode`
  and prints its text. `tbd nightwatch status` prints the deprecation line
  first.

## Documentation

- `docs/nightwatch.md` gets a dated banner at the top: deprecated as of this
  change, not available with the pty-holder transport, port deferred to #907,
  replacement in the fleet-supervision spec. Its as-built-audit status permits
  the dated banner.
- The root `CLAUDE.md` paragraph "Nightwatch is being replaced" gains one
  sentence stating the deprecation and the holder exclusion.
- Issue #851 item 11 is closed by the implementing PR.

## What stays as it is

- `DeskSessionManager`, `DaywatchRunner`, the tick script, and the skill
  content are untouched. Their tmux verbs remain, and are deleted with the tmux
  path in Phase 4 or ported under #907, whichever is chosen.
- No new feature flag: the change is a refusal that runs only on a user gesture
  or at boot, and the only state it writes is one mode column set to `off` in a
  state that cannot be re-entered.
- No migration: no column is added or changed.
- The `nightwatchExperimental` UserDefaults key that reveals the controls is
  unchanged.

## Testing

Both branches of every gate.

- **setMode.** Holder off: each of the three modes is accepted. Holder on:
  `.off` is accepted; `.daywatch` and `.nightwatch` are refused with the shared
  text and the persisted mode is unchanged.
- **Holder switch.** Mode `.off`: turning the holder on succeeds. Mode active:
  turning it on is refused with the mirror text and the flag is unchanged.
  Turning it off succeeds under every mode.
- **Boot reconcile.** Both on: mode written to `.off`, a notification of type
  `attentionNeeded` created, runner not started. Either off: mode unchanged and
  applied to the runner as today.
- **Effective value.** A NULL holder column with `Config.ptyHolderDefault`
  flipped to `true` trips the gate; an explicit `0` in the column does not.
- **Presentation.** `NightwatchModePresentation.isEnabled` is false for the two
  watch modes and true for `.off` when the holder is on, true for all three
  when it is off, and `disabledHelp` is the shared text.

## Rejected alternatives

- **Allow the mode and idle the runner.** The mode would persist while each
  tick checked the holder flag and skipped. Rejected: a mode that reads "on"
  and does nothing is the shape users cannot diagnose, and the daemon would be
  carrying a persisted intent it never acts on.
- **Pin the desk terminal to tmux.** Nightwatch would keep working through the
  deprecation window. Rejected: it re-pins a spawn kind the tmux removal just
  finished unpinning, and it postpones the "does not work on the holder" notice
  to the day tmux is deleted.
- **Holder wins: turning the holder on sets the mode to off.** Rejected: a
  setting silently rewritten by another setting's switch. The symmetric refusal
  keeps every write behind the user's own gesture, and the boot reconcile is the
  one exception because no gesture is available at boot.
- **Hide the controls while the holder is on.** Rejected: a mode that vanishes
  with no explanation reads as a bug, and the Settings toggle would still point
  at nothing.
- **Port the desk now.** Two to four days, most of it moving Claude-session
  classification off the screen. Deferred to #907; that classification work is
  the redesign's to do where it is not deprecated on arrival.

## Relationship to other documents

- [`2026-07-26-fleet-supervision-design.md`](2026-07-26-fleet-supervision-design.md)
  is the replacement.
- [`../nightwatch.md`](../nightwatch.md) is the as-built audit of what is being
  deprecated.
- [`2026-08-30-pty-holder-session-transport-design.md`](2026-08-30-pty-holder-session-transport-design.md)
  defines the transport and `Config.ptyHolderDefault`.
- Issue #851 tracks the tmux removal; issue #907 records the deferred port.

# `tbd terminal close` — design

**Status:** proposed, not implemented
**Date:** 2026-07-25

## 1. Why

`tbd terminal` has no `close`. The daemon has had the semantic all along —
`terminal.delete` (`RPCProtocol.swift:113`), handled by `handleTerminalDelete`
(`RPCRouter+TerminalHandlers.swift:445-485`), which the SwiftUI app has been
calling for tab-close since forever (`DaemonClient.swift:663-669`). Only the CLI
never got a surface over it.

The gap has been actively harmful, not merely absent.

### 1.1 The phantom command

`Sources/TBDShared/NightwatchDeskPrompts.swift` — a **compiled-in** desk tick
prompt (at `33494d80:112`, before the fix in this branch) — instructed sessions:

> Remedy: call `tbd terminal close --all` on the desk, let daemon respawn fresh

Both halves are wrong: the command does not exist, and the daemon does not
respawn desk sessions. This is the origin of the "RESPAWN FLAGGED" instruction
that has sat inert in the nightwatch queue since 2026-07-20.

### 1.2 The workaround is worse than a ghost row

Lacking a CLI close, `handoff.py`'s `cmd_close()` reaches around the daemon:
resolve the row via `tbd terminal list --json`, derive the tmux server from
`$TMUX`, then `tmux -L <server> kill-window -t <windowID>`. That kills the window
and leaves the DB row live. What follows is not a ghost — it is a resurrection:

1. **The app's dead-window path parks it, within seconds.**
   `terminal.recreateWindow` → `RPCRouter+TerminalHandlers.swift:737-759`: a
   Claude-resumable row whose window is gone gets `setHibernated(id:sessionID:)`
   — no `reason:` argument, so the reason is nil.
2. **Reconcile does the same, later.** `WorktreeLifecycle+Reconcile.swift:282-289`
   parks Claude-resumable rows with `reason: .recovery`, preserving the session
   ID. Only plain shell/Codex rows get deleted (`:290-294`).
3. **Focus-wake resurrects it.** `AppState+Hibernation.swift:306-317` excludes
   only `hibernateReason == .manual`; the comment is explicit that "nil-reason
   (legacy), auto, and recovery parks still focus-wake." Navigating to the
   worktree respawns `claude --resume` on the retired session.

So the relay can end with **predecessor and successor both live on the same
desk**. It also loses the scrollback: `terminalHistory.captureOnClose` never
runs, so the retired session never appears in Session History → Closed Terminals.

### 1.3 Reconciliation verdict

Asymmetric, and the asymmetry is deliberate:

| Direction | Behavior | Evidence |
| --- | --- | --- |
| tmux window with no DB row | killed + reaped | `Reconcile.swift:373-381` |
| DB row with no tmux window | Claude-resumable → **parked**; shell/Codex → deleted | `Reconcile.swift:282-294` |

Reconcile is **not** on a timer. Its only callers are daemon startup
(`Daemon.swift:200`), repo-add (`RPCRouter+RepoHandlers.swift:60`), and
`tbd cleanup` (`RPCRouter+TerminalHandlers.swift:1744`). `tbd cleanup` therefore
does **not** clean up an externally-killed Claude terminal in any useful sense —
it parks it into the wakeable state described above.

## 2. Command surface

```
tbd terminal close --terminal <uuid> [--force] [--json]
tbd terminal close <worktree> --all [--force] [--dry-run] [--json]
```

```swift
struct TerminalClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a terminal: capture its scrollback to Closed Terminals history, kill its tmux window, remove it from TBD. Idempotent: closing an already-closed terminal is a no-op.",
        discussion: """
            Closing is immediate and final for the terminal row. The pane's
            scrollback is captured into Session History → Closed Terminals
            (best-effort), any pending session-limit auto-resume is cancelled,
            and the tab disappears from the app. A Claude session's transcript
            survives on disk, and a closed Claude terminal can be revived from
            Closed Terminals history.

            By default a Claude/Codex terminal that is mid-turn or holding a
            permission prompt is refused — pass --force to close it anyway.

            A terminal cannot close itself. Spawn a successor and have it close
            you (see the nightwatch handoff relay).

            `<worktree> --all` closes every terminal in ONE worktree; the
            calling terminal is excluded and reported as skipped. This does NOT
            archive the worktree — a worktree with zero terminals stays active.
            Use `tbd worktree archive` for that.
            """
    )

    @Argument(help: "Worktree name or ID (required with --all, forbidden otherwise)")
    var worktree: String?

    @Option(name: .long, help: "Terminal ID to close")
    var terminal: String?

    @Flag(name: .long, help: "Close ALL terminals in <worktree> (the calling terminal is excluded)")
    var all = false

    @Flag(name: .long, help: "Also close terminals that are mid-turn or waiting on a permission prompt")
    var force = false

    @Flag(name: .long, help: "List what would be closed without closing anything (--all only)")
    var dryRun = false

    @Flag(name: .long, help: "Output JSON")
    var json = false
}
```

`validate()` enforces exactly one of `--terminal` XOR (`worktree` + `--all`). A
bare positional worktree with no `--all` is a `ValidationError` — a typo'd
positional must never silently mean "close everything".

`--terminal` is an `@Option`, matching the newer house pattern (`send`, `wake`,
`focus`, `swap-profile` — `TerminalCommands.swift:122,161,207,391`) and freeing
the positional for the worktree, matching `terminal list <worktree>`.

There is **no** `TBD_TERMINAL_ID` default for `--terminal`. Other commands
default to it (`NotifyCommand.swift:64-69`, `FakeRateLimitCommand.swift:31`), but
here it would make a bare `tbd terminal close` mean "close myself" — the one
thing this command refuses.

### JSON schemas

Single:
```json
{"terminalID": "…", "closed": true, "alreadyGone": false, "claudeSessionID": "…|null"}
```

`claudeSessionID` is echoed so an autonomous caller retains a resume pointer
after the row is gone.

Bulk:
```json
{"worktreeID": "…",
 "closed":  [{"terminalID": "…", "claudeSessionID": "…|null"}],
 "skipped": [{"terminalID": "…", "reason": "self|working|waiting_for_user"}],
 "failed":  [{"terminalID": "…", "error": "…"}]}
```

`--dry-run` emits the same shape with `wouldClose` in place of `closed`.

### Deliberately excluded

- **Fleet-wide `--all`.** ~40 worktrees / ~93 panes. A shell-history replay would
  decapitate the fleet. Anyone who genuinely wants it can loop
  `tbd worktree list --json`, which at least forces them to write the loop.
- **`--graceful` / typed `/exit`.** Knowing the composer is idle and empty
  requires reading rendered screen text — banned by the no-TUI-scraping rule.
  The hibernation subsystem already demonstrates that process-kill plus
  `claude --resume` is lossless for a Claude session.
- **A self-close override.** See §4.
- **`--except <id>`.** See §6, D2 — deferred, not rejected.
- **`--no-capture`.** Capture is already best-effort and cheap.
- **A `delete` alias.** One user-facing verb: "close" (matching the app's "Close
  Tab" and "Closed Terminals"). The RPC keeps its `terminal.delete` name.
- **A default-off feature flag.** The flag rule targets features that act
  *without a user gesture*. Every invocation here explicitly names its target —
  the same category as `worktree archive`, which is unflagged and destructive —
  and the underlying daemon capability has shipped for months behind the app's
  tab-close. The rails in §3-§4 are the safety story. Per the branching-conditional
  rule, the rail itself gets a test on both branches.

## 3. Semantics

| Terminal state | default | `--force` | under `--all` | under `--all --force` |
| --- | --- | --- | --- | --- |
| Idle Claude/Codex (`.idle`/`.unknown`) | closed | closed | closed | closed |
| Working (`.working`), window alive | **refused**, exit 2 | closed | skipped, reported | closed |
| Waiting on permission (`.waitingForUser`), window alive | **refused**, exit 2 | closed | skipped, reported | closed |
| `.working`/`.waitingForUser` but **window dead** | closed (rail is liveness-qualified — see §6 D1) | closed | closed | closed |
| Plain shell (`activityState` is agent-fed; shells stay `.unknown`) | closed | closed | closed | closed |
| Hibernated-parked, window alive | closed; resumes cancelled; scrollback captured | same | closed | closed |
| Recovery-parked, window already dead | closed; **capture stores nothing** (dead pane); session becomes unreachable from TBD, transcript survives on disk | same | closed | closed |
| `keepWarm: true` | closed — keepWarm exempts from *auto-hibernation* only (`Models.swift:309-312`), it is not close protection | same | closed | closed |
| Pinned (`pinnedAt`) | closed — pin is a dock affordance; the app closes pinned tabs too | same | closed | closed |
| Pending scheduled resume | closed; resume cancelled (`RPCRouter+TerminalHandlers.swift:452-455`) | same | closed | closed |
| Already gone (no DB row) | **no-op success**, exit 0, `alreadyGone: true` | same | n/a | n/a |
| Self (`--terminal` == `$TBD_TERMINAL_ID`) | **refused**, exit 2 | **still refused** | skipped, `reason: "self"` | skipped |
| Mid-`terminal send` race | close wins; a send arriving after row deletion errors "Terminal not found"; a send already in flight lands in a dying pane and is lost | same | same | same |
| Scratch-worktree terminal | identical — the daemon reads `worktree.tmuxServer` from the row, satisfying the pane-ids-collide rule by construction | same | same | same |

**Closing the last terminal is explicitly permitted and is not an archive.** The
app already closes the last tab with no guard — `AppState+Tabs.swift:148-200`
lets the tab count reach zero (`remaining > 0 ? min(index, remaining - 1) : 0`).
The worktree row survives, and the tmux server survives because the server-kill
sweep keys on live *worktree* rows, not terminal counts
(`Reconcile.swift:348-361`). Close and archive stay distinct lifecycle events.

## 4. Refusals

All to stderr.

| Refusal | Text | Exit |
| --- | --- | --- |
| Self-close | `Refusing to close the calling terminal (<uuid>). A terminal cannot close itself — spawn a successor and have it close this one.` | 2 |
| Busy, no `--force` | `Terminal <uuid> is <mid-turn\|waiting on a permission prompt> (activityState=<working\|waiting_for_user>). Closing now would kill in-flight work. Pass --force to close anyway.` | 2 |
| Bare worktree, no `--all` | `To close every terminal in a worktree, pass --all explicitly.` | 64 |
| `--terminal` with `--all` | `Specify either --terminal <id> or <worktree> --all, not both.` | 64 |
| Invalid UUID | `Invalid terminal ID: <s>` (matches `TerminalCommands.swift:136`) | 1 |

`ExitCode(2)` has house precedent (`DoctorCommand.swift:34,39`).

**Self-close is refused with no override flag.** The tmux window kill SIGHUPs the
calling shell, so the `tbd` process dies mid-`recv` and can never report its own
result; the agent's turn is chopped mid-tool-call. A daemon-side "reply first,
tear down after a delay" deferral would work mechanically and is a legitimate
future design — this is a scope call, not an impossibility. It is deferred
because no consumer exists: `handoff.py` refuses self-close for an independent
availability reason (if the spawn failed, the predecessor is the only thing still
watching the desk), and successor-closes-predecessor is the documented standing
rule. Build the deferral when a real consumer appears.

Under `--all` the caller is excluded and **reported** as `reason: "self"` in both
JSON and text — never silently dropped.

## 5. Failure modes

| Situation | Exit |
| --- | --- |
| Success / already gone / dry-run / bulk with only skips | 0 |
| Daemon not running (`SocketClient.swift:19-21`) | 1 |
| Bulk with any `failed` entries (partial results still printed) | 1 |
| Refused (self, busy) | 2 |
| Usage error | 64 |

Best-effort, inherited from the daemon handler and acceptable:

- **Scrollback capture failure** is swallowed inside `captureOnClose`; the close
  proceeds with no history entry. Not surfaced per-call — the handler does not
  know, and the result shape should not claim otherwise.
- **`killWindow` failure** is `try?`-swallowed
  (`RPCRouter+TerminalHandlers.swift:467`); the row is deleted regardless, and
  the orphaned window is later reaped by reconcile's untracked-window sweep
  (`Reconcile.swift:373-381`). Self-healing.
- **A wedged process surviving SIGHUP.** `handleTerminalDelete` uses plain
  `tmux.killWindow` (`TmuxManager.swift:508-515`), *not* the reaper-escalating
  `killWindowAndReap` that reconcile uses (`WorktreeLifecycle.swift:164-171`).
  This is a pre-existing gap shared with the app's tab-close, not something this
  command introduces. Recommended as a separate follow-up PR.
- **TOCTOU under `--all`**: a terminal closed between the list and the delete
  resolves as `alreadyGone`. Harmless once idempotency lands.

## 6. Reconciled disagreements

The independent design (Fable) and this reading agree on the shape. Four points
where they differ, and the call taken:

**D1 — the busy rail must be liveness-qualified.** Refusing on
`.working`/`.waitingForUser` has strong precedent: `isManuallyHibernatable`
(`Models.swift:434-439`) refuses exactly those two states for manual "Hibernate
now", and `worktree archive`'s `--force`-gates-a-safety-check shape matches
(`WorktreeCommands.swift:374-404`). Adopted. **But** `activityState` is hook-fed
and carries **no timestamp** — `Models.swift:296` is a bare enum with nothing to
age it out. A session that dies mid-turn (crash, OOM, killed pane) stays
`.working` forever, and an unqualified rail would then refuse forever on exactly
the wedged terminal you most need to close, turning the safety rail into a trap
for the command's primary cleanup use case. So the rail refuses only when the
state is busy **and** `tmux.windowExists` confirms a live window. A dead-window
row cannot be mid-turn — and that is precisely the zombified-predecessor state
`handoff.py` creates today, which must remain closeable without `--force`.

**D2 — `--except` deferred, not shipped.** The relay's real shape is "close
everything but me", and self is already auto-excluded. The remaining
justification (recycle a desk, keep the fresh session) is real but is expressible
as N single-target closes, and the successor in the relay is spawned *after* the
close decision. Ship the smaller surface; add `--except` when a second consumer
appears.

**D3 — self-close framing.** Both refuse it; recorded above with the deferral
door explicitly left open rather than as a claim that it cannot be built.

**D4 — the change is four pieces, not three.** `SocketClient` does not surface
`errorCode` to CLI callers today (no references in `Sources/TBDCLI/`), so
branching on `terminalBusy` requires a small addition there alongside the three
daemon changes in §7.

## 7. Required changes

Not pure CLI. Three daemon changes plus one CLI plumbing change, all additive and
decode-compatible.

1. **Idempotent not-found.** `handleTerminalDelete` currently returns
   `RPCResponse(error: "Terminal not found: …")`
   (`RPCRouter+TerminalHandlers.swift:448-450`). Return a success
   `TerminalDeleteResult(closed: false, alreadyGone: true)` instead. This matches
   the idempotency contract `terminal wake` already sets
   (`TerminalCommands.swift:158,190`). String-matching the error text in the CLI
   is the fragile alternative, and the text embeds a UUID. App-invisible: the app
   calls `callVoidAsync` and ignores results (`DaemonClient.swift:663-669`); the
   only behavior change is that a double-close stops logging an error.
2. **Rails, daemon-side.** Add optional `respectActivityRails: Bool?` to
   `TerminalDeleteParams` (`RPCProtocol.swift:1159-1162`; optional per the
   Models decode-compat rule). `nil`/`false` keeps today's unconditional close,
   so the app's tab-close — a direct human gesture — is unchanged. `true` (the
   CLI default, dropped by `--force`) applies the liveness-qualified rail from
   §6 D1 and returns `RPCErrorCode.terminalBusy`. Daemon-side because the state
   lives in the daemon's DB and a CLI-side check on a listed row would be
   racier.
3. **Structured error code.** Add `case terminalBusy` to `RPCErrorCode`
   (`RPCProtocol.swift:86-91`, currently a single `profileMissing` case).
   `RPCResponse(error:code:)` already carries it (`RPCProtocol.swift:50-55`).
4. **CLI plumbing.** Surface `errorCode` through `SocketClient` so the command
   maps `terminalBusy` → exit 2 without parsing prose.

Result type: `TerminalDeleteResult(closed: Bool, alreadyGone: Bool,
claudeSessionID: String?)`, mirroring wake's `{"woken": bool}` precedent.

## 8. Migration

**`handoff.py` `cmd_close()`** collapses to a single call:

```python
def cmd_close(args):
    target = args.close_predecessor
    if target == os.environ.get("TBD_TERMINAL_ID"):
        sys.exit("refusing to close myself — pass the PREDECESSOR's terminal id")
    r = _run(["tbd", "terminal", "close", "--terminal", target, "--json"])
    if r.returncode == 0:
        out = json.loads(r.stdout or "{}")
        print(f"closed predecessor {target}" + (" (was already gone)" if out.get("alreadyGone") else ""))
        return 0
    sys.exit(f"close failed (exit {r.returncode}): {r.stderr.strip()}")
```

Deleted outright: the `$TMUX` server derivation, the `terminal list` row lookup,
the raw `kill-window`, and the `"can't find"` stderr sniff. The local self-check
stays as a belt — the CLI also refuses, but failing before the subprocess gives a
clearer message. The predecessor now actually gets history capture, row deletion,
and a `.terminalRemoved` broadcast.

A predecessor that went idle per the relay protocol reads `.idle` and closes
cleanly. One still finishing its last message reads `.working` and is correctly
refused — the successor should retry briefly rather than lead with `--force`.

The successor prompt's step 2 (`handoff.py:107-109`) should name the new command.

**`handoff.py` is the only raw `kill-window` caller to migrate.** It now ships
from `NightwatchSkillContent.handoffPy`, so the migration is a source edit in
this repo rather than a hand-patch of the installed copy — and the daemon
rewrites the installed copy on every start, so editing only the on-disk file
would be reverted. Every other `kill-window` reference is either daemon code
using `worktree.tmuxServer` correctly, or prose in `docs/specs/`.

**One-time fleet sweep.** Shipping this does not retroactively fix predecessors
already zombified by the old path. Those rows are parked with `.recovery` (or nil
reason) and will focus-wake. `tbd terminal close --terminal <id>` closes them
correctly once available, but their scrollback is already unrecoverable — the
pane is gone.

## 9. Doc/reality mismatches found

1. **`Sources/TBDShared/NightwatchDeskPrompts.swift:112`** — compiled-in desk
   prompt instructs `tbd terminal close --all`, a command that does not exist,
   and claims "let daemon respawn fresh", which the daemon does not do. Must be
   rewritten to the handoff relay. Note that even after this ships the old text
   stays wrong: `close --all` on the desk's own worktree excludes the caller by
   design, so it would never recycle the desk session that ran it.
2. **`docs/superpowers/specs/2026-05-09-pending-askuserquestion-rendering-design.md:228`**
   — cites "`tbd terminal close` / explicit terminal close" as an existing CLI
   trigger. The RPC half was real; the CLI half never existed.
3. **nightwatch `SKILL.md:91-92`** — currently correct ("that command does not
   exist"), becomes stale the moment this ships. Update in the same change that
   migrates `handoff.py`, keeping the handoff relay as the documented
   context-ceiling remedy; `close --all` was never the right tool for it.
4. Queue records (`acted.jsonl:32,57`, `judge-summary.txt:118-119`) memorialize
   the mismatch. Leave as-is — they are logs.

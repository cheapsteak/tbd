# Mod-only park guard

## Problem

Parking a Claude session ends its process. Anything the person typed into the composer and has not sent dies with it, unless something saved it first. Two mechanisms guard that today.

- **The pending-input scrape** – `HibernationSafetyChecks.hasPendingInput` reads the pane's rendered text, looks for a `>` prompt line holding something other than a placeholder, and refuses the park when it finds one. It is TBD's last sanctioned screen scraper. It fails silently in the unsafe direction: when Claude Code changes how it draws the composer, the scrape stops seeing drafts and parks proceed over them. That failure direction is why `v50` turned the idle sweep off by default.
- **The session mod's composer-draft feature** – the mod saves the composer's contents to the session's directory as the person types, and restores them on the next spawn. A park of a session whose mod confirms the save proceeds with nothing lost. See [`2026-10-19-tbd-session-mod-design.md`](2026-10-19-tbd-session-mod-design.md).

The feature is behind `composer_draft_enabled`, which defaults off. So on an ordinary install every session is spawned without it, and the scrape is still the only guard. A typed `/exit` ends those parks, and it is safe only because the scrape refused first. A second, opt-in guard, the keystroke veto (`hibernate_input_veto_enabled`), refuses an idle park when a keystroke arrived after the session went idle.

## Decision

The mod is the only draft guard. The scrape, the typed `/exit` and the keystroke veto are deleted. Every park ends the Claude process by signal, so nothing is ever typed into a composer. Automatic parking turns the composer-draft feature on, so the sessions parked without anyone asking are the ones the mod protects.

## Which parks go ahead

A park's outcome depends on two things: how the session was spawned, read from its `spawn.json` and liveness as today, and what started the park.

| Session | Manual park | Merge-park, idle sweep | Profile swap |
|---|---|---|---|
| Spawned with the feature, mod confirmed | park | park | proceed |
| Spawned without the feature | park | park | proceed |
| Spawned with the feature, mod not confirmed | park | skip, logged | proceed |

- **Confirmed** – the mod has saved the draft, and restores it on the next spawn. Unchanged.
- **Spawned without the feature** – nothing saved the draft, and nothing can see it. Every park proceeds, and an unsent draft is lost. On an install with automatic parking on, such a session exists only until its next spawn: sessions already running when the feature turned on, through an update or a settings change.
- **Spawned with the feature, mod not confirmed** – a stale heartbeat, a missing or torn file, managed settings that block plugins, or a Claude Code too old for mods. A manual park proceeds without asking, and an unsent draft may be lost. An automatic park skips the session and logs the reason, as the session-mod design already specifies. Unlike the case above, this one does not resolve itself at the next spawn, so parking it automatically would leave automatic parking with no guard on such a machine.

Codex sessions are never parked, as before.

Every park ends the same way. On tmux, `TmuxSignalEnding` sends SIGTERM to the Claude process found under the pane on the process table, then `respawn-window -k` guarantees the end. On the pty-holder transport, the ladder starts at its terminate rung. SIGTERM runs Claude Code's graceful shutdown, so a confirmed session's mod still makes its final save in `session.end`.

## The effective composer-draft value

The composer-draft feature is on when any of these holds:

- `composer_draft_enabled`, resolved through `Config.composerDraftDefault` when NULL
- `auto_hibernate_enabled` – the idle sweep
- `auto_hibernate_on_merge_default` – park-on-merge for every worktree without an override
- any worktree whose `autoHibernateOnMerge` override is true

The value is resolved where `ConfigStore` builds `Config`, with one query over the worktree overrides, so every reader agrees: `SessionModFeature.enabled(in:)` at spawn and plugin sync, and the app. `Config` also carries whether automatic parking is what turned it on. Settings shows the composer-draft toggle on and greyed in that case, with the caption "On while auto-hibernation is on".

Nothing is written. The stored `composer_draft_enabled` keeps whatever the person chose, so an explicit OFF is overridden while automatic parking is on and holds again once it is off. Every write that can change the effective value re-syncs the plugin, as the composer-draft toggle already does: the idle-sweep toggle, the global park-on-merge default, and a worktree's park-on-merge override.

**Updates.** An install with automatic parking on and the feature off needs no migration. The first daemon start after the update resolves the feature on and writes the mod into the plugin, and every spawn after that carries it. Sessions already running stay "spawned without the feature" until they next spawn, and automatic parks end them by signal.

## Deletions

- `HibernationSafetyChecks.hasPendingInput` and its helpers, its three call sites (the tmux park's pre-lock and under-lock reads and the holder park's screen read), and its `.swiftlint.yml` exclusion. `isTranscriptTailValid` stays. No sanctioned scraper remains, and the root `CLAUDE.md` "No TUI screen-scraping" section says so. The hibernation display snapshot stays: it shows the parked screen and decides nothing.
- The typed `/exit` ending and its Escape and Ctrl+C fallbacks on tmux, and the holder ladder's typed-exit rung. `ParkEndingStyle` goes with them, since every park ends by signal.
- The manual-park confirmation: `ComposerDraftParkDecision.refuse`, `terminal.hibernate`'s `overrideUnconfirmedDraft` parameter, the app's prompt, and the refusal outcome a park records for it. The skip outcome and its log line stay.
- The shadow comparison between the feature and the scrape.
- The keystroke veto: `InputActivityTracker`, its rail in `HibernationGate`, the control-mode input hook that feeds it, its RPC, its Settings toggle, and `hibernateInputVetoEnabled` on `Config` and on the capabilities result. `config.hibernate_input_veto_enabled` is retired under [`2026-10-24-column-retirement-design.md`](2026-10-24-column-retirement-design.md) at schema epoch 2.

The session-mod design's "Parking", "Soak and graduation" and "Deletion after graduation" sections are rewritten to state this design. Graduating `composer_draft_enabled`, flipping its default for every install, stays a separate decision with the soak signals that design names, minus the scrape comparison. The `Config.autoHibernateEnabled` documentation loses its scrape rationale.

## What this gives up

- A draft typed into a session spawned without the feature is lost when that session parks, by hand or automatically. Before, the scrape refused such a park when it saw the draft.
- A manual park of a session whose mod is not confirmed proceeds without asking.
- On a machine where the mod never loads, automatic parking skips every session, so the idle sweep and park-on-merge reclaim nothing there. The skip is logged with its reason.

## No flag

This ships without its own flag, deliberately. The behavior it changes sits behind two flags that already exist and default off: automatic parking and composer-draft. A new flag would have to keep the scrape and the typed `/exit` alive behind it, which is the code this design removes.

## Testing

- **The park decision** – each row of the table against each policy, including a profile swap.
- **The effective value** – the stored flag ON, OFF and NULL, crossed with the idle sweep, the global park-on-merge default and a single worktree override; an explicit OFF reads on while any of them holds and off once none does; the "turned on by automatic parking" signal follows.
- **Plugin re-sync** – changing the idle sweep, the park-on-merge default or a worktree override re-syncs the plugin when the effective feature set changes, and does nothing when it does not.
- **Endings** – a park on tmux and on the holder ends by signal for every row of the table; nothing is written to the pane or pty.
- **Updates** – a database with `auto_hibernate_enabled = 1` and `composer_draft_enabled` NULL resolves the feature on at startup, and the plugin written then carries the mod.
- **The veto** – the retired-column list carries `config.hibernate_input_veto_enabled` at epoch 2, and `ConfigRecord` no longer declares it.

## Rejected alternatives

- **Only the idle sweep turns the feature on.** Park-on-merge also parks without a gesture, and with the scrape gone its sessions would have no guard.
- **Turn the feature on for every install.** That graduates `composer_draft_enabled` before the soak its design asks for.
- **Write the flag once.** Turning automatic parking on, or a one-time migration, could set `composer_draft_enabled = 1`. That leaves the feature on after automatic parking is turned off, and it stores a value the person never chose, which the three-state flag rule exists to prevent.
- **Automatic parking waits for the feature.** Skipping every session until the person turns the feature on keeps the flags independent, but leaves automatic parking doing nothing on every install that already uses it.
- **Ask before a manual park the mod cannot vouch for.** It loses nothing silently, at the cost of a prompt on every manual park while the feature is off.
- **Skip sessions spawned without the feature until they respawn.** Nothing is lost, but long-lived sessions are not reclaimed until something respawns them.
- **Park unconfirmed sessions by signal on automatic parks too.** Memory is always reclaimed, but a machine where the mod never loads would park with no draft protection at all.
- **Keep the keystroke veto.** It guards only automatic parks, sees only keystrokes routed through tmux control mode, and runs only while opted in. The mod covers the same case for every park it confirms.

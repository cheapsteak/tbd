# Deep dive: Claude Code's `fallbackModel`

*Scout doc — focused thinking on one setting. Lens and rules: [`../claude-code-kb.md`](../claude-code-kb.md).*

## Problem framing

TBD spawns and supervises a fleet of concurrent interactive `claude` sessions. A fleet
hammering the API is exactly the scenario where the primary model gets overloaded —
and today, when that happens, a TBD-spawned session hard-fails a turn instead of
degrading. Claude Code's `fallbackModel` machinery is the lever: TBD can configure its
spawned sessions to **drop to an alternate model on overload rather than failing**.
That graceful-degradation win is the whole focus of this doc.

*(Out of scope by decision: TBD does not need to observe or surface which model a
session is actually running on. We're using `fallbackModel` to harden sessions, not to
reflect live model state in the UI.)*

## What `fallbackModel` actually is (with sources)

It is a primary-model-degradation mechanism. When the primary model is overloaded or
unavailable, Claude Code falls back to a configured alternate rather than failing.

**The setting itself — v2.1.166** ([CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#21166)):

> Added `fallbackModel` setting to configure up to three fallback models tried in
> order when the primary model is overloaded or unavailable; `--fallback-model` now
> also applies to interactive sessions

Two things land here: a new **`settings.json` key (`fallbackModel`)** that takes an
**ordered list of up to three models**, and the **`--fallback-model` CLI flag**. But
**the flag and the setting are not interchangeable for TBD** — see the verified
contract below; the `--print`-only restriction on the flag is the decisive fact.

**When it kicks in.** Three distinct triggers, from three changelog entries:

1. *Primary overloaded or unavailable* — the headline trigger above.
2. *Primary not found → sticky for the session* — v2.1.152:
   > Claude Code now switches to your configured `--fallback-model` for the rest of
   > the session when the primary model is not found, instead of failing every request

   The switch is **sticky for the rest of the session**, not per-turn. Once degraded,
   it stays degraded.
3. *Retry-once on unexpected error* — v2.1.166:
   > Claude Code now retries a turn once on the fallback model when the API rejects an
   > unexpected non-retryable error; auth, rate-limit, request-size, and transport
   > errors still surface immediately

   So fallback is **not** triggered by auth, rate-limit, request-size, or transport
   errors — those surface immediately. Fallback is for overload / model-not-found /
   unexpected-non-retryable.

**It survives backgrounding** — v2.1.x:

> `/bg` and `←`-detach now preserve `--fallback-model`, so backgrounded workers
> degrade to the fallback model on overload instead of hard-failing.

**Not yet in public docs.** The `fallbackModel` *setting* (v2.1.166) is not yet listed
in the [settings reference](https://code.claude.com/docs/en/settings) — confirmed by
fetching it. Treat the changelog + the verified CLI behavior below as the authority.

### Verified locally (claude 2.1.167, this machine)

Forced fallback by setting the **primary to a bogus model id** (the "primary not found"
path), then read which model actually served the turn from `--output-format json`'s
`modelUsage` key. Results:

- **`--fallback-model` is `--print`-only.** Its `--help` text on 2.1.167:
  > Enable automatic fallback to specified model(s) when the default model is
  > overloaded or not available. **Accepts a comma-separated list to try each in
  > order. Re-tries the primary at the start of each user turn. (only works with
  > `--print`)**

  This *contradicts* the v2.1.166 changelog line "`--fallback-model` now also applies
  to interactive sessions." On 2.1.167 the help still restricts the flag to `--print`.
  **TBD spawns interactive sessions, so the flag is the wrong lever for TBD.**
- **The `fallbackModel` *setting* works and is the right lever.** With
  `--model bogus-primary-1 --settings <file>` where the file is
  `{"fallbackModel":["claude-haiku-4-5-20251001"]}` (array form) **and no flag**, the
  turn was served by `claude-haiku-4-5-20251001` (`modelUsage` key). The setting is
  honored and takes an **array**.
- **Ordering confirmed.** `--fallback-model bogus-fallback-2,claude-haiku-4-5-20251001`
  skipped the dead second-position model and landed on haiku — it tries each in order.
- **Syntax differs by surface:** the *flag* takes a **comma-separated string**; the
  *setting* takes a **JSON array**.
- **Re-tries the primary each user turn** (per the help) — so it is *not* purely "sticky
  for the rest of the session" as the v2.1.152 prose implied; it reattempts the primary
  at the top of each turn and only falls back when the primary is still unavailable.

*(All tests were in `--print` mode, the only mode scriptable from a shell. Whether the
**setting** is honored in an **interactive** session is the one residual verify — see
Risks. Settings keys normally apply across all modes, and only the *flag* is documented
as `--print`-only, so this is expected to work.)*

---

## Ranked ideas

### 1. Inject `fallbackModel` into the existing `--settings` overlay so TBD sessions degrade instead of hard-failing — **Integration** — effort **S**

**TBD-side change:** Add a `fallbackModel` key (a JSON **array** of up to three model
ids) to the overlay body in `ClaudeHookOverlay.generateBody()`
(`Sources/TBDDaemon/Hooks/ClaudeHookOverlay.swift` ~L87–139, currently `hooks`-only).
TBD already appends `--settings <overlay>` to every spawned `claude`, so this rides the
mechanism that's already there — no new flag, no new spawn-arg plumbing. Source the
array from a new optional `fallbackModels` field on `ModelProfile`.

> Verified: `--model bogus --settings {"fallbackModel":["claude-haiku-4-5-20251001"]}`
> served the turn on haiku (see "Verified locally" above).

**Why the setting, not the flag:** the `--fallback-model` *flag* is `--print`-only on
2.1.167 (verified). TBD spawns **interactive** sessions, so the flag would be ignored —
the **setting** is the only lever that reaches TBD's sessions. This is actually the
*cleaner* path: TBD's `--settings` overlay already exists for exactly this kind of
non-invasive config injection.

A multi-agent TBD fleet is the canonical overload scenario, so graceful degradation has
outsized value here.

**Touches:** `ModelProfile` (`Sources/TBDShared/Models.swift` ~L274–316, add optional
`fallbackModels: [String]?` — must be optional/defaulted so existing rows decode),
`ModelProfileResolver` (`Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift`,
carry it through `ResolvedModelProfile`), and `ClaudeHookOverlay` (write the
`fallbackModel` array into the overlay body, threading the resolved profile in). No new
RPC, no UI required for a v1 with a single sensible default fallback.

**Note:** TBD currently sets the *primary* model via the `ANTHROPIC_MODEL` env var, not
`--model` (commit #253). The forced-fallback test used `--model`; confirm `fallbackModel`
also engages when the primary is supplied via `ANTHROPIC_MODEL` (different layer — should
be fine, but verify).

---

### 2. Per-worktree primary + ordered fallback list in the model-profile UI — **TBD-side** — effort **M**

**TBD-side change:** Build on #253 ("let Claude-direct (OAuth) profiles set a model")
by letting a profile/worktree carry the **ordered fallback list (up to three)**,
surfaced in the model-profile editing UI. This is the configuration layer that makes
Idea 1 user-settable rather than a single hard-coded default.

> "configure up to three fallback models tried in order when the primary model is
> overloaded or unavailable" — v2.1.166

**Touches:** `ModelProfile` (the `fallbackModels` list from Idea 1), the model-profile
editing UI (a small ordered-list editor capped at three), resolver, `ClaudeHookOverlay`.
Lower priority — do it after Idea 1 proves the plumbing; a global default is enough to
ship value first.

---

## Risks / open questions / verification needed

1. **(Residual) Does `fallbackModel` (the setting) engage in an *interactive* session?**
   All local tests were in `--print` mode — the only mode scriptable from a shell — and
   the setting worked there. The *flag* is documented `--print`-only, but the *setting* is
   not, and settings keys normally apply across modes, so this is expected to work. Still
   worth a one-time confirmation via a real TBD-spawned interactive session: force a
   fallback (bogus primary) and inspect the session transcript JSONL for the serving
   model. **This is the gate before relying on Idea 1 in production.**

2. **Interaction with OAuth / `ANTHROPIC_MODEL`.** TBD sets the *primary* via the
   `ANTHROPIC_MODEL` env var (not `--model`); the forced-fallback test used `--model`.
   Confirm `fallbackModel` engages when the primary comes from `ANTHROPIC_MODEL`, and that
   the chosen fallback models are even *available* on the account tier in use (Max-plan
   model availability has historically been finicky — cf. the old "Max users specifying
   Opus still fell back to Sonnet" fix).

3. **Overlay precedence for the `fallbackModel` key.** TBD's `--settings` overlay is
   documented to *merge* the `hooks` array with the user's `~/.claude/settings.json`.
   Confirm a scalar/array `fallbackModel` in the overlay isn't *overridden* by (or
   silently overriding) a user-set `fallbackModel` in an unexpected way. Low risk — most
   users won't set it — but worth a glance.

4. **Contract not yet documented; flag/changelog mismatch.** `fallbackModel` is
   changelog-only as of v2.1.166 and absent from the settings reference. The v2.1.166
   changelog says the *flag* "now also applies to interactive sessions," but 2.1.167 help
   still marks the flag `--print`-only. Pin to observed behavior, not the prose, and
   re-check on CLI upgrades.

## Resolved by local testing (claude 2.1.167)

- **Syntax:** flag = comma-separated string; setting = JSON array. Both tried in order.
- **Ordering:** dead models in the list are skipped; the first reachable one serves.
- **Flag is `--print`-only** → not usable for TBD's interactive sessions; use the setting.
- **`modelUsage` in `--output-format json` reveals the actual serving model** — the tool
  for the residual interactive verification (Risk #1), if exposed there too.

---

## Recommendation

**Ship a small spike of Idea 1, via the `--settings` overlay (not the flag).** Adding a
`fallbackModel` array to TBD's existing overlay (sourced from a new optional
`ModelProfile.fallbackModels`) is low-effort, rides machinery that already exists, needs
no new flag/RPC/UI, and directly hardens TBD's core multi-agent-fleet use case against
overload. Local testing confirms the setting + array form works in `--print`; gate the
production rollout on the one residual check — that the setting also engages in an
**interactive** TBD-spawned session (Risk #1) — then layer Idea 2's UI on top.

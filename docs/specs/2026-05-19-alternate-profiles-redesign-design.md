# Alternate Claude profiles — credential-delivery redesign

**Date:** 2026-05-19
**Status:** Decision doc (no implementation)

## Problem

TBD lets a user run Claude Code under alternate profiles. Today each profile
injects credentials as environment variables at tmux spawn time
(`Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift`):

- **oauth** → `CLAUDE_CODE_OAUTH_TOKEN=<secret>` (a `setup-token`)
- **apiKey** → `ANTHROPIC_API_KEY=<secret>` (+ optional `ANTHROPIC_BASE_URL`,
  `ANTHROPIC_MODEL`, and — for proxy profiles only — `ANTHROPIC_CONFIG_DIR`)
- **bedrock** → `CLAUDE_CODE_USE_BEDROCK=1` + AWS env vars

Two problems motivate a redesign:

1. **Billing divergence is about to sharpen.** Starting **2026-06-15**, Anthropic
   bills `claude -p` / Agent SDK usage on subscription plans from a *separate*
   monthly "Agent SDK credit" pool, distinct from interactive subscription
   limits. Official docs place this warning inside the `claude setup-token`
   section. Strong (but not officially confirmed) indication: a
   `setup-token`-derived `CLAUDE_CODE_OAUTH_TOKEN` is classified as Agent-SDK
   usage **even when used to drive an interactive REPL**. TBD's oauth profiles
   inject exactly such a token — so after 2026-06-15 they would likely stop
   behaving like "a normal terminal-based Claude Code subscription session" and
   instead drain the Agent-SDK pool.

2. **Profile types diverge in shape, which breeds bugs.** oauth/direct-apiKey
   profiles share the host's `~/.claude`; proxy-apiKey profiles get an isolated
   `ANTHROPIC_CONFIG_DIR`. Today's symptom: invoking a Sonnet subagent under an
   apiKey profile fails with *"Usage credits required for 1M context"* while
   Opus and Haiku subagents succeed. (Root cause is upstream Claude Code bug
   #57249 — a subagent inherits the parent's `[1m]` context tier without the
   matching per-model entitlement — but the divergent profile shapes make this
   class of environment-dependent failure easy to hit and hard to reason about.)

## Goal

A single credential-delivery mechanism shared by every profile type, such that:

- oauth profiles bill as ordinary **interactive** subscription sessions, before
  and after 2026-06-15.
- A user can keep **multiple** OAuth subscriptions side-by-side and switch
  between them per-repo / per-session (existing capability — must not regress).
- Profile types differ only in *which credential* is used, not in *how* the
  session is shaped — so environment-divergence bug classes disappear.

Scope is **credentials only**. Profiles do not gain model-selection or
request-rewriting responsibilities.

## Out of scope

- Model selection or subagent-model control as a user-facing profile field.
- An HTTP proxy / wire-level request rewriting layer.
- Fixing upstream Claude Code bug #57249.
- Vertex AI / GCP profiles.

## Key research findings

Sourced from official Claude Code docs, the `anthropics/claude-code` issue
tracker, and corroborating community tooling. Items marked *(inferred)* are not
in official documentation.

1. **2026-06-15 billing split** — `claude -p` / Agent SDK usage on subscription
   plans moves to a separate monthly credit pool. The warning lives in the
   `setup-token` doc section. *(inferred)* `setup-token` tokens are classified
   as Agent-SDK usage regardless of interactive vs. `-p` invocation.
2. **`CLAUDE_CONFIG_DIR` isolates credentials on macOS** *(inferred, proven in
   the wild)* — Claude Code SHA-256-hashes the `CLAUDE_CONFIG_DIR` path and
   derives a unique macOS Keychain service name (`Claude Code-credentials-<hash>`).
   Two `claude` processes with different `CLAUDE_CONFIG_DIR` values hold
   independent logins without clobbering. Multiple community profile-switchers
   (`claude-profile`, `claude-swap`, etc.) depend on this.
3. **`ANTHROPIC_CONFIG_DIR` is not the documented Claude Code variable** —
   `CLAUDE_CONFIG_DIR` is. TBD's current proxy-profile code uses the former and
   relies on partial behavior.
4. **No native multi-account feature** in Claude Code as of ~2.3.x; open feature
   requests (#18435, #44687). `CLAUDE_CONFIG_DIR` is the only isolation lever.
5. **Token refresh race** (#27933) — concurrent `claude` processes sharing one
   credential store can race on OAuth refresh. Pre-exists in TBD today.
6. **`.credentials.json` shape** — `{ claudeAiOauth: { accessToken, refreshToken,
   expiresAt, scopes, subscriptionType } }`; access token ~24h, auto-refreshed
   in place.

## Options considered

### Option A — Status quo + targeted hardening
Keep env-var injection; tighten the oauth path (e.g. always isolate, or never).
**Rejected:** does not address the 2026-06-15 billing reclassification — oauth
profiles still inject a `setup-token` and still risk draining the Agent-SDK pool.

### Option B — HTTP proxy intercepting the Anthropic API
Local proxy attaches auth / rewrites requests.
**Rejected:** large new moving part; overkill for "credentials only" scope; does
not change how `claude` itself classifies the session for billing.

### Option C — Swap a single shared credential store before each spawn
Rewrite `~/.claude` / the shared Keychain entry per spawn.
**Rejected:** concurrency-unsafe — parallel tmux panes on different profiles
would clobber each other; refresh race (#27933) becomes routine.

### Option D — One persistent `CLAUDE_CONFIG_DIR` per profile *(recommended)*
Every profile is a persistent config directory. See below.

## Recommended design — Option D

**Every profile is a persistent `CLAUDE_CONFIG_DIR`.** That directory is the
single delivery mechanism. Profile types differ only in what lives inside it and
which (if any) env var rides alongside.

| Profile | `CLAUDE_CONFIG_DIR` | Extra env | Credential origin | Billing |
|---|---|---|---|---|
| **Default** | `~/.claude` (host native, untouched) | none | host's existing `/login` | interactive subscription |
| **Additional OAuth** | `~/tbd/profiles/<id>/` | none | user runs `/login` once in-pane; credential persists in that dir's hashed Keychain entry, auto-refreshes there | interactive subscription |
| **API key** | `~/tbd/profiles/<id>/` | `ANTHROPIC_API_KEY` (+ `ANTHROPIC_BASE_URL` for proxy) | TBD-stored key | pay-as-you-go API |
| **Bedrock** | `~/tbd/profiles/<id>/` | `CLAUDE_CODE_USE_BEDROCK=1` + AWS vars | AWS credential chain | AWS |

### Why this satisfies the goal

- **Multi-OAuth survives** — each OAuth profile is a real `/login` in its own
  isolated config dir. Per-repo / per-session switching is just "which
  `CLAUDE_CONFIG_DIR` is exported."
- **Billing stays correct** — OAuth profiles never touch `setup-token` /
  `CLAUDE_CODE_OAUTH_TOKEN`. Each is an ordinary interactive `/login` session
  that happens to live in a non-default directory, so it is not reclassified
  into the 2026-06-15 Agent-SDK pool.
- **Unification** — every profile spawns `claude` identically; the only variable
  is the config dir. The oauth-shape vs. apiKey-shape divergence is gone.

### Changes vs. today

1. oauth profiles stop storing a `setup-token` and stop injecting
   `CLAUDE_CODE_OAUTH_TOKEN`. An oauth profile becomes "a config dir you log
   into."
2. Standardize on `CLAUDE_CONFIG_DIR` (the documented var the Keychain hashing
   keys on); drop `ANTHROPIC_CONFIG_DIR`.
3. Config-dir isolation applies to *all* non-default profiles, not just proxy
   ones.
4. First use of a new oauth profile is unauthenticated — TBD detects the empty
   config dir and prompts the user to `/login` once.

### Data model sketch

- `ModelProfile` gains a config-dir association (a stored `configDirPath`, or
  derive `~/tbd/profiles/<id>/` from the profile UUID). New field optional /
  defaulted per the migration rules in `CLAUDE.md`.
- `CredentialKind.oauth` keeps existing but changes meaning: **no Keychain
  secret** — just a config dir the user logs into. apiKey / bedrock unchanged.
- Migration is non-destructive: keep existing oauth profile rows, drop the now
  unused stored `setup-token`, mark the profile "needs login." The default
  profile maps to `~/.claude`.

### The 1M-context subagent bug

Unification makes every profile *behave* identically but cannot change what an
account is entitled to: a Max-subscription oauth profile with extra-usage will
not hit bug #57249; an apiKey profile without Sonnet-1M credits will. The bug
stops being a TBD-architecture artifact but is not erased.

**Optional mitigation:** TBD sets `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` for apiKey
profiles by default — forces 200k context, so no subagent inherits a 1M tier and
the entitlement error cannot fire. This touches model behavior (slightly past
"credentials only"), so it is offered as a recommended-but-optional knob, not
core to the redesign.

## Risks

1. **Keychain path-hashing is undocumented.** The multi-OAuth scheme rests on
   Claude Code's SHA-256-of-`CLAUDE_CONFIG_DIR` Keychain keying. If Anthropic
   changes it, isolation breaks. *Mitigation:* a startup health probe that
   verifies two distinct config dirs yield two distinct Keychain entries.
2. **OAuth-billing classification not officially confirmed.** Research strongly
   indicates `/login` credentials = interactive billing, but no doc says so
   explicitly. *Mitigation:* file one Anthropic support question to confirm
   before relying on it past 2026-06-15.
3. **Token-refresh race** (#27933) for two concurrent panes on the *same* oauth
   profile sharing one Keychain entry. Pre-exists today; out of scope to fix.
4. **First-run friction** — a new oauth profile's first session is
   unauthenticated. *Mitigation:* TBD detects the empty config dir and prompts.

## Open questions for follow-up

- Confirm with Anthropic support whether a `/login` credential in a non-default
  `CLAUDE_CONFIG_DIR`, driving an interactive REPL, bills as interactive
  subscription usage after 2026-06-15.
- Decide whether `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` for apiKey profiles ships
  with the redesign or is deferred.

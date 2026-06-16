# Environment Overrides

TBD lets you set arbitrary `KEY=VALUE` environment variables on the **primary agent** sessions it spawns — both `claude` and `codex`. The motivating case is routing a repo's Claude sessions through AWS Bedrock (`CLAUDE_CODE_USE_BEDROCK=1` and friends), but the mechanism is generic: any environment variable a spawned agent needs can be set without a code change.

Overrides apply **only** to the spawned primary agent terminal. Plain shell terminals and `setup`/`preSession` hook terminals do **not** receive them.

## Scopes

Overrides can be set at three scopes, each edited in a different place in the app:

| Scope       | What it covers                              | Where it's edited                                  |
| ----------- | ------------------------------------------- | -------------------------------------------------- |
| **Global**  | Every spawned session, in every repo        | Settings → General → "Environment overrides"       |
| **Repo**    | Every session in one repository             | The per-repository settings pane                   |
| **Profile** | Every session using one model profile       | The model-profile edit sheets                      |

Each scope holds a free-form `[String: String]` map. The per-profile bag follows whatever profile the worktree actually resolves (repo override → global default → none), so per-profile env automatically tracks the worktree's effective profile.

## Precedence

Scopes are merged into one map with **`global < repo < profile`** — a more specific scope wins collisions, and non-colliding keys from every scope are unioned in. So a key set globally is overridden by the same key set on the repo, which is in turn overridden by the same key set on the profile.

```
// EnvOverrideResolver.merge(global:repo:profile:) -> [String: String]
var merged = global ?? [:]
merged.merge(repo ?? [:])     { _, new in new }   // repo overrides global
merged.merge(profile ?? [:])  { _, new in new }   // profile overrides both
return merged                                      // global < repo < profile
```

## Auth/routing is final

For Claude sessions, the model profile's **structured auth/routing env is layered on top of the merged free-form result and cannot be overridden by a free-form var.** This is the env the Claude spawn builder emits from the resolved profile:

- the OAuth `CLAUDE_CONFIG_DIR`,
- the Bedrock `CLAUDE_CODE_USE_BEDROCK` / `AWS_REGION` / `AWS_PROFILE`,
- `ANTHROPIC_MODEL` / `ANTHROPIC_BASE_URL`.

The merge order is:

```
merged = global ∪ repo ∪ profile-freeform
final  = merged ∪ builderAuthRouting        // auth/routing is final
```

A free-form var can set anything the builder does **not** already set, but it cannot clobber a key the builder owns. This keeps a stray free-form override from silently breaking model connectivity. (Codex does not get structured Claude routing env — its auth stays via `CODEX_HOME` — so for Codex the merged free-form map is the entirety of the injected env.)

## Values are free-form

The map is a plain `[String: String]`. There is **no** name validation, **no** denylist, **no** registry of allowed keys, and **no** secret handling. Whatever you type is what the session gets.

> **Secrets:** override values are persisted as plain text in TBD's SQLite database (`~/tbd/state.db`), exactly like the rest of TBD's config. There is no encryption or redaction. Treat secret values accordingly.

## Lifecycle

Overrides are read fresh at spawn time, so they survive every path that respawns the primary agent: resume, reboot recovery, manual create, recreate-window, and a mid-conversation profile swap. Change an override and the next spawned (or respawned) session picks it up; already-running sessions keep the env they were spawned with.

## Worked example: Bedrock

The Bedrock launcher's env is split across two systems:

- A **Bedrock model profile** already supplies the structured auth/routing fields — `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION` (from the profile's region), `AWS_PROFILE`, and the `ANTHROPIC_MODEL` / per-tier model IDs (from the profile's `model` / `fallbackModels`). These are emitted by the Claude spawn builder and are final.
- **Free-form env overrides** cover whatever the structured fields don't — for example an `AWS_PROFILE` you'd rather pin per-repo, an `AWS_SESSION_TOKEN`, a custom `BEDROCK_*` tuning var, or a proxy setting.

Because auth/routing is final, a free-form `AWS_REGION` set on the repo will **not** override the region baked into the Bedrock profile — the profile wins. Use the profile's own region field for that.

## Storage

Each scope persists its map as a JSON-encoded `[String: String]` in a nullable `env_overrides` TEXT column, added by migration `v31_env_overrides`:

- `config.env_overrides` — global scope
- `repo.env_overrides` — per-repo scope
- `model_profiles.env_overrides` — per-profile scope

An empty map clears the column back to `NULL`; a missing or corrupt value decodes to "no overrides", so old rows keep working.

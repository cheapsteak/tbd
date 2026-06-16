# Free-form environment overrides for spawned sessions

**Date:** 2026-06-16
**Status:** Approved design, ready for implementation plan

## Problem

TBD spawns `claude` and `codex` sessions but gives the user no way to set arbitrary
environment variables on them. The motivating case: routing a specific repo's Claude
sessions through AWS Bedrock by setting `CLAUDE_CODE_USE_BEDROCK=1` (and friends). We
want a generic mechanism — not a one-off Bedrock switch — so any future
`KEY=VALUE` need is covered without code changes.

### What already exists (and why it's not enough)

- `Config.envSettingOverrides: [String: ClaudeEnvValue]` (`Sources/TBDShared/Models.swift:395`)
  is a **global-only, registry-gated, typed** map persisted in the `config.claude_env_settings`
  JSON column (migration `v26`). Only keys present in `ClaudeEnvRegistry.all` are allowed;
  today that registry has exactly one entry (`fullscreenRendering → CLAUDE_CODE_NO_FLICKER`).
  It is Claude-only and flows through `ClaudeSpawnCommandBuilder.build(envSettingOverrides:)`.
- `ModelProfile` (`Models.swift:274`) already has `kind: .bedrock` with `awsRegion` / `awsProfile`
  / `model` / `fallbackModels`, and the Claude builder emits structured auth/routing env from it.
  This covers *part* of the Bedrock launcher's env (`AWS_REGION`, `ANTHROPIC_MODEL`, the per-tier
  `ANTHROPIC_DEFAULT_*_MODEL` IDs map onto `fallbackModels`/`model`) but leaves no home for the rest.

This design adds a **separate, free-form** layer rather than extending or replacing the typed
registry — to avoid entangling the two systems.

## Decisions (locked)

1. **Shape:** pure free-form `KEY=VALUE` (`[String: String]`). No name validation, no denylist,
   no secret flag, no preview, no registry repurposing — explicitly out of scope.
2. **Scopes:** global, repo, model-profile.
3. **Precedence:** `global < repo < profile` — a more specific scope wins collisions (union merge).
4. **Auth tier is final:** the Claude builder's structured auth/routing output (OAuth token,
   Bedrock `AWS_REGION`/`ANTHROPIC_*`) is applied **last** and is **not** overridable by free-form
   vars, so a stray free-form var can't silently break model connectivity.
5. **Both agents:** applies to spawned Claude **and** Codex primary sessions.

## Architecture

### 1. Data model — a new free-form bag, parallel to the typed one

Add `envOverrides: [String: String]?` at three scopes. The existing typed
`envSettingOverrides` / `ClaudeEnvRegistry` is left untouched.

| Scope   | Shared model field (`Models.swift`)      | DB column                       |
|---------|------------------------------------------|---------------------------------|
| Global  | `Config.envOverrides` (`:395`)           | `config.env_overrides`          |
| Repo    | `Repo.envOverrides` (`:8`)               | `repo.env_overrides`            |
| Profile | `ModelProfile.envOverrides` (`:274`)     | `model_profiles.env_overrides`  |

Each is a nullable `TEXT` column holding JSON-encoded `[String: String]`, mirroring exactly how
`claude_env_settings` was added in `v26`. New model fields are optional (per the CLAUDE.md DB rule),
so existing rows/JSON still decode.

**Migration `v31_env_overrides`** adds the `env_overrides TEXT` column to all three tables in one
migration (via `addColumnIfMissing`). Per the CLAUDE.md migration rule, the same commit updates:
the migration, the GRDB records (`ConfigRecord`, `RepoRecord`, `ModelProfileRecord`), and the three
shared models.

### 2. Resolution — one pure, testable function

A pure resolver returns the merged map:

```swift
// EnvOverrideResolver.merge(global:repo:profile:) -> [String: String]
var merged = global ?? [:]
merged.merge(repo ?? [:])     { _, new in new }   // repo overrides global
merged.merge(profile ?? [:])  { _, new in new }   // profile overrides both
return merged                                      // global < repo < profile
```

The `profile` argument is the env bag of whatever profile `ModelProfileResolver` already resolves
for the worktree (repo override → global default → none), so per-profile env automatically follows
the worktree's effective profile. This function is the unit-test seam for the precedence rule.

### 3. Injection — single chokepoint, both agents

Merge in `WorktreeLifecycle+Create.swift` where `primarySensitiveEnv` is assembled
(~`:464` for Codex, ~`:510` for Claude) — the one place both agents converge — **not** inside the
Claude builder.

- **Claude:** layer the merged free-form env into `primarySensitiveEnv`, then apply the Claude
  builder's structured auth/routing output **on top** so auth wins:
  ```
  merged   = global ∪ repo ∪ profile-freeform
  final    = merged ∪ builderAuthRouting        // auth/routing is final
  ```
- **Codex:** `primarySensitiveEnv` is `[:]` today (`:464`); set it to the merged free-form map.
  That is the entirety of Codex's new env support. (Codex auth stays via `CODEX_HOME`; Codex does
  not get structured Claude routing env.)

Both paths flow unchanged through `TmuxManager.newWindowCommand`'s `-e KEY=VALUE` injection (`:114`).

### 4. UI — one reusable editor, three mount points

A reusable `EnvOverridesEditor` SwiftUI view (KEY/VALUE rows with add/remove), modeled on the
existing `FallbackModelsEditor` (`ModelProfilesSettingsView.swift:244`). Mounted in:

- **Global:** a new section in `GeneralSettingsTab` (`SettingsView.swift`).
- **Repo:** a section in the per-repo settings area (alongside `RepoHooksSettingsView`), but
  persisted via **RPC** (it is a DB field, unlike the file-based hooks).
- **Profile:** inside the profile edit sheets (`ModelProfilesSettingsView`).

Three new void RPC methods following the existing `callVoidAsync` pattern:
`configSetEnvOverrides`, `repoSetEnvOverrides`, `modelProfileSetEnvOverrides` — each with a
param struct in `RPCProtocol.swift`, a handler, a `DaemonClient` method, and an `AppState` action.

### 5. Docs & tests

- **Docs:** new `docs/env-overrides.md` documenting the scopes, the `global < repo < profile`
  precedence, the auth-tier-is-final rule, that values are free-form, and that they apply to both
  Claude and Codex primary sessions. Link it from the `tbd-project` skill's conventions.
- **Tests:**
  - Unit-test `EnvOverrideResolver.merge`: union; profile wins collisions; nil/empty scopes; that
    auth/routing is not overridden (layer ordering).
  - Per the CLAUDE.md branch-test rule: Codex now receives the merged env (new branch), and an empty
    config injects nothing for either agent.

## Scope boundaries (YAGNI)

Out of scope: per-worktree scope, env-name validation/denylist, secret marking, merge preview,
any change to the typed `ClaudeEnvRegistry`. Applies only to the spawned **primary agent** session
(Claude/Codex), not secondary shell terminals.

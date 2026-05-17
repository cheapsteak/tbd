# Bedrock credential kind for model profiles

**Date:** 2026-05-16
**Status:** Design

## Problem

`tbd` models a Claude session profile as `{ name, kind: oauth | apiKey, baseURL?, model? }`
plus a secret in Keychain. Spawning exports `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` (and optionally `ANTHROPIC_BASE_URL` / `ANTHROPIC_MODEL`).

That shape doesn't fit AWS Bedrock. Bedrock auth is the AWS SDK's job
(`CLAUDE_CODE_USE_BEDROCK=1` + the SDK credential chain), not a token TBD stores.
A third profile kind — `bedrock` — is the right abstraction so a user can switch
to Bedrock as a failover when `api.anthropic.com` is down (or use it day-to-day)
with one click in Settings.

## Goal

After this change: open Settings → Model Profiles → "Add Bedrock profile", give
it a name + AWS region + optional AWS profile name + Bedrock model id, and
spawning a Claude session against that profile uses Bedrock with no extra setup.
No proxy process.

## Out of scope

- Vertex AI / GCP profiles. (Same shape, different env vars. Code should leave
  a clean seam but not build it.)
- Per-region usage / spend tracking for Bedrock.
- Detecting Anthropic outages and auto-switching profiles.

## Data model changes

### `CredentialKind` (TBDShared/Models.swift)

```swift
public enum CredentialKind: String, Codable, Sendable {
    case oauth
    case apiKey
    case bedrock   // NEW — no Keychain secret; AWS SDK handles auth
}
```

### `ModelProfile` (TBDShared/Models.swift)

Two new optional fields, both `String?` so older clients that omit them decode
cleanly:

```swift
public struct ModelProfile: ... {
    public let id: UUID
    public var name: String
    public var kind: CredentialKind
    public var baseURL: String?
    public var model: String?
    public var awsRegion: String?    // NEW — required when kind == .bedrock
    public var awsProfile: String?   // NEW — optional even for bedrock (nil = SDK default chain)
    public var createdAt: Date
    public var lastUsedAt: Date?
}
```

Add to `CodingKeys`, the memberwise init, and the explicit `init(from:)` (using
`decodeIfPresent` for both).

### Shared display interface (TBDShared/Models.swift)

Five sites currently format profile display strings inline:
`RepoDetailView`, `SettingsView`, `ModelProfilesSettingsView`, `TabBar`, and
`MenuBar/ModelProfileMenu`. Adding Bedrock would plant a sixth. Consolidate
with a single extension:

```swift
extension ModelProfile {
    /// Short capsule label for the kind badge.
    /// "OAuth" | "API key" | "Proxy" | "Bedrock"
    public var kindLabel: String {
        switch kind {
        case .oauth:   return "OAuth"
        case .apiKey:  return baseURL != nil ? "Proxy" : "API key"
        case .bedrock: return "Bedrock"
        }
    }

    /// Secondary detail line. `nil` when there's nothing useful beyond the
    /// kind badge (plain claude-direct OAuth / api-key).
    /// Proxy:   "via http://127.0.0.1:3456 · gpt-5"
    /// Bedrock: "us-west-2 · anthropic.claude-sonnet-4-5-20250929-v1:0"
    public var detailCaption: String? {
        switch kind {
        case .oauth, .apiKey:
            guard let baseURL else { return nil }
            if let model, !model.isEmpty { return "via \(baseURL) · \(model)" }
            return "via \(baseURL)"
        case .bedrock:
            let region = awsRegion ?? "?"
            if let model, !model.isEmpty { return "\(region) · \(model)" }
            return region
        }
    }

    /// What goes in a tab title, menu item, or anywhere we render the profile
    /// as a single line. Just `name` today, but routed through a single seam
    /// so any future "name · region" change lands in one place.
    public var tabDisplayName: String { name }
}
```

Migrate the five existing call sites to use these. After this change, no view
constructs profile-display strings inline.

**Important — `tabDisplayName` is an *input* to existing formatters, not a
drop-in replacement for them.** `TabBar.swift:587-609` has per-profile
ordinal disambiguation (when multiple tabs share the same profile, suffixes
"_2", "_3", … are appended). That whole block stays; only the bare
`entry.profile.name` on line 595 becomes `entry.profile.tabDisplayName`. Same
pattern applies anywhere the existing view does more than just render the name
literally — substitute the input, don't rewrite the surrounding logic.

Note: `kindLabel` returns "Proxy" (not "API key") for the proxy case. Today's
badge calls it "API key" — this is an intentional UI correction, not a
back-compat break.

## Database migration

### `v25_model_profiles_bedrock` (TBDDaemon/Database/Database.swift)

`v25` is the next sequential migration ID — the current head is `v24_drop_conductor`.

```swift
migrator.registerMigration("v25_model_profiles_bedrock") { db in
    try db.addColumnIfMissing(table: "model_profiles", column: "aws_region",  type: .text)
    try db.addColumnIfMissing(table: "model_profiles", column: "aws_profile", type: .text)
}
```

- Additive only; both columns nullable. Existing oauth/apiKey rows keep
  `aws_region = NULL`, `aws_profile = NULL`.
- Uses `addColumnIfMissing` per the `Database/CLAUDE.md` migration discipline so
  parallel-branch ID collisions become logged no-ops.
- `model_profiles.keychain_ref` stays `TEXT NOT NULL`. Bedrock rows keep the
  existing `ModelProfileRecord.init(from:)` default (write `profile.id.uuidString`
  into the column), and we just never read from Keychain for that kind. No need
  to relax the NOT NULL constraint.

### Multiple bedrock profiles

The only uniqueness constraint is `name`. A user can create as many bedrock
rows as they want, each with a different `(awsRegion, awsProfile, model)` tuple
— same as how multiple proxy profiles already work.

## Daemon changes

### `ModelProfileRecord` (TBDDaemon/Database/ModelProfileRecord.swift)

Wire the two new columns through:

```swift
struct ModelProfileRecord: ... {
    var aws_region: String?
    var aws_profile: String?

    init(from profile: ModelProfile) {
        // existing assignments …
        self.aws_region  = profile.awsRegion
        self.aws_profile = profile.awsProfile
    }

    func toModel() -> ModelProfile {
        ModelProfile(
            // existing fields …
            awsRegion: aws_region,
            awsProfile: aws_profile,
            // …
        )
    }
}
```

Extend `ModelProfileStore.create`:

```swift
public func create(name: String, kind: CredentialKind,
                   baseURL: String? = nil, model: String? = nil,
                   awsRegion: String? = nil, awsProfile: String? = nil
) async throws -> ModelProfile
```

A new `ModelProfileStore.updateBedrock(id:awsRegion:awsProfile:model:)` method handles in-place edits via the `modelProfile.updateBedrock` RPC.

### `ResolvedModelProfile` (TBDDaemon/ModelProfile/ModelProfileResolver.swift)

Two changes:

1. `secret` becomes optional (`nil` for bedrock rows — no Keychain entry).
2. Two new fields pass AWS routing through to the spawn builder.

```swift
public struct ResolvedModelProfile: Sendable, Equatable {
    public let profileID: UUID
    public let name: String
    public let kind: CredentialKind
    public let baseURL: String?
    public let model: String?
    public let secret: String?         // CHANGED: optional, nil for bedrock
    public let awsRegion: String?      // NEW
    public let awsProfile: String?     // NEW
}
```

`loadResolved` skips the Keychain load for `.bedrock`:

```swift
let secret: String?
if row.kind == .bedrock {
    secret = nil
} else {
    guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
    secret = s
}
```

The 9 existing `ClaudeSpawnCommandBuilder.build` call sites that pass
`resolvedProfile?.secret` continue to compile — the parameter is already
`String?`. Of those 9, **7 are Claude-profile spawn paths** and get the new
AWS params plumbed through (`profileAwsRegion:`, `profileAwsProfile:`); the
**2 in `WorktreeLifecycle+Reconcile.swift:293-314` are shell/codex fallback
branches** that already pass `profileSecret: nil` and stay nil for the new
params too — they never set `profileKind: .bedrock`, so the bedrock branch in
the builder cannot fire for non-Claude windows.

### `ClaudeProfileConfigDirManager` (TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift)

`resolveConfigDir` at line ~100 currently calls
`ensureDir(forProfileID: profile.profileID, apiKey: profile.secret)`, which
takes a non-optional `apiKey: String`. With `secret` now optional, this
won't compile. Guard the call:

```swift
guard let apiKey = profile.secret else {
    // Bedrock (and any future kind without a Keychain secret) doesn't need
    // an isolated ANTHROPIC_CONFIG_DIR — we're not setting ANTHROPIC_API_KEY
    // at all, so the "Auth conflict" warning this isolation defends against
    // can't fire.
    return nil
}
try ensureDir(forProfileID: profile.profileID, apiKey: apiKey)
```

This makes the config-dir setup OAuth/api-key/proxy-only, which is the
correct semantic — there's no API-key collision to defend against for
bedrock profiles.

### `ClaudeSpawnCommandBuilder.build` (TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift)

Add two new optional params:

```swift
static func build(
    // … existing params …
    profileSecret: String?,
    profileKind: CredentialKind? = nil,
    profileBaseURL: String? = nil,
    profileModel: String? = nil,
    profileAwsRegion: String? = nil,   // NEW
    profileAwsProfile: String? = nil,  // NEW
    profileConfigDir: String? = nil,
    // … rest …
) -> Result
```

Replace the env-building block (today's lines 91–110) with a branch on
`profileKind`:

```swift
var env: [String: String] = [:]
if profileKind == .bedrock {
    env["CLAUDE_CODE_USE_BEDROCK"] = "1"
    if let r = profileAwsRegion  { env["AWS_REGION"]  = r }
    if let p = profileAwsProfile { env["AWS_PROFILE"] = p }
    if let m = profileModel      { env["ANTHROPIC_MODEL"] = m }
    // intentionally no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN
    // / ANTHROPIC_BASE_URL / ANTHROPIC_CONFIG_DIR
} else {
    if let secret = profileSecret {
        let envVar = profileKind == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
        env[envVar] = secret
    }
    if let baseURL = profileBaseURL { env["ANTHROPIC_BASE_URL"] = baseURL }
    if let model   = profileModel   { env["ANTHROPIC_MODEL"]    = model }
    if let configDir = profileConfigDir, profileBaseURL != nil {
        env["ANTHROPIC_CONFIG_DIR"] = configDir
    }
}
return Result(command: base, sensitiveEnv: env)
```

All 9 existing call sites also pass the new params (via
`resolvedProfile?.awsRegion`, `resolvedProfile?.awsProfile`).

### RPC params shape (TBDShared/RPCProtocol.swift)

One params struct with an explicit `kind` discriminator. Optional for
back-compat with older CLIs that omit it (the handler infers exactly as today
when nil).

```swift
public enum ModelProfileAddKind: String, Codable, Sendable {
    case claudeDirect    // existing OAuth / api-key path; uses `token`
    case proxy           // existing proxy path; uses `token` + `baseURL`
    case bedrock         // NEW; uses `awsRegion` + optional `awsProfile`; no token
}

public struct ModelProfileAddParams: Codable, Sendable {
    public let kind: ModelProfileAddKind?   // nil = infer (back-compat)
    public let name: String
    public let token: String?               // CHANGED: optional; required for non-bedrock
    public let baseURL: String?
    public let model: String?
    public let awsRegion: String?           // NEW
    public let awsProfile: String?          // NEW
}
```

The `token: String` → `String?` shift is the only back-compat-affecting change.
Older daemon → newer app: the daemon will reject a `token = nil` for a kind
that needs one, which is the correct outcome. Older app → newer daemon: still
sends `token` as a JSON string field, which decodes fine.

### `handleModelProfileAdd` (TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift)

Branch on the new `kind`:

- **bedrock branch**
  - Trim whitespace from `name`, `awsRegion`, `awsProfile`, `model`.
  - Validate: trimmed `name` non-empty (existing); trimmed `awsRegion` non-empty;
    trimmed `model` non-empty.
  - Normalize: if trimmed `awsProfile` is empty, store as `nil` (so the spawn
    builder's `if let p = profileAwsProfile` correctly omits `AWS_PROFILE`
    rather than injecting an empty value).
  - No format validation on `awsRegion` (e.g. no `us-west-2` regex) — AWS SDK
    rejects malformed regions at first request, and over-validating now blocks
    legitimate region names we haven't enumerated.
  - Reject if a profile with that name already exists (existing check).
  - Skip token validation, skip Keychain write, skip the Anthropic usage probe.
  - `db.modelProfiles.create(..., kind: .bedrock, awsRegion:, awsProfile:, model:)`.
  - Broadcast `.modelProfilesChanged`; return `ModelProfileAddResult(profile:, warning: nil)`.

- **claudeDirect / proxy / nil-inferred branches** — unchanged behavior.

### `handleModelProfileFetchUsage`

Extend the existing proxy-rejection guard to also reject bedrock:

```swift
if profile.baseURL != nil || profile.kind == .bedrock {
    return RPCResponse(error: "Usage tracking is only available for Claude-direct profiles")
}
```

This is what stops the OAuth-only `api.anthropic.com` poll from running against
bedrock rows. Polling stays OAuth-only; bedrock just shows `lastStatus = nil`.

### `handleModelProfileDelete`

No code change. The existing path already wraps the Keychain delete in
`do/catch` + logger warning (lines 151–155), so a missing Keychain entry for a
bedrock profile turns into a logged warning, not an RPC error.

## App changes

### `AppState.addModelProfile` (TBDApp/AppState+ModelProfiles.swift)

Add the new params and forward through `daemonClient.addModelProfile`:

```swift
@discardableResult
func addModelProfile(name: String,
                     kind: ModelProfileAddKind,
                     token: String? = nil,
                     baseURL: String? = nil,
                     model: String? = nil,
                     awsRegion: String? = nil,
                     awsProfile: String? = nil) async -> String?
```

`DaemonClient.addModelProfile` gets the same shape.

### Add sheet (TBDApp/Settings/ModelProfilesSettingsView.swift)

Add a third option to the existing segmented picker:

```swift
private enum AddPreset: String, CaseIterable, Identifiable {
    case claudeDirect = "Claude (direct)"
    case proxy        = "Anthropic-compatible proxy"
    case bedrock      = "AWS Bedrock"
    var id: String { rawValue }
}
```

When `.bedrock` is selected, the form shows:

- **Name** (required) — same field as today.
- **Region** (required) — `TextField`, placeholder `us-west-2`.
- **AWS profile** (optional) — `TextField`, placeholder `default`. Caption:
  "Leave blank to use the AWS SDK default chain — env vars, SSO, instance role."
- **Model** (required) — `TextField`, placeholder
  `anthropic.claude-sonnet-4-5-20250929-v1:0`. Caption: "Bedrock model ID or
  cross-region inference profile ID (e.g. `us.anthropic.…`)."

Hide the Token + Base URL fields and the health-probe section — there's no
endpoint for TBD to probe; AWS SDK validation happens at first request.

`canSave` for bedrock requires non-empty trimmed name, region, and model.

### Existing row (`ModelProfileRow`)

Switch the binary kind badge to use the new `profile.kindLabel`. Switch
`endpointCaption` to use `profile.detailCaption`. Bedrock rows then render with
"Bedrock" badge + `"us-west-2 · anthropic.claude-sonnet-4-5-…"` caption with
zero additional code.

Hide the "Edit endpoint" button when `profile.kind == .bedrock` (no
`EditBedrockSheet` in this scope).

### Other display sites

Migrate to the shared interface:

- `RepoDetailView.swift:89-93` → use `profile.kindLabel` / `profile.detailCaption`.
- `SettingsView.swift:242-246` → same.
- `TabBar.swift:595` → use `profile.tabDisplayName` (input only; preserve the
  surrounding ordinal-disambiguation block).
- Picker labels in `ModelProfilesSettingsView.swift:36` and
  `MenuBar/ModelProfileMenu.swift:70` → use `profile.tabDisplayName`.

### Running-terminal warnings — intentionally untouched

`TerminalPanelView.swift:97-118` shows a "Proxy unreachable" badge on running
terminals whose profile has `baseURL != nil`. Bedrock profiles have nil
`baseURL`, so this badge correctly never fires for them — but document the
contract: **running-terminal warnings stay proxy-specific in this design.** No
"Bedrock unreachable" probe gets added; AWS errors surface in the Claude
session output, not in a TBD-rendered badge. Health probing for AWS would
require credentials TBD doesn't have (the whole point of leaving auth to the
SDK chain), so this is a deliberate non-feature.

## Verification

- `swift build` passes.
- `swift test` passes — relevant tests: `ClaudeSpawnCommandBuilder` env-var
  shape (new bedrock case + existing cases unchanged), `ModelProfileResolver`
  with bedrock + missing-Keychain happy path, migration `v25` round-trips.
- Add a Bedrock profile in Settings; restart daemon (`scripts/restart.sh`);
  confirm it persists.
- Spawn a Claude session against the bedrock profile and run `env | grep -E
  'ANTHROPIC|AWS|CLAUDE_CODE'` inside it. Expected exact set:
  - `CLAUDE_CODE_USE_BEDROCK=1`
  - `AWS_REGION=<region>`
  - `AWS_PROFILE=<profile>` (only when set)
  - `ANTHROPIC_MODEL=<model>`
  - Nothing else from the `ANTHROPIC_*` or `CLAUDE_CODE_*` families.
- Run a real Claude turn end-to-end against Bedrock; confirm via tcpdump or
  AWS console that traffic hits `bedrock-runtime.<region>.amazonaws.com`, not
  `api.anthropic.com`.
- Delete a bedrock profile; confirm the daemon logs a single
  `"Failed to delete secret file"` warning (no Keychain entry to delete) and
  the RPC returns success.
- Create a second bedrock profile with a different region; confirm both
  coexist and can be selected independently.

## Accepted risks (called out, not mitigated)

A pre-implementation Codex review flagged three concerns that this design
intentionally does not defend against. Documented here so future readers
understand they were considered.

### Mixed-version daemon/app decode

Adding `"bedrock"` as a `CredentialKind` raw value means an older app
binary reading a newer daemon's `modelProfile.list` response will fail
`CredentialKind.decode` if any bedrock row exists, and `ModelProfileAddParams.token`
becoming optional means an older daemon receiving a newer app's bedrock-add
payload (with `token: null`) will fail to decode the request.

**Why we accept it:** `Sources/TBDShared/CLAUDE.md` and
`Sources/TBDDaemon/CLAUDE.md` both mandate `scripts/restart.sh` (full restart)
after any shared-code change, and the project has a single end user running
exactly one paired daemon+app build at a time. The mixed-version window
doesn't exist in practice. Adding tolerant-decode fallbacks (`CredentialKind(rawValue:) ?? .apiKey`,
optional token treated as empty) would silently degrade rather than fail
loudly, which is worse for a tool with one operator.

### Bedrock env-var surface is intentionally minimal

Claude Code documents additional Bedrock env vars beyond what this design
emits: `ANTHROPIC_BEDROCK_BASE_URL`, `AWS_BEARER_TOKEN_BEDROCK`,
`ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION`, and
direct `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`
overrides.

**Why we accept it:** the explicit goal is failover via the AWS SDK default
credential chain plus a region + model pin. Direct AWS credential
injection collides with the "let the SDK chain handle auth" premise.
Haiku/small-model overrides and a custom Bedrock endpoint URL are valid
configurations but expand scope beyond v1. Adding them later is a column-add
plus a few env-injection lines — the spawn-builder branch is the seam.

## Design seams left for later

- Vertex AI: the spawn-builder branch on `profileKind` is the natural insertion
  point. A future `.vertex` case adds `vertexProjectID` / `vertexRegion` columns
  and a third arm of the env switch.
- Bedrock profile editing: re-use `EditEndpointSheet`'s pattern with an
  `EditBedrockSheet`.
- Bedrock cost tracking: a separate feature; not coupled to this design.

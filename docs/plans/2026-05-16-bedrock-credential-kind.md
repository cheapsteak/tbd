# Bedrock Credential Kind — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `bedrock` model-profile kind so `tbd` can spawn Claude sessions that route to AWS Bedrock via the SDK credential chain — no Keychain secret, no proxy process.

**Architecture:** Add `.bedrock` to `CredentialKind`; add two nullable columns (`aws_region`, `aws_profile`) to `model_profiles` via migration `v25`; route through `ResolvedModelProfile` (now with `secret: String?`) into `ClaudeSpawnCommandBuilder`, which branches on `profileKind == .bedrock` to emit `CLAUDE_CODE_USE_BEDROCK=1` + `AWS_REGION` + optional `AWS_PROFILE` + `ANTHROPIC_MODEL`. RPC `modelProfile.add` gains a `kind` discriminator; the bedrock add path skips token validation, Keychain write, and the Anthropic usage probe. Consolidate five duplicated profile-display formatters behind a single `ModelProfile` extension before adding the new kind.

**Tech Stack:** Swift 5.x, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), GRDB (SQLite), SwiftUI. Build: `swift build`. Test: `swift test`. Restart for end-to-end: `scripts/restart.sh`.

**Reference spec:** `docs/specs/2026-05-16-bedrock-credential-kind-design.md`

---

## File Map

**Modify (TBDShared):**
- `Sources/TBDShared/Models.swift` — `CredentialKind` enum, `ModelProfile` struct, new display extension
- `Sources/TBDShared/RPCProtocol.swift` — `ModelProfileAddParams` (new fields + kind discriminator)

**Modify (TBDDaemon):**
- `Sources/TBDDaemon/Database/Database.swift` — register migration `v25_model_profiles_bedrock`
- `Sources/TBDDaemon/Database/ModelProfileRecord.swift` — wire `aws_region`/`aws_profile` through record + store
- `Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift` — `secret: String?`, add AWS fields, skip Keychain for bedrock
- `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift` — guard optional secret
- `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift` — bedrock branch + new params
- 7 Claude-profile call sites of `ClaudeSpawnCommandBuilder.build` — plumb new params
- `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift` — bedrock branch in `handleModelProfileAdd`, reject bedrock in `handleModelProfileFetchUsage`

**Modify (TBDApp):**
- `Sources/TBDApp/DaemonClient.swift` — `addModelProfile` signature
- `Sources/TBDApp/AppState+ModelProfiles.swift` — forward new params
- `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift` — new `.bedrock` `AddPreset`, conditional fields, hide Edit Endpoint button for bedrock
- 5 display sites — migrate to shared `kindLabel` / `detailCaption` / `tabDisplayName`:
  - `Sources/TBDApp/RepoDetailView.swift:89-93`
  - `Sources/TBDApp/Settings/SettingsView.swift:242-246`
  - `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift:112-118` + `:144-151`
  - `Sources/TBDApp/TabBar.swift:595` (input only — preserve ordinal block)
  - `Sources/TBDApp/MenuBar/ModelProfileMenu.swift:70`

**Extend (Tests):**
- `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift` — bedrock env-var contract
- `Tests/TBDDaemonTests/ModelProfileMigrationTests.swift` — v25 schema assertions
- `Tests/TBDDaemonTests/ModelProfileStoreTests.swift` — round-trip bedrock fields
- `Tests/TBDDaemonTests/ModelProfileRPCTests.swift` — bedrock add path + usage rejection
- `Tests/TBDDaemonTests/ModelProfileSpawnTests.swift` — resolver returns bedrock with nil secret
- `Tests/TBDSharedTests/` (create if needed) or co-located — `ModelProfile` display extension

---

## Task 1: Data model — `CredentialKind.bedrock` + `ModelProfile` fields + display extension

**Files:**
- Modify: `Sources/TBDShared/Models.swift`
- Test: `Tests/TBDSharedTests/ModelProfileDisplayTests.swift` (create new file)

The display extension is added in this task even though `.bedrock` isn't routable yet — it's pure data-shape work and unblocks UI migration later. Three test cases keep it honest.

- [ ] **Step 1: Verify TBDSharedTests target exists; if not, check Package.swift**

```bash
grep -n "TBDSharedTests" Package.swift || echo "MISSING — co-locate tests in TBDDaemonTests instead"
```

If missing, add the test to `Tests/TBDDaemonTests/ModelProfileDisplayTests.swift` (TBDDaemon already imports TBDShared, so the extension is reachable). Adjust file paths below accordingly.

- [ ] **Step 2: Write failing tests for the display extension**

Create the test file with three suites — `kindLabel`, `detailCaption`, `tabDisplayName`:

```swift
import Foundation
import Testing
@testable import TBDShared

@Suite("ModelProfile display")
struct ModelProfileDisplayTests {

    @Test("kindLabel: oauth → OAuth")
    func kindLabelOAuth() {
        let p = ModelProfile(name: "x", kind: .oauth)
        #expect(p.kindLabel == "OAuth")
    }

    @Test("kindLabel: apiKey without baseURL → API key")
    func kindLabelApiKeyDirect() {
        let p = ModelProfile(name: "x", kind: .apiKey)
        #expect(p.kindLabel == "API key")
    }

    @Test("kindLabel: apiKey with baseURL → Proxy")
    func kindLabelProxy() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://localhost:3456")
        #expect(p.kindLabel == "Proxy")
    }

    @Test("kindLabel: bedrock → Bedrock")
    func kindLabelBedrock() {
        let p = ModelProfile(name: "x", kind: .bedrock, awsRegion: "us-west-2", model: "anthropic.claude-sonnet-4-5")
        #expect(p.kindLabel == "Bedrock")
    }

    @Test("detailCaption: oauth → nil")
    func detailOAuthNil() {
        let p = ModelProfile(name: "x", kind: .oauth)
        #expect(p.detailCaption == nil)
    }

    @Test("detailCaption: direct apiKey → nil")
    func detailDirectApiKeyNil() {
        let p = ModelProfile(name: "x", kind: .apiKey)
        #expect(p.detailCaption == nil)
    }

    @Test("detailCaption: proxy with model → via URL · model")
    func detailProxyWithModel() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://h:1", model: "gpt-5")
        #expect(p.detailCaption == "via http://h:1 · gpt-5")
    }

    @Test("detailCaption: proxy without model → via URL")
    func detailProxyNoModel() {
        let p = ModelProfile(name: "x", kind: .apiKey, baseURL: "http://h:1", model: nil)
        #expect(p.detailCaption == "via http://h:1")
    }

    @Test("detailCaption: bedrock with model → region · model")
    func detailBedrockWithModel() {
        let p = ModelProfile(name: "x", kind: .bedrock,
                             awsRegion: "us-west-2",
                             model: "anthropic.claude-sonnet-4-5")
        #expect(p.detailCaption == "us-west-2 · anthropic.claude-sonnet-4-5")
    }

    @Test("detailCaption: bedrock without model → region only")
    func detailBedrockNoModel() {
        let p = ModelProfile(name: "x", kind: .bedrock, awsRegion: "us-west-2", model: nil)
        #expect(p.detailCaption == "us-west-2")
    }

    @Test("detailCaption: bedrock missing region → ? · model")
    func detailBedrockNoRegion() {
        let p = ModelProfile(name: "x", kind: .bedrock,
                             awsRegion: nil,
                             model: "anthropic.claude-sonnet-4-5")
        #expect(p.detailCaption == "? · anthropic.claude-sonnet-4-5")
    }

    @Test("tabDisplayName returns name verbatim")
    func tabDisplayName() {
        let p = ModelProfile(name: "Bedrock prod", kind: .bedrock,
                             awsRegion: "us-west-2", model: "anthropic.claude-sonnet-4-5")
        #expect(p.tabDisplayName == "Bedrock prod")
    }
}
```

- [ ] **Step 3: Run tests — expect compile failure**

```bash
swift test --filter ModelProfileDisplayTests 2>&1 | tail -20
```

Expected: build failure (no `.bedrock` case, no `awsRegion`/`awsProfile` fields, no display extension).

- [ ] **Step 4: Update `CredentialKind` enum**

In `Sources/TBDShared/Models.swift`, change:

```swift
public enum CredentialKind: String, Codable, Sendable {
    case oauth
    case apiKey
}
```

to:

```swift
public enum CredentialKind: String, Codable, Sendable {
    case oauth
    case apiKey
    case bedrock
}
```

- [ ] **Step 5: Add `awsRegion`/`awsProfile` to `ModelProfile`**

In `Sources/TBDShared/Models.swift`, modify the `ModelProfile` struct. Add two fields, extend the init, extend `CodingKeys`, extend the explicit `init(from:)`:

```swift
public struct ModelProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: CredentialKind
    public var baseURL: String?
    public var model: String?
    public var awsRegion: String?
    public var awsProfile: String?
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: CredentialKind,
                baseURL: String? = nil, model: String? = nil,
                awsRegion: String? = nil, awsProfile: String? = nil,
                createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, awsRegion, awsProfile, createdAt, lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(CredentialKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        awsRegion = try c.decodeIfPresent(String.self, forKey: .awsRegion)
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}
```

- [ ] **Step 6: Add the display extension at the end of `Sources/TBDShared/Models.swift`**

```swift
// MARK: - ModelProfile display

extension ModelProfile {
    /// Short capsule label for the kind badge.
    public var kindLabel: String {
        switch kind {
        case .oauth:   return "OAuth"
        case .apiKey:  return baseURL != nil ? "Proxy" : "API key"
        case .bedrock: return "Bedrock"
        }
    }

    /// Secondary detail line. `nil` when there's nothing useful to show
    /// beyond the kind badge (plain claude-direct OAuth / api-key).
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
    /// as a single line. Today just `name`; the seam exists for future
    /// per-kind divergence.
    public var tabDisplayName: String { name }
}
```

- [ ] **Step 7: Run tests — expect PASS**

```bash
swift test --filter ModelProfileDisplayTests 2>&1 | tail -10
```

Expected: all 12 tests pass.

- [ ] **Step 8: Build the whole project — confirm no breakage from new enum case**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build. (If anything breaks with non-exhaustive-switch warnings, fix them — but spec §"Nitpick" notes no exhaustive switches exist today, so this should be clean.)

- [ ] **Step 9: Commit**

```bash
git add Sources/TBDShared/Models.swift Tests/TBDSharedTests/ModelProfileDisplayTests.swift
git commit -m "feat(TBDShared): add .bedrock CredentialKind, AWS fields, display interface

Adds the data shape for bedrock profiles (no behavior yet) plus a single
extension on ModelProfile that consolidates the five inline display
formatters currently scattered across RepoDetailView, SettingsView,
ModelProfilesSettingsView, TabBar, and ModelProfileMenu. Migration of
those sites lands in a later task."
```

---

## Task 2: Database — migration `v25` + `ModelProfileRecord` plumbing

**Files:**
- Modify: `Sources/TBDDaemon/Database/Database.swift`
- Modify: `Sources/TBDDaemon/Database/ModelProfileRecord.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileMigrationTests.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileStoreTests.swift`

- [ ] **Step 1: Write failing migration test**

Add to `Tests/TBDDaemonTests/ModelProfileMigrationTests.swift` inside the existing `@Suite`:

```swift
@Test("v25 adds aws_region and aws_profile columns")
func v25AddsAwsColumns() async throws {
    let db = try TBDDatabase(inMemory: true)
    try await db.writerForTests.read { conn in
        let cols = try Row.fetchAll(conn, sql: "PRAGMA table_info(model_profiles)")
            .map { $0["name"] as String }
        #expect(cols.contains("aws_region"))
        #expect(cols.contains("aws_profile"))
    }
}
```

- [ ] **Step 2: Write failing store round-trip test**

Add to `Tests/TBDDaemonTests/ModelProfileStoreTests.swift`:

```swift
@Test("store: bedrock fields round-trip through create + get")
func bedrockRoundTrip() async throws {
    let db = try TBDDatabase(inMemory: true)
    let p = try await db.modelProfiles.create(
        name: "Bedrock prod",
        kind: .bedrock,
        baseURL: nil,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-west-2",
        awsProfile: "acme-prod"
    )
    let fetched = try await db.modelProfiles.get(id: p.id)
    #expect(fetched?.kind == .bedrock)
    #expect(fetched?.awsRegion == "us-west-2")
    #expect(fetched?.awsProfile == "acme-prod")
    #expect(fetched?.model == "anthropic.claude-sonnet-4-5")
}

@Test("store: bedrock with nil awsProfile stays nil after round-trip")
func bedrockNilAwsProfile() async throws {
    let db = try TBDDatabase(inMemory: true)
    let p = try await db.modelProfiles.create(
        name: "Bedrock minimal",
        kind: .bedrock,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-east-1",
        awsProfile: nil
    )
    let fetched = try await db.modelProfiles.get(id: p.id)
    #expect(fetched?.awsProfile == nil)
}
```

- [ ] **Step 3: Run tests — expect failure**

```bash
swift test --filter "ModelProfileMigration|ModelProfileStore" 2>&1 | tail -20
```

Expected: build failure (missing migration; `create` doesn't accept `awsRegion`/`awsProfile`).

- [ ] **Step 4: Add migration v25 to `Sources/TBDDaemon/Database/Database.swift`**

After the `v24_drop_conductor` block (before the closing `return migrator`), add:

```swift
migrator.registerMigration("v25_model_profiles_bedrock") { db in
    try db.addColumnIfMissing(table: "model_profiles", column: "aws_region",  type: .text)
    try db.addColumnIfMissing(table: "model_profiles", column: "aws_profile", type: .text)
}
```

- [ ] **Step 5: Wire columns through `ModelProfileRecord`**

Edit `Sources/TBDDaemon/Database/ModelProfileRecord.swift`:

Add two fields to the struct:
```swift
struct ModelProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "model_profiles"

    var id: String
    var name: String
    var keychain_ref: String
    var kind: String
    var base_url: String?
    var model: String?
    var aws_region: String?
    var aws_profile: String?
    var created_at: Date
    var last_used_at: Date?
    // …
}
```

Extend `init(from profile:)`:
```swift
init(from profile: ModelProfile) {
    self.id = profile.id.uuidString
    self.name = profile.name
    self.keychain_ref = profile.id.uuidString
    self.kind = profile.kind.rawValue
    self.base_url = profile.baseURL
    self.model = profile.model
    self.aws_region = profile.awsRegion
    self.aws_profile = profile.awsProfile
    self.created_at = profile.createdAt
    self.last_used_at = profile.lastUsedAt
}
```

Extend `toModel()`:
```swift
func toModel() -> ModelProfile {
    ModelProfile(
        id: UUID(uuidString: id)!,
        name: name,
        kind: CredentialKind(rawValue: kind) ?? .oauth,
        baseURL: base_url,
        model: model,
        awsRegion: aws_region,
        awsProfile: aws_profile,
        createdAt: created_at,
        lastUsedAt: last_used_at
    )
}
```

- [ ] **Step 6: Extend `ModelProfileStore.create`**

In the same file:

```swift
public func create(name: String, kind: CredentialKind,
                   baseURL: String? = nil, model: String? = nil,
                   awsRegion: String? = nil, awsProfile: String? = nil
) async throws -> ModelProfile {
    let profile = ModelProfile(
        name: name, kind: kind,
        baseURL: baseURL, model: model,
        awsRegion: awsRegion, awsProfile: awsProfile
    )
    let record = ModelProfileRecord(from: profile)
    try await writer.write { db in
        try record.insert(db)
    }
    return profile
}
```

- [ ] **Step 7: Run tests — expect PASS**

```bash
swift test --filter "ModelProfileMigration|ModelProfileStore" 2>&1 | tail -10
```

Expected: all migration + store tests pass.

- [ ] **Step 8: Build the whole project**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 9: Commit**

```bash
git add Sources/TBDDaemon/Database/Database.swift \
        Sources/TBDDaemon/Database/ModelProfileRecord.swift \
        Tests/TBDDaemonTests/ModelProfileMigrationTests.swift \
        Tests/TBDDaemonTests/ModelProfileStoreTests.swift
git commit -m "feat(TBDDaemon): migration v25 + record plumbing for bedrock profile fields

Additive migration via addColumnIfMissing per Database/CLAUDE.md.
keychain_ref column stays NOT NULL; bedrock rows reuse the existing
default of writing the profile UUID into it."
```

---

## Task 3: Resolver — optional `secret`, AWS fields, Keychain skip for bedrock

**Files:**
- Modify: `Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift`
- Modify: `Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileSpawnTests.swift`

- [ ] **Step 1: Inspect `ClaudeProfileConfigDirManager.swift` around line 100 to confirm the current shape**

```bash
sed -n '90,115p' Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift
```

Confirm that `resolveConfigDir` passes `profile.secret` to an `apiKey:` parameter and decide the exact guard form based on what you see (the spec assumes the function returns the dir or nil; verify before writing the guard).

- [ ] **Step 2: Write failing resolver test**

Add to `Tests/TBDDaemonTests/ModelProfileSpawnTests.swift` (or wherever resolver tests live — grep for `ModelProfileResolver` to confirm):

```swift
@Test("resolver: bedrock profile returns nil secret and populated AWS fields")
func resolverBedrock() async throws {
    let db = try TBDDatabase(inMemory: true)
    let row = try await db.modelProfiles.create(
        name: "Bedrock", kind: .bedrock,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-west-2", awsProfile: "acme"
    )
    let resolver = ModelProfileResolver(
        profiles: db.modelProfiles,
        repos: db.repos,
        config: db.config,
        keychain: { _ in
            #expect(Bool(false), "keychain must not be consulted for bedrock")
            return nil
        }
    )
    let resolved = try await resolver.loadByID(row.id)
    #expect(resolved != nil)
    #expect(resolved?.secret == nil)
    #expect(resolved?.kind == .bedrock)
    #expect(resolved?.awsRegion == "us-west-2")
    #expect(resolved?.awsProfile == "acme")
    #expect(resolved?.model == "anthropic.claude-sonnet-4-5")
}
```

- [ ] **Step 3: Run test — expect failure**

```bash
swift test --filter resolverBedrock 2>&1 | tail -15
```

Expected: build failure (`ResolvedModelProfile.secret` is `String`, no `awsRegion`/`awsProfile`).

- [ ] **Step 4: Update `ResolvedModelProfile`**

In `Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift`:

```swift
public struct ResolvedModelProfile: Sendable, Equatable {
    public let profileID: UUID
    public let name: String
    public let kind: CredentialKind
    public let baseURL: String?
    public let model: String?
    public let secret: String?
    public let awsRegion: String?
    public let awsProfile: String?
}
```

- [ ] **Step 5: Update `loadResolved` to skip Keychain for bedrock**

```swift
private func loadResolved(id: UUID) async throws -> ResolvedModelProfile? {
    guard let row = try await profiles.get(id: id) else { return nil }

    let secret: String?
    if row.kind == .bedrock {
        secret = nil
    } else {
        guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
        secret = s
    }

    try await profiles.touchLastUsed(id: row.id)
    return ResolvedModelProfile(
        profileID: row.id,
        name: row.name,
        kind: row.kind,
        baseURL: row.baseURL,
        model: row.model,
        secret: secret,
        awsRegion: row.awsRegion,
        awsProfile: row.awsProfile
    )
}
```

- [ ] **Step 6: Build to surface call-site breakage**

```bash
swift build 2>&1 | tail -30
```

Expected: at least one error in `ClaudeProfileConfigDirManager` (and possibly tests). Read the actual error.

- [ ] **Step 7: Guard `ClaudeProfileConfigDirManager.resolveConfigDir`**

Based on the exact call shape you confirmed in Step 1, wrap the `ensureDir` call in `guard let apiKey = profile.secret else { return nil }`. Example:

```swift
public func resolveConfigDir(for profile: ResolvedModelProfile) throws -> String? {
    guard profile.baseURL != nil else { return nil }
    guard let apiKey = profile.secret else {
        // Bedrock and any future kind without a Keychain secret don't need
        // an isolated ANTHROPIC_CONFIG_DIR — we're not setting ANTHROPIC_API_KEY
        // at all, so the "Auth conflict" warning this isolation defends
        // against can't fire.
        return nil
    }
    return try ensureDir(forProfileID: profile.profileID, apiKey: apiKey)
}
```

If the actual function shape differs from this, adapt — the key change is "only call `ensureDir(..., apiKey: …)` when `secret` is non-nil."

- [ ] **Step 8: Fix any other compile errors that surface**

```bash
swift build 2>&1 | tail -30
```

Likely additional surfaces: places that pattern-match on a non-optional `secret` (e.g. interpolation). Apply minimum-necessary fixes. Do NOT add bedrock-routing logic here — Task 4 handles the spawn builder.

- [ ] **Step 9: Run resolver tests — expect PASS**

```bash
swift test --filter "ModelProfile" 2>&1 | tail -15
```

Expected: existing tests still pass, new `resolverBedrock` passes.

- [ ] **Step 10: Commit**

```bash
git add Sources/TBDDaemon/ModelProfile/ModelProfileResolver.swift \
        Sources/TBDDaemon/Claude/ClaudeProfileConfigDirManager.swift \
        Tests/TBDDaemonTests/ModelProfileSpawnTests.swift
git commit -m "feat(TBDDaemon): bedrock-aware ResolvedModelProfile

ResolvedModelProfile.secret is now optional (nil for bedrock); two new
fields carry AWS region/profile. loadResolved skips the Keychain lookup
for bedrock kind. ClaudeProfileConfigDirManager guards its ensureDir
call so it never runs for secret-less profiles."
```

---

## Task 4: Spawn builder — bedrock branch + plumb new params through 7 Claude call sites

**Files:**
- Modify: `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift`
- Modify (7 call sites): `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift:273`, `Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift:380`, `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift:280` and `:362`, `Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift:198` and `:572` and `:594`
- Skip (2 non-Claude call sites): `Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift:293` and `:306` already pass `profileSecret: nil` — leave them alone, do NOT add bedrock params.
- Modify: `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift`

- [ ] **Step 1: Confirm the 9 call sites**

```bash
grep -n "ClaudeSpawnCommandBuilder.build" Sources/TBDDaemon -r
```

Expected output matches the file list above. The 2 non-Claude calls in `WorktreeLifecycle+Reconcile.swift` will be obvious — they're inside an `else` branch that handles shell/codex windows.

- [ ] **Step 2: Write failing tests for bedrock env shape**

Add to `Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift`:

```swift
// MARK: - Bedrock

@Test("bedrock: full env set with AWS_PROFILE")
func bedrockFullEnv() {
    let r = ClaudeSpawnCommandBuilder.build(
        resumeID: nil,
        freshSessionID: "sid",
        appendSystemPrompt: nil,
        initialPrompt: nil,
        profileSecret: nil,
        profileKind: .bedrock,
        profileBaseURL: nil,
        profileModel: "anthropic.claude-sonnet-4-5",
        profileAwsRegion: "us-west-2",
        profileAwsProfile: "acme-prod",
        profileConfigDir: nil,
        cmd: nil,
        shellFallback: "/bin/zsh"
    )
    #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == "1")
    #expect(r.sensitiveEnv["AWS_REGION"] == "us-west-2")
    #expect(r.sensitiveEnv["AWS_PROFILE"] == "acme-prod")
    #expect(r.sensitiveEnv["ANTHROPIC_MODEL"] == "anthropic.claude-sonnet-4-5")
    // Forbidden keys
    #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
    #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(r.sensitiveEnv["ANTHROPIC_BASE_URL"] == nil)
    #expect(r.sensitiveEnv["ANTHROPIC_CONFIG_DIR"] == nil)
    // Exactly these 4 keys
    #expect(r.sensitiveEnv.keys.sorted() == ["ANTHROPIC_MODEL", "AWS_PROFILE", "AWS_REGION", "CLAUDE_CODE_USE_BEDROCK"])
}

@Test("bedrock: AWS_PROFILE omitted when nil")
func bedrockNoAwsProfile() {
    let r = ClaudeSpawnCommandBuilder.build(
        resumeID: nil,
        freshSessionID: "sid",
        appendSystemPrompt: nil,
        initialPrompt: nil,
        profileSecret: nil,
        profileKind: .bedrock,
        profileBaseURL: nil,
        profileModel: "anthropic.claude-sonnet-4-5",
        profileAwsRegion: "us-east-1",
        profileAwsProfile: nil,
        profileConfigDir: nil,
        cmd: nil,
        shellFallback: "/bin/zsh"
    )
    #expect(r.sensitiveEnv["AWS_PROFILE"] == nil)
    #expect(r.sensitiveEnv["AWS_REGION"] == "us-east-1")
    #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == "1")
}

@Test("bedrock branch fires even with profileSecret accidentally passed in")
func bedrockIgnoresStraySecret() {
    // Defensive: if a caller passes a non-nil secret with bedrock kind, the
    // bedrock branch still wins and no ANTHROPIC_API_KEY is emitted.
    let r = ClaudeSpawnCommandBuilder.build(
        resumeID: nil,
        freshSessionID: "sid",
        appendSystemPrompt: nil,
        initialPrompt: nil,
        profileSecret: "stray-secret",
        profileKind: .bedrock,
        profileBaseURL: nil,
        profileModel: "anthropic.claude-sonnet-4-5",
        profileAwsRegion: "us-west-2",
        profileAwsProfile: nil,
        profileConfigDir: nil,
        cmd: nil,
        shellFallback: "/bin/zsh"
    )
    #expect(r.sensitiveEnv["ANTHROPIC_API_KEY"] == nil)
    #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
}

@Test("existing oauth path unchanged when bedrock params present but kind is oauth")
func oauthUnaffectedByNewParams() {
    let r = ClaudeSpawnCommandBuilder.build(
        resumeID: nil,
        freshSessionID: "sid",
        appendSystemPrompt: nil,
        initialPrompt: nil,
        profileSecret: fakeOauth,
        profileKind: .oauth,
        profileBaseURL: nil,
        profileModel: nil,
        profileAwsRegion: "us-west-2",   // present but ignored
        profileAwsProfile: "foo",        // present but ignored
        profileConfigDir: nil,
        cmd: nil,
        shellFallback: "/bin/zsh"
    )
    #expect(r.sensitiveEnv["CLAUDE_CODE_OAUTH_TOKEN"] == fakeOauth)
    #expect(r.sensitiveEnv["AWS_REGION"] == nil)
    #expect(r.sensitiveEnv["CLAUDE_CODE_USE_BEDROCK"] == nil)
}
```

- [ ] **Step 3: Run tests — expect build failure**

```bash
swift test --filter ClaudeSpawnCommandBuilder 2>&1 | tail -15
```

Expected: unknown `profileAwsRegion`/`profileAwsProfile` params.

- [ ] **Step 4: Add the new params + bedrock branch to `ClaudeSpawnCommandBuilder.build`**

Edit `Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift`. The new signature:

```swift
static func build(
    resumeID: String?,
    freshSessionID: String?,
    appendSystemPrompt: String?,
    initialPrompt: String?,
    profileSecret: String?,
    profileKind: CredentialKind? = nil,
    profileBaseURL: String? = nil,
    profileModel: String? = nil,
    profileAwsRegion: String? = nil,
    profileAwsProfile: String? = nil,
    profileConfigDir: String? = nil,
    cmd: String?,
    shellFallback: String,
    settingsOverlayPath: String? = nil,
    pluginDirPath: String? = nil,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> Result
```

Replace the existing env-building block (the `var env: [String: String] = [:]` section after the `base` switch) with:

```swift
var env: [String: String] = [:]
if profileKind == .bedrock {
    env["CLAUDE_CODE_USE_BEDROCK"] = "1"
    if let r = profileAwsRegion { env["AWS_REGION"] = r }
    if let p = profileAwsProfile { env["AWS_PROFILE"] = p }
    if let m = profileModel { env["ANTHROPIC_MODEL"] = m }
    // Intentionally no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN /
    // ANTHROPIC_BASE_URL / ANTHROPIC_CONFIG_DIR for bedrock.
} else {
    if let secret = profileSecret {
        let envVar = profileKind == .apiKey ? "ANTHROPIC_API_KEY" : "CLAUDE_CODE_OAUTH_TOKEN"
        env[envVar] = secret
    }
    if let baseURL = profileBaseURL { env["ANTHROPIC_BASE_URL"] = baseURL }
    if let model = profileModel { env["ANTHROPIC_MODEL"] = model }
    // Only inject ANTHROPIC_CONFIG_DIR for proxy profiles.
    if let configDir = profileConfigDir, profileBaseURL != nil {
        env["ANTHROPIC_CONFIG_DIR"] = configDir
    }
}
return Result(command: base, sensitiveEnv: env)
```

- [ ] **Step 5: Plumb new params through 7 Claude call sites**

For each of the 7 Claude-profile call sites listed in the Files header, add `profileAwsRegion: resolvedProfile?.awsRegion, profileAwsProfile: resolvedProfile?.awsProfile,` next to the existing `profileSecret: resolvedProfile?.secret, profileKind: resolvedProfile?.kind, profileBaseURL: resolvedProfile?.baseURL, profileModel: resolvedProfile?.model,` lines. The local variable name may vary (`resolvedProfile`, `resolved`, `profile`) — match it per site. Do NOT modify the 2 non-Claude shell/codex sites in `WorktreeLifecycle+Reconcile.swift:293` and `:306`.

For each site, grep first to see the existing arg style, then mirror it.

- [ ] **Step 6: Build — confirm everything compiles**

```bash
swift build 2>&1 | tail -15
```

Expected: clean build.

- [ ] **Step 7: Run all spawn-related tests**

```bash
swift test --filter "ClaudeSpawn|ModelProfileSpawn" 2>&1 | tail -15
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDDaemon/Claude/ClaudeSpawnCommandBuilder.swift \
        Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift \
        Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Create.swift \
        Sources/TBDDaemon/Lifecycle/SuspendResumeCoordinator.swift \
        Sources/TBDDaemon/Server/RPCRouter+TerminalHandlers.swift \
        Tests/TBDDaemonTests/ClaudeSpawnCommandBuilderTests.swift
git commit -m "feat(TBDDaemon): ClaudeSpawnCommandBuilder bedrock env branch

Bedrock profiles now emit CLAUDE_CODE_USE_BEDROCK=1 + AWS_REGION +
optional AWS_PROFILE + ANTHROPIC_MODEL; explicitly suppresses
ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_BASE_URL /
ANTHROPIC_CONFIG_DIR. AWS params plumbed through the 7 Claude-profile
call sites; the 2 shell/codex builder calls in WorktreeLifecycle+Reconcile
stay nil since they never carry a Claude profile."
```

---

## Task 5: RPC params — kind discriminator + new fields

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`

This task is data-shape only; the handler that consumes the new fields lands in Task 6.

- [ ] **Step 1: Add `ModelProfileAddKind` enum and extend `ModelProfileAddParams`**

In `Sources/TBDShared/RPCProtocol.swift`, near the existing `ModelProfileAddParams` struct, add:

```swift
public enum ModelProfileAddKind: String, Codable, Sendable {
    case claudeDirect   // existing OAuth / api-key path; uses `token`
    case proxy          // existing proxy path; uses `token` + `baseURL`
    case bedrock        // NEW; uses `awsRegion` + optional `awsProfile`; no token
}
```

Replace the existing struct:

```swift
public struct ModelProfileAddParams: Codable, Sendable {
    public let kind: ModelProfileAddKind?
    public let name: String
    public let token: String?
    public let baseURL: String?
    public let model: String?
    public let awsRegion: String?
    public let awsProfile: String?

    public init(name: String,
                kind: ModelProfileAddKind? = nil,
                token: String? = nil,
                baseURL: String? = nil,
                model: String? = nil,
                awsRegion: String? = nil,
                awsProfile: String? = nil) {
        self.kind = kind
        self.name = name
        self.token = token
        self.baseURL = baseURL
        self.model = model
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
    }
}
```

- [ ] **Step 2: Build — surface call-site compile errors**

```bash
swift build 2>&1 | tail -30
```

Expected: errors in `DaemonClient.addModelProfile` and the existing test that calls the old init. Note them but do not fix yet — Task 6 fixes the handler; Task 7 fixes the client and the test layer.

Actually fix them minimally here since they block the build: the existing initializer call sites all use `ModelProfileAddParams(name:, token:, baseURL:, model:)`. The new init is back-compat for those (token is `String?` with default nil — but they pass a non-nil string, which is still valid). The only thing that breaks is calls that omitted `name`/`token` via labels. Grep:

```bash
grep -rn "ModelProfileAddParams(" Sources/ Tests/
```

Adjust any that fail to compile. If the existing app-side `DaemonClient.addModelProfile` constructs the params with positional or label-based args, the new signature should still accept them. If anything breaks, fix it to use the new init's labels.

- [ ] **Step 3: Run all tests to confirm no behavior regression**

```bash
swift test 2>&1 | tail -15
```

Expected: all green. (No new tests in this task — params shape changes are exercised by Task 6's handler tests.)

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift
git commit -m "feat(TBDShared): add kind discriminator + bedrock fields to ModelProfileAddParams

kind defaults to nil for back-compat (handler infers from token shape +
baseURL presence). token becomes optional so bedrock adds can omit it."
```

---

## Task 6: Daemon handler — bedrock add branch + usage-probe rejection

**Files:**
- Modify: `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift`
- Modify: `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`

- [ ] **Step 1: Write failing tests for the bedrock add path**

Add to `Tests/TBDDaemonTests/ModelProfileRPCTests.swift`:

```swift
@Test("modelProfile.add bedrock: persists fields, skips token + keychain + probe")
func addBedrockHappyPath() async throws {
    let (router, db) = try await makeRouter()  // use existing test harness
    let params = ModelProfileAddParams(
        name: "Bedrock prod",
        kind: .bedrock,
        token: nil,
        baseURL: nil,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-west-2",
        awsProfile: "acme-prod"
    )
    let response = try await router.handleModelProfileAdd(JSONEncoder().encode(params))
    #expect(response.success)
    let stored = try await db.modelProfiles.list()
    #expect(stored.count == 1)
    #expect(stored.first?.kind == .bedrock)
    #expect(stored.first?.awsRegion == "us-west-2")
    #expect(stored.first?.awsProfile == "acme-prod")
}

@Test("modelProfile.add bedrock: rejects missing region")
func addBedrockMissingRegion() async throws {
    let (router, _) = try await makeRouter()
    let params = ModelProfileAddParams(
        name: "Bedrock", kind: .bedrock, token: nil,
        model: "anthropic.claude-sonnet-4-5", awsRegion: "", awsProfile: nil
    )
    let response = try await router.handleModelProfileAdd(JSONEncoder().encode(params))
    #expect(!response.success)
    #expect(response.error?.contains("region") == true || response.error?.contains("Region") == true)
}

@Test("modelProfile.add bedrock: rejects missing model")
func addBedrockMissingModel() async throws {
    let (router, _) = try await makeRouter()
    let params = ModelProfileAddParams(
        name: "Bedrock", kind: .bedrock, token: nil,
        model: "", awsRegion: "us-west-2", awsProfile: nil
    )
    let response = try await router.handleModelProfileAdd(JSONEncoder().encode(params))
    #expect(!response.success)
    #expect(response.error?.lowercased().contains("model") == true)
}

@Test("modelProfile.add bedrock: empty awsProfile normalized to nil")
func addBedrockEmptyAwsProfileNormalized() async throws {
    let (router, db) = try await makeRouter()
    let params = ModelProfileAddParams(
        name: "Bedrock", kind: .bedrock, token: nil,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-west-2",
        awsProfile: "   "
    )
    let response = try await router.handleModelProfileAdd(JSONEncoder().encode(params))
    #expect(response.success)
    let stored = try await db.modelProfiles.list()
    #expect(stored.first?.awsProfile == nil)
}

@Test("modelProfile.fetchUsage rejects bedrock profiles")
func fetchUsageRejectsBedrock() async throws {
    let (router, db) = try await makeRouter()
    let row = try await db.modelProfiles.create(
        name: "Bedrock", kind: .bedrock,
        model: "anthropic.claude-sonnet-4-5",
        awsRegion: "us-west-2", awsProfile: nil
    )
    let params = ModelProfileFetchUsageParams(id: row.id)
    let response = try await router.handleModelProfileFetchUsage(JSONEncoder().encode(params))
    #expect(!response.success)
    #expect(response.error?.lowercased().contains("claude-direct") == true ||
            response.error?.lowercased().contains("only available") == true)
}
```

Use the existing test harness pattern in `ModelProfileRPCTests.swift` — there should already be a `makeRouter()` or similar helper. If not, copy from the nearest existing test setup.

- [ ] **Step 2: Run tests — expect failure**

```bash
swift test --filter "addBedrock|fetchUsageRejectsBedrock" 2>&1 | tail -20
```

Expected: failures or build errors due to missing bedrock branch.

- [ ] **Step 3: Update `handleModelProfileAdd` to branch on `kind`**

In `Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift`, near the top of `handleModelProfileAdd`, after decoding params and trimming `name`, add a bedrock branch BEFORE the existing token-validation logic. Existing logic stays the `else` branch.

```swift
func handleModelProfileAdd(_ paramsData: Data) async throws -> RPCResponse {
    let params = try decoder.decode(ModelProfileAddParams.self, from: paramsData)
    let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !name.isEmpty else {
        return RPCResponse(error: "Name cannot be empty")
    }
    if try await db.modelProfiles.getByName(name) != nil {
        return RPCResponse(error: "A profile named '\(name)' already exists")
    }

    if params.kind == .bedrock {
        let region = (params.awsRegion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (params.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let awsProfileRaw = (params.awsProfile ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let awsProfile: String? = awsProfileRaw.isEmpty ? nil : awsProfileRaw

        guard !region.isEmpty else {
            return RPCResponse(error: "AWS region is required for bedrock profiles")
        }
        guard !model.isEmpty else {
            return RPCResponse(error: "Bedrock model id is required")
        }

        let row = try await db.modelProfiles.create(
            name: name,
            kind: .bedrock,
            baseURL: nil,
            model: model,
            awsRegion: region,
            awsProfile: awsProfile
        )
        // No Keychain write, no usage probe.
        subscriptions.broadcast(delta: .modelProfilesChanged)
        return try RPCResponse(result: ModelProfileAddResult(profile: row, warning: nil))
    }

    // … existing claudeDirect / proxy logic continues unchanged from here.
    // Move the existing trimmed-token + kind inference + keychain write +
    // probe code into this fall-through (no change to those lines).
    let trimmed = (params.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // …rest of existing body, replacing `params.token.trimming…` with `trimmed`
}
```

Verify the existing body uses `params.token` directly — if so, change to `(params.token ?? "")` (or to a `guard let token = params.token else { return RPCResponse(error: "Token cannot be empty") }` before the existing trimming/validation).

- [ ] **Step 4: Update `handleModelProfileFetchUsage` rejection guard**

Find the line `if profile.baseURL != nil {` and change to:

```swift
if profile.baseURL != nil || profile.kind == .bedrock {
    return RPCResponse(error: "Usage tracking is only available for Claude-direct profiles")
}
```

- [ ] **Step 5: Run tests — expect PASS**

```bash
swift test --filter "ModelProfileRPC" 2>&1 | tail -15
```

Expected: existing tests still pass, new bedrock add + usage rejection tests pass.

- [ ] **Step 6: Build the whole project**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+ModelProfileHandlers.swift \
        Tests/TBDDaemonTests/ModelProfileRPCTests.swift
git commit -m "feat(TBDDaemon): bedrock add path + reject bedrock in usage probe

The bedrock add branch validates name/region/model, normalizes empty
awsProfile to nil, skips token validation + Keychain write + Anthropic
usage probe. fetchUsage rejects bedrock alongside proxy profiles."
```

---

## Task 7: App client + AppState plumbing for the new params

**Files:**
- Modify: `Sources/TBDApp/DaemonClient.swift` (locate `addModelProfile`)
- Modify: `Sources/TBDApp/AppState+ModelProfiles.swift`

- [ ] **Step 1: Locate the existing `DaemonClient.addModelProfile`**

```bash
grep -n "func addModelProfile" Sources/TBDApp/DaemonClient.swift
```

- [ ] **Step 2: Update its signature to mirror the new RPC params**

```swift
func addModelProfile(name: String,
                     kind: ModelProfileAddKind? = nil,
                     token: String? = nil,
                     baseURL: String? = nil,
                     model: String? = nil,
                     awsRegion: String? = nil,
                     awsProfile: String? = nil) async throws -> ModelProfileAddResult {
    let params = ModelProfileAddParams(
        name: name,
        kind: kind,
        token: token,
        baseURL: baseURL,
        model: model,
        awsRegion: awsRegion,
        awsProfile: awsProfile
    )
    let response = try await call(method: RPCMethod.modelProfileAdd, params: params)
    return try response.decodeResult(ModelProfileAddResult.self)
}
```

Keep the existing return-type wrapping/error handling style — adapt to whatever pattern that file already uses.

- [ ] **Step 3: Update `AppState.addModelProfile`**

In `Sources/TBDApp/AppState+ModelProfiles.swift`:

```swift
@discardableResult
func addModelProfile(name: String,
                     kind: ModelProfileAddKind? = nil,
                     token: String? = nil,
                     baseURL: String? = nil,
                     model: String? = nil,
                     awsRegion: String? = nil,
                     awsProfile: String? = nil) async -> String? {
    do {
        let result = try await daemonClient.addModelProfile(
            name: name, kind: kind, token: token,
            baseURL: baseURL, model: model,
            awsRegion: awsRegion, awsProfile: awsProfile
        )
        await loadModelProfiles()
        return result.warning
    } catch {
        logger.error("Failed to add model profile (name=\(name, privacy: .public)): \(error, privacy: .public)")
        showAlert("Failed to add model profile: \(error.localizedDescription)", isError: true)
        return nil
    }
}
```

- [ ] **Step 4: Build — confirm existing call sites still compile**

```bash
swift build 2>&1 | tail -15
```

Expected: clean build. The two existing callers in `ModelProfilesSettingsView.swift` use `addModelProfile(name:, token:, baseURL:, model:)` — those labels still match the new init with `kind` defaulted to nil and `awsRegion`/`awsProfile` defaulted to nil.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDApp/DaemonClient.swift \
        Sources/TBDApp/AppState+ModelProfiles.swift
git commit -m "feat(TBDApp): forward bedrock params through AppState + DaemonClient"
```

---

## Task 8: Migrate 5 display sites to shared `kindLabel` / `detailCaption` / `tabDisplayName`

**Files:**
- Modify: `Sources/TBDApp/RepoDetailView.swift:89-93`
- Modify: `Sources/TBDApp/Settings/SettingsView.swift:242-246`
- Modify: `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift:112-118` and `:144-151`
- Modify: `Sources/TBDApp/TabBar.swift:595` (input only)
- Modify: `Sources/TBDApp/MenuBar/ModelProfileMenu.swift:70`

This task purely migrates existing UI to use the new extension. No behavior change for OAuth / API-key / Proxy users; bedrock rows render correctly because the extension already supports them.

- [ ] **Step 1: Inspect each site to confirm the current pattern**

```bash
sed -n '85,95p' Sources/TBDApp/RepoDetailView.swift
sed -n '240,250p' Sources/TBDApp/Settings/SettingsView.swift
sed -n '110,155p' Sources/TBDApp/Settings/ModelProfilesSettingsView.swift
sed -n '590,615p' Sources/TBDApp/TabBar.swift
sed -n '65,75p' Sources/TBDApp/MenuBar/ModelProfileMenu.swift
```

- [ ] **Step 2: Migrate `RepoDetailView.swift:89-93`**

Replace the existing 5-line block (currently `guard let baseURL = entry.profile.baseURL else { return entry.profile.name } …`) with a single expression that uses the extension. Example:

```swift
private func profileLabel(entry: ModelProfileWithUsage) -> String {
    let profile = entry.profile
    if let detail = profile.detailCaption {
        return "\(profile.name) — \(detail)"
    }
    return profile.name
}
```

If the function isn't already extracted, adapt to the existing shape — the substitution is "replace the inline `baseURL`/`model` interpolation with `profile.detailCaption`."

- [ ] **Step 3: Migrate `SettingsView.swift:242-246`**

Identical change — replace the same inline block with `profile.detailCaption`.

- [ ] **Step 4: Migrate `ModelProfilesSettingsView.swift`**

Two changes:

In `endpointCaption` (line 112-118), replace the inline body with:

```swift
private var endpointCaption: String? { profile.detailCaption }
```

In `kindBadge` (line 144-151), replace the binary text:

```swift
private var kindBadge: some View {
    Text(profile.kindLabel)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
}
```

- [ ] **Step 5: Migrate `TabBar.swift:595` (input only — preserve ordinal block)**

Find `let name = entry.profile.name` on line 595 and change to:

```swift
let name = entry.profile.tabDisplayName
```

Do NOT change the surrounding `sameTokenTabs` / ordinal-suffix logic — it stays.

- [ ] **Step 6: Migrate `MenuBar/ModelProfileMenu.swift:70`**

Change `entry.profile.name` to `entry.profile.tabDisplayName` at line 70 (and any other render-the-name sites in the file — grep first).

- [ ] **Step 7: Build and run UI-area tests**

```bash
swift build 2>&1 | tail -10
swift test 2>&1 | tail -15
```

Expected: clean build, all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDApp/
git commit -m "refactor(TBDApp): consolidate profile display via shared interface

Five sites that formatted profile name + kind + endpoint inline now use
ModelProfile.kindLabel / detailCaption / tabDisplayName. TabBar's ordinal
disambiguation block is preserved — only its bare-name input changes.
Bedrock profiles will render with the same formatting machinery."
```

---

## Task 9: Add the Bedrock option to the add-profile sheet

**Files:**
- Modify: `Sources/TBDApp/Settings/ModelProfilesSettingsView.swift`

- [ ] **Step 1: Extend `AddPreset` enum (line ~190)**

```swift
private enum AddPreset: String, CaseIterable, Identifiable {
    case claudeDirect = "Claude (direct)"
    case proxy        = "Anthropic-compatible proxy"
    case bedrock      = "AWS Bedrock"
    var id: String { rawValue }
}
```

- [ ] **Step 2: Add bedrock-specific state to `AddModelProfileSheet`**

Near the existing `@State private var baseURL = ""` etc, add:

```swift
@State private var awsRegion = ""
@State private var awsProfile = ""
```

- [ ] **Step 3: Add a bedrock branch to the form body**

Inside the `Form { … }` block (around line 235), the existing `if preset == .proxy { … } else { … }` becomes a 3-way switch:

```swift
TextField("Name", text: $name)
switch preset {
case .claudeDirect:
    SecureField("Token", text: $token)
    (Text("Run ")
        + Text("claude setup-token").font(.system(.caption, design: .monospaced))
        + Text(" in a terminal and paste the resulting sk-ant-oat01-… token."))
        .font(.caption)
        .foregroundColor(.secondary)
case .proxy:
    SecureField("Token", text: $token)
    TextField("Base URL", text: $baseURL,
              prompt: Text("http://127.0.0.1:3456"))
    TextField("Model", text: $model,
              prompt: Text("e.g. gpt-5-codex"))
    Text("Leave blank to pass through whatever model Claude Code selects.")
        .font(.caption)
        .foregroundColor(.secondary)
case .bedrock:
    TextField("Region", text: $awsRegion,
              prompt: Text("us-west-2"))
    TextField("AWS profile (optional)", text: $awsProfile,
              prompt: Text("default"))
    Text("Leave blank to use the AWS SDK default credential chain — env vars, SSO, instance role.")
        .font(.caption)
        .foregroundColor(.secondary)
    TextField("Model", text: $model,
              prompt: Text("us.anthropic.claude-sonnet-4-5-20250929-v1:0"))
    Text("Cross-region inference profile ID (e.g. `us.anthropic.claude-sonnet-4-5-…`). Required for Claude 4.5+ models — bare model IDs no longer support on-demand throughput.")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

- [ ] **Step 4: Update `canSave` for bedrock**

```swift
private var canSave: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty, !isSaving else { return false }
    let duplicate = appState.modelProfiles.contains { $0.profile.name == trimmedName }
    if duplicate { return false }
    switch preset {
    case .claudeDirect:
        return !token.isEmpty
    case .proxy:
        return !token.isEmpty &&
               !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    case .bedrock:
        return !awsRegion.trimmingCharacters(in: .whitespaces).isEmpty &&
               !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
```

- [ ] **Step 5: Update `save()` to dispatch bedrock to the new path**

Modify the `save()` function so:
- For `.claudeDirect` and `.proxy` it calls the existing path (no `kind` argument, or `kind: .claudeDirect` / `.proxy` as appropriate — the daemon infers it either way).
- For `.bedrock` it calls `appState.addModelProfile(name:, kind: .bedrock, awsRegion:, awsProfile:, model:)` and skips the health probe section.

Example replacement for the bedrock branch:

```swift
if preset == .bedrock {
    let trimmedRegion = awsRegion.trimmingCharacters(in: .whitespaces)
    let trimmedAwsProfile = awsProfile.trimmingCharacters(in: .whitespaces)
    let trimmedModel = model.trimmingCharacters(in: .whitespaces)
    let priorAlert = await MainActor.run { appState.alertMessage }
    let warning = await appState.addModelProfile(
        name: trimmedName,
        kind: .bedrock,
        token: nil,
        baseURL: nil,
        model: trimmedModel,
        awsRegion: trimmedRegion,
        awsProfile: trimmedAwsProfile.isEmpty ? nil : trimmedAwsProfile
    )
    await MainActor.run {
        isSaving = false
        let newAlert = appState.alertMessage
        if newAlert != priorAlert, let msg = newAlert {
            errorMessage = msg
            appState.alertMessage = priorAlert
            return
        }
        if let warning {
            errorMessage = warning
            return
        }
        dismiss()
    }
    return
}
```

- [ ] **Step 6: Hide the "Edit endpoint" button for bedrock rows**

In `ModelProfileRow.body`, find the existing `if profile.baseURL != nil { Button("Edit endpoint") … }` and add a second guard:

```swift
if profile.baseURL != nil && profile.kind != .bedrock {
    Button("Edit endpoint") { showEditEndpoint = true }
        .controlSize(.small)
}
```

(Belt-and-braces — bedrock has `baseURL == nil` so it would already be hidden, but the explicit guard documents intent.)

- [ ] **Step 7: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 8: Commit**

```bash
git add Sources/TBDApp/Settings/ModelProfilesSettingsView.swift
git commit -m "feat(TBDApp): AWS Bedrock option in add-profile sheet

Third segmented preset shows Region + optional AWS profile + Model
fields; canSave validates the bedrock-specific subset; save() dispatches
to AppState.addModelProfile with kind: .bedrock. No health probe (no
endpoint to probe — AWS SDK validates at first request)."
```

---

## Task 10: End-to-end verification

**Files:** none — this is a manual + automated verification pass.

- [ ] **Step 1: Full build + test**

```bash
swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```

Expected: clean build, all tests pass.

- [ ] **Step 2: Lint check**

```bash
swift package plugin --allow-writing-to-package-directory swiftlint --strict 2>&1 | tail -20
```

Expected: pass. If there are violations, fix them — pre-push hook will block otherwise.

- [ ] **Step 3: Full restart so the daemon picks up the new schema + code**

```bash
scripts/restart.sh
```

Verify only one daemon + one app are running from the worktree path:

```bash
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
```

Expected: exactly one `TBDDaemon` and one `TBDApp`, both from the worktree path.

- [ ] **Step 4: Add a Bedrock profile via the UI**

Open Settings → Model Profiles → Add profile → select "AWS Bedrock". Fill in:
- Name: `Bedrock test`
- Region: `us-west-2`
- AWS profile: leave blank (test the default-chain path first)
- Model: `us.anthropic.claude-sonnet-4-5-20250929-v1:0` (cross-region inference profile — required for Claude 4.5+ on Bedrock; bare model IDs return ValidationException)

Save. Confirm it appears in the list with "Bedrock" badge and `us-west-2 · anthropic.claude-…` caption.

- [ ] **Step 5: Confirm persistence**

```bash
scripts/restart.sh
```

Reopen Settings — profile should still be there.

- [ ] **Step 6: Spawn a Claude session against the bedrock profile**

Set the bedrock profile as the global default (Settings → "Global default"). Create a new worktree (or open a terminal in an existing one). Inside the spawned Claude tab, drop to a shell (Ctrl-C twice) or open a sibling shell tab in the same worktree and run:

```bash
env | grep -E 'ANTHROPIC|AWS|CLAUDE_CODE' | sort
```

Expected exact set (order may vary):
```
ANTHROPIC_MODEL=us.anthropic.claude-sonnet-4-5-20250929-v1:0
AWS_REGION=us-west-2
CLAUDE_CODE_USE_BEDROCK=1
```

Forbidden — none of these should be present:
- `ANTHROPIC_API_KEY=…`
- `CLAUDE_CODE_OAUTH_TOKEN=…`
- `ANTHROPIC_BASE_URL=…`
- `ANTHROPIC_CONFIG_DIR=…`
- `AWS_PROFILE=…` (since we left it blank)

- [ ] **Step 7: Run a real Claude turn through Bedrock**

Type a trivial prompt (e.g. "what's 2+2?") into the Claude session. Confirm a response.

In a separate terminal, watch for AWS Bedrock activity:

```bash
# If you have aws-cli configured and a CloudTrail trail:
aws cloudtrail lookup-events --lookup-attributes \
  AttributeKey=EventName,AttributeValue=InvokeModel \
  --max-results 5
# Or just confirm by reading the Claude session's response and trusting
# that the env var contract is correct.
```

- [ ] **Step 8: Add a second bedrock profile, different region**

Confirm the schema supports multiple bedrock rows (per spec). Add `Bedrock dr` with region `us-east-1` and the same model. Confirm both coexist; switching between them in the global-default picker works.

- [ ] **Step 9: Delete a bedrock profile**

Delete one of them via the row menu. Watch the daemon log:

```bash
log stream --level debug --predicate 'subsystem == "com.tbd.daemon" AND category == "modelProfileHandlers"'
```

Expected: one `"Failed to delete secret file"` warning (no Keychain entry existed) but the RPC returns success and the row disappears from the UI.

- [ ] **Step 10: Final commit (verification log only — no code change)**

If everything above passes, no commit needed — Tasks 1–9 already contain the code. Note any deviations in a follow-up commit message if you had to adjust the plan during execution.

---

## Definition of done

- All 10 tasks above have their boxes checked.
- `swift build` and `swift test` pass.
- SwiftLint passes (`--strict`).
- Manual verification in Task 10 succeeds end-to-end against a real AWS Bedrock account.
- Spec accepted-risks remain as designed (no mixed-version decode tolerance, no extra Bedrock env vars).

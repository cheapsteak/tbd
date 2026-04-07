# Phase 01: Schema & Models

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** nothing
> **Unblocks:** all other phases

**Scope:** Database migration v13, new records/stores for Claude tokens & usage cache, a new Config singleton store, and optional field additions to Repo and Terminal models.

---

## Conventions used in this phase

- **Migration style:** copy `Database.swift` v12 — `migrator.registerMigration("v13") { db in ... }` with `try db.create(table:)` / `try db.alter(table:)` and `.defaults(to:)` on every new column.
- **Record + Store style:** copy `RepoStore.swift` exactly — top-level `XxxRecord: Codable, FetchableRecord, PersistableRecord, Sendable` with `init(from:)` and `toModel()`, then `public struct XxxStore: Sendable { let writer: any DatabaseWriter }`.
- **Test style:** Swift Testing — `@Suite("...")`, `@Test func ...() async throws`, `#expect(...)`, `let db = try TBDDatabase(inMemory: true)`.
- **Backward-compat decoders:** every new optional field on `Repo` and `Terminal` must be wired through a custom `init(from decoder:)` using `decodeIfPresent` (matching `Worktree`/`Terminal` precedent in `Models.swift`).
- **Commit cadence:** one commit per task. Each commit must `swift build` and `swift test` clean.

---

## Task list

### 1. Add models to TBDShared

- [ ] **Files**
  - Modify: `Sources/TBDShared/Models.swift`
  - Test: `Tests/TBDDaemonTests/ClaudeTokenModelTests.swift` (new)

- [ ] **Steps**
  1. Write a failing test that decodes JSON for each new type:
     ```swift
     import Testing
     import Foundation
     @testable import TBDShared

     @Suite("Claude Token Models")
     struct ClaudeTokenModelTests {
         @Test func decodeClaudeToken() throws {
             let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Personal","kind":"oauth","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
             let dec = JSONDecoder()
             dec.dateDecodingStrategy = .iso8601
             let tok = try dec.decode(ClaudeToken.self, from: json)
             #expect(tok.name == "Personal")
             #expect(tok.kind == .oauth)
             #expect(tok.lastUsedAt == nil)
         }

         @Test func decodeClaudeTokenKindApiKey() throws {
             let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Work","kind":"apiKey","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
             let dec = JSONDecoder()
             dec.dateDecodingStrategy = .iso8601
             let tok = try dec.decode(ClaudeToken.self, from: json)
             #expect(tok.kind == .apiKey)
         }

         @Test func decodeClaudeTokenUsage() throws {
             let json = #"{"tokenID":"11111111-1111-1111-1111-111111111111","fiveHourPct":0.42,"sevenDayPct":0.18,"lastStatus":"ok"}"#.data(using: .utf8)!
             let u = try JSONDecoder().decode(ClaudeTokenUsage.self, from: json)
             #expect(u.fiveHourPct == 0.42)
             #expect(u.sevenDayPct == 0.18)
             #expect(u.lastStatus == "ok")
         }

         @Test func decodeConfigEmpty() throws {
             let u = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
             #expect(u.defaultClaudeTokenID == nil)
         }

         @Test func repoDecodesWithoutOverride() throws {
             let json = #"{"id":"11111111-1111-1111-1111-111111111111","path":"/tmp/x","displayName":"x","defaultBranch":"main","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
             let dec = JSONDecoder()
             dec.dateDecodingStrategy = .iso8601
             let r = try dec.decode(Repo.self, from: json)
             #expect(r.claudeTokenOverrideID == nil)
         }

         @Test func terminalDecodesWithoutTokenID() throws {
             let json = #"{"id":"11111111-1111-1111-1111-111111111111","worktreeID":"22222222-2222-2222-2222-222222222222","tmuxWindowID":"@1","tmuxPaneID":"%0","createdAt":"2026-04-06T00:00:00Z"}"#.data(using: .utf8)!
             let dec = JSONDecoder()
             dec.dateDecodingStrategy = .iso8601
             let t = try dec.decode(Terminal.self, from: json)
             #expect(t.claudeTokenID == nil)
         }
     }
     ```
  2. Run `swift test --filter ClaudeTokenModelTests` and verify it fails (types don't exist yet).
  3. Add to `Sources/TBDShared/Models.swift`:
     ```swift
     public enum ClaudeTokenKind: String, Codable, Sendable {
         case oauth
         case apiKey
     }

     public struct ClaudeToken: Codable, Sendable, Identifiable, Equatable {
         public let id: UUID
         public var name: String
         public var kind: ClaudeTokenKind
         public var createdAt: Date
         public var lastUsedAt: Date?

         public init(id: UUID = UUID(), name: String, kind: ClaudeTokenKind,
                     createdAt: Date = Date(), lastUsedAt: Date? = nil) {
             self.id = id
             self.name = name
             self.kind = kind
             self.createdAt = createdAt
             self.lastUsedAt = lastUsedAt
         }
     }

     public struct ClaudeTokenUsage: Codable, Sendable, Equatable {
         public var tokenID: UUID
         public var fiveHourPct: Double?
         public var sevenDayPct: Double?
         public var fiveHourResetsAt: Date?
         public var sevenDayResetsAt: Date?
         public var fetchedAt: Date?
         public var lastStatus: String?

         public init(tokenID: UUID, fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
                     fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil,
                     fetchedAt: Date? = nil, lastStatus: String? = nil) {
             self.tokenID = tokenID
             self.fiveHourPct = fiveHourPct
             self.sevenDayPct = sevenDayPct
             self.fiveHourResetsAt = fiveHourResetsAt
             self.sevenDayResetsAt = sevenDayResetsAt
             self.fetchedAt = fetchedAt
             self.lastStatus = lastStatus
         }
     }

     public struct Config: Codable, Sendable, Equatable {
         public var defaultClaudeTokenID: UUID?

         public init(defaultClaudeTokenID: UUID? = nil) {
             self.defaultClaudeTokenID = defaultClaudeTokenID
         }

         public init(from decoder: Decoder) throws {
             let c = try decoder.container(keyedBy: CodingKeys.self)
             defaultClaudeTokenID = try c.decodeIfPresent(UUID.self, forKey: .defaultClaudeTokenID)
         }
     }
     ```
  4. Add `claudeTokenOverrideID: UUID?` to `Repo`:
     - Add the stored property with default `nil`.
     - Extend the initializer with a `claudeTokenOverrideID: UUID? = nil` parameter.
     - Add a custom `init(from decoder:)`:
       ```swift
       public init(from decoder: Decoder) throws {
           let c = try decoder.container(keyedBy: CodingKeys.self)
           id = try c.decode(UUID.self, forKey: .id)
           path = try c.decode(String.self, forKey: .path)
           remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
           displayName = try c.decode(String.self, forKey: .displayName)
           defaultBranch = try c.decode(String.self, forKey: .defaultBranch)
           createdAt = try c.decode(Date.self, forKey: .createdAt)
           renamePrompt = try c.decodeIfPresent(String.self, forKey: .renamePrompt)
           customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions)
           claudeTokenOverrideID = try c.decodeIfPresent(UUID.self, forKey: .claudeTokenOverrideID)
       }
       ```
  5. Add `claudeTokenID: UUID?` to `Terminal`:
     - Add the stored property with default `nil`.
     - Extend the initializer with `claudeTokenID: UUID? = nil`.
     - Add `claudeTokenID = try c.decodeIfPresent(UUID.self, forKey: .claudeTokenID)` to the existing custom decoder.
  6. Run `swift test --filter ClaudeTokenModelTests`. Expected: 6 tests pass.
  7. Commit: `feat: add ClaudeToken / ClaudeTokenUsage / Config models and optional fields on Repo/Terminal`.

---

### 2. Migration v13 — `claude_tokens` and `claude_token_usage` tables

- [ ] **Files**
  - Modify: `Sources/TBDDaemon/Database/Database.swift`
  - Test: `Tests/TBDDaemonTests/ClaudeTokenMigrationTests.swift` (new)

- [ ] **Steps**
  1. Write failing test:
     ```swift
     import Testing
     import Foundation
     import GRDB
     @testable import TBDDaemonLib
     @testable import TBDShared

     @Suite("Claude Token Migration")
     struct ClaudeTokenMigrationTests {
         @Test func v13CreatesClaudeTokensTable() async throws {
             let db = try TBDDatabase(inMemory: true)
             try await db.writerForTests.read { conn in
                 #expect(try conn.tableExists("claude_tokens"))
                 #expect(try conn.tableExists("claude_token_usage"))
                 #expect(try conn.tableExists("config"))
             }
         }

         @Test func v13AddsRepoAndTerminalColumns() async throws {
             let db = try TBDDatabase(inMemory: true)
             try await db.writerForTests.read { conn in
                 let repoCols = try conn.columns(in: "repo").map(\.name)
                 #expect(repoCols.contains("claude_token_override_id"))
                 let termCols = try conn.columns(in: "terminal").map(\.name)
                 #expect(termCols.contains("claude_token_id"))
             }
         }

         @Test func v13InsertsConfigSingleton() async throws {
             let db = try TBDDatabase(inMemory: true)
             try await db.writerForTests.read { conn in
                 let count = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM config WHERE id = 'singleton'")
                 #expect(count == 1)
             }
         }
     }
     ```
     Note: this test references `db.writerForTests` — add an `internal var writerForTests: any DatabaseWriter { writer }` accessor on `TBDDatabase` (test-only convenience; daemon code never uses it).
  2. Run `swift test --filter ClaudeTokenMigrationTests`. Expected: fails (tables don't exist).
  3. In `Database.swift`, after the `v12` block, add:
     ```swift
     migrator.registerMigration("v13") { db in
         try db.create(table: "claude_tokens") { t in
             t.primaryKey("id", .text).notNull()
             t.column("name", .text).notNull().unique()
             t.column("keychain_ref", .text).notNull()
             t.column("kind", .text).notNull()
             t.column("created_at", .datetime).notNull()
             t.column("last_used_at", .datetime)
         }

         try db.create(table: "claude_token_usage") { t in
             t.primaryKey("token_id", .text).notNull()
                 .references("claude_tokens", onDelete: .cascade)
             t.column("five_hour_pct", .double)
             t.column("seven_day_pct", .double)
             t.column("five_hour_resets_at", .datetime)
             t.column("seven_day_resets_at", .datetime)
             t.column("fetched_at", .datetime)
             t.column("last_status", .text)
         }

         try db.create(table: "config") { t in
             t.primaryKey("id", .text).notNull()
             t.column("default_claude_token_id", .text)
                 .references("claude_tokens", onDelete: .setNull)
         }
         try db.execute(
             sql: "INSERT OR IGNORE INTO config (id, default_claude_token_id) VALUES ('singleton', NULL)"
         )

         try db.alter(table: "repo") { t in
             t.add(column: "claude_token_override_id", .text)
         }

         try db.alter(table: "terminal") { t in
             t.add(column: "claude_token_id", .text)
         }
     }
     ```
  4. Add the `writerForTests` accessor on `TBDDatabase`.
  5. Run `swift test --filter ClaudeTokenMigrationTests`. Expected: 3 tests pass.
  6. Run the full `swift test` to ensure no existing test broke.
  7. Commit: `feat: add migration v13 for claude_tokens, claude_token_usage, config tables`.

---

### 3. `ClaudeTokenRecord` + `ClaudeTokenStore`

- [ ] **Files**
  - Create: `Sources/TBDDaemon/Database/ClaudeTokenRecord.swift`
  - Modify: `Sources/TBDDaemon/Database/Database.swift` (wire `claudeTokens` accessor)
  - Test: `Tests/TBDDaemonTests/ClaudeTokenStoreTests.swift` (new)

- [ ] **Steps**
  1. Write failing test:
     ```swift
     import Testing
     import Foundation
     @testable import TBDDaemonLib
     @testable import TBDShared

     @Suite("ClaudeTokenStore")
     struct ClaudeTokenStoreTests {
         @Test func createListGet() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
             #expect(tok.name == "Personal")
             #expect(tok.kind == .oauth)

             let all = try await db.claudeTokens.list()
             #expect(all.count == 1)

             let fetched = try await db.claudeTokens.get(id: tok.id)
             #expect(fetched?.id == tok.id)
         }

         @Test func getByName() async throws {
             let db = try TBDDatabase(inMemory: true)
             _ = try await db.claudeTokens.create(name: "Work", kind: .apiKey)
             let found = try await db.claudeTokens.getByName("Work")
             #expect(found?.kind == .apiKey)
             let missing = try await db.claudeTokens.getByName("Nope")
             #expect(missing == nil)
         }

         @Test func renameAndDelete() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "Old", kind: .oauth)
             try await db.claudeTokens.rename(id: tok.id, name: "New")
             let renamed = try await db.claudeTokens.get(id: tok.id)
             #expect(renamed?.name == "New")

             try await db.claudeTokens.delete(id: tok.id)
             #expect(try await db.claudeTokens.get(id: tok.id) == nil)
         }

         @Test func touchLastUsed() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
             #expect(tok.lastUsedAt == nil)
             try await db.claudeTokens.touchLastUsed(id: tok.id)
             let updated = try await db.claudeTokens.get(id: tok.id)
             #expect(updated?.lastUsedAt != nil)
         }
     }
     ```
  2. Run and verify failure (`db.claudeTokens` doesn't exist).
  3. Create `Sources/TBDDaemon/Database/ClaudeTokenRecord.swift`:
     ```swift
     import Foundation
     import GRDB
     import TBDShared

     struct ClaudeTokenRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
         static let databaseTableName = "claude_tokens"

         var id: String
         var name: String
         var keychain_ref: String
         var kind: String
         var created_at: Date
         var last_used_at: Date?

         init(from token: ClaudeToken) {
             self.id = token.id.uuidString
             self.name = token.name
             self.keychain_ref = token.id.uuidString
             self.kind = token.kind.rawValue
             self.created_at = token.createdAt
             self.last_used_at = token.lastUsedAt
         }

         func toModel() -> ClaudeToken {
             ClaudeToken(
                 id: UUID(uuidString: id)!,
                 name: name,
                 kind: ClaudeTokenKind(rawValue: kind) ?? .oauth,
                 createdAt: created_at,
                 lastUsedAt: last_used_at
             )
         }
     }

     public struct ClaudeTokenStore: Sendable {
         let writer: any DatabaseWriter

         init(writer: any DatabaseWriter) {
             self.writer = writer
         }

         public func create(name: String, kind: ClaudeTokenKind) async throws -> ClaudeToken {
             let token = ClaudeToken(name: name, kind: kind)
             let record = ClaudeTokenRecord(from: token)
             try await writer.write { db in
                 try record.insert(db)
             }
             return token
         }

         public func list() async throws -> [ClaudeToken] {
             try await writer.read { db in
                 try ClaudeTokenRecord.fetchAll(db).map { $0.toModel() }
             }
         }

         public func get(id: UUID) async throws -> ClaudeToken? {
             try await writer.read { db in
                 try ClaudeTokenRecord.fetchOne(db, key: id.uuidString)?.toModel()
             }
         }

         public func getByName(_ name: String) async throws -> ClaudeToken? {
             try await writer.read { db in
                 try ClaudeTokenRecord
                     .filter(Column("name") == name)
                     .fetchOne(db)?
                     .toModel()
             }
         }

         public func rename(id: UUID, name: String) async throws {
             try await writer.write { db in
                 try db.execute(
                     sql: "UPDATE claude_tokens SET name = ? WHERE id = ?",
                     arguments: [name, id.uuidString]
                 )
             }
         }

         public func delete(id: UUID) async throws {
             _ = try await writer.write { db in
                 try ClaudeTokenRecord.deleteOne(db, key: id.uuidString)
             }
         }

         public func touchLastUsed(id: UUID, at date: Date = Date()) async throws {
             try await writer.write { db in
                 try db.execute(
                     sql: "UPDATE claude_tokens SET last_used_at = ? WHERE id = ?",
                     arguments: [date, id.uuidString]
                 )
             }
         }
     }
     ```
  4. Wire into `TBDDatabase`:
     - Add `public let claudeTokens: ClaudeTokenStore` next to existing stores.
     - Initialize in both `init(path:)` and `init(inMemory:)` after the pool/queue is created: `self.claudeTokens = ClaudeTokenStore(writer: pool)` (or `queue`).
  5. Run `swift test --filter ClaudeTokenStoreTests`. Expected: 4 pass.
  6. Commit: `feat: add ClaudeTokenStore with CRUD + touchLastUsed`.

---

### 4. `ClaudeTokenUsageRecord` + `ClaudeTokenUsageStore`

- [ ] **Files**
  - Create: `Sources/TBDDaemon/Database/ClaudeTokenUsageRecord.swift`
  - Modify: `Sources/TBDDaemon/Database/Database.swift` (wire `claudeTokenUsage`)
  - Test: `Tests/TBDDaemonTests/ClaudeTokenUsageStoreTests.swift` (new)

- [ ] **Steps**
  1. Write failing test:
     ```swift
     import Testing
     import Foundation
     @testable import TBDDaemonLib
     @testable import TBDShared

     @Suite("ClaudeTokenUsageStore")
     struct ClaudeTokenUsageStoreTests {
         @Test func upsertIsIdempotent() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
             let u1 = ClaudeTokenUsage(tokenID: tok.id, fiveHourPct: 0.1, sevenDayPct: 0.2, lastStatus: "ok")
             try await db.claudeTokenUsage.upsert(u1)
             let u2 = ClaudeTokenUsage(tokenID: tok.id, fiveHourPct: 0.5, sevenDayPct: 0.6, lastStatus: "ok")
             try await db.claudeTokenUsage.upsert(u2)

             let fetched = try await db.claudeTokenUsage.get(tokenID: tok.id)
             #expect(fetched?.fiveHourPct == 0.5)
             #expect(fetched?.sevenDayPct == 0.6)
         }

         @Test func deleteForToken() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
             try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(tokenID: tok.id, lastStatus: "ok"))
             try await db.claudeTokenUsage.deleteForToken(id: tok.id)
             #expect(try await db.claudeTokenUsage.get(tokenID: tok.id) == nil)
         }

         @Test func cascadeOnTokenDelete() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "T", kind: .oauth)
             try await db.claudeTokenUsage.upsert(ClaudeTokenUsage(tokenID: tok.id, lastStatus: "ok"))
             try await db.claudeTokens.delete(id: tok.id)
             #expect(try await db.claudeTokenUsage.get(tokenID: tok.id) == nil)
         }
     }
     ```
  2. Run and verify failure.
  3. Create `Sources/TBDDaemon/Database/ClaudeTokenUsageRecord.swift`:
     ```swift
     import Foundation
     import GRDB
     import TBDShared

     struct ClaudeTokenUsageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
         static let databaseTableName = "claude_token_usage"

         var token_id: String
         var five_hour_pct: Double?
         var seven_day_pct: Double?
         var five_hour_resets_at: Date?
         var seven_day_resets_at: Date?
         var fetched_at: Date?
         var last_status: String?

         init(from u: ClaudeTokenUsage) {
             self.token_id = u.tokenID.uuidString
             self.five_hour_pct = u.fiveHourPct
             self.seven_day_pct = u.sevenDayPct
             self.five_hour_resets_at = u.fiveHourResetsAt
             self.seven_day_resets_at = u.sevenDayResetsAt
             self.fetched_at = u.fetchedAt
             self.last_status = u.lastStatus
         }

         func toModel() -> ClaudeTokenUsage {
             ClaudeTokenUsage(
                 tokenID: UUID(uuidString: token_id)!,
                 fiveHourPct: five_hour_pct,
                 sevenDayPct: seven_day_pct,
                 fiveHourResetsAt: five_hour_resets_at,
                 sevenDayResetsAt: seven_day_resets_at,
                 fetchedAt: fetched_at,
                 lastStatus: last_status
             )
         }
     }

     public struct ClaudeTokenUsageStore: Sendable {
         let writer: any DatabaseWriter

         init(writer: any DatabaseWriter) {
             self.writer = writer
         }

         public func upsert(_ usage: ClaudeTokenUsage) async throws {
             let record = ClaudeTokenUsageRecord(from: usage)
             try await writer.write { db in
                 try record.save(db) // GRDB upsert by primary key
             }
         }

         public func get(tokenID: UUID) async throws -> ClaudeTokenUsage? {
             try await writer.read { db in
                 try ClaudeTokenUsageRecord.fetchOne(db, key: tokenID.uuidString)?.toModel()
             }
         }

         public func deleteForToken(id: UUID) async throws {
             _ = try await writer.write { db in
                 try ClaudeTokenUsageRecord.deleteOne(db, key: id.uuidString)
             }
         }
     }
     ```
  4. Wire `public let claudeTokenUsage: ClaudeTokenUsageStore` into `TBDDatabase` (both inits).
  5. Run `swift test --filter ClaudeTokenUsageStoreTests`. Expected: 3 pass.
  6. Commit: `feat: add ClaudeTokenUsageStore with upsert, get, delete, cascade-on-token-delete`.

---

### 5. `ConfigStore` singleton

- [ ] **Files**
  - Create: `Sources/TBDDaemon/Database/ConfigStore.swift`
  - Modify: `Sources/TBDDaemon/Database/Database.swift` (wire `config`)
  - Test: `Tests/TBDDaemonTests/ConfigStoreTests.swift` (new)

- [ ] **Steps**
  1. Write failing test:
     ```swift
     import Testing
     import Foundation
     @testable import TBDDaemonLib
     @testable import TBDShared

     @Suite("ConfigStore")
     struct ConfigStoreTests {
         @Test func defaultsToNil() async throws {
             let db = try TBDDatabase(inMemory: true)
             let cfg = try await db.config.get()
             #expect(cfg.defaultClaudeTokenID == nil)
         }

         @Test func setAndGetDefaultClaudeTokenID() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
             try await db.config.setDefaultClaudeTokenID(tok.id)
             let cfg = try await db.config.get()
             #expect(cfg.defaultClaudeTokenID == tok.id)
         }

         @Test func clearDefaultClaudeTokenID() async throws {
             let db = try TBDDatabase(inMemory: true)
             let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
             try await db.config.setDefaultClaudeTokenID(tok.id)
             try await db.config.setDefaultClaudeTokenID(nil)
             let cfg = try await db.config.get()
             #expect(cfg.defaultClaudeTokenID == nil)
         }
     }
     ```
  2. Run and verify failure.
  3. Create `Sources/TBDDaemon/Database/ConfigStore.swift`:
     ```swift
     import Foundation
     import GRDB
     import TBDShared

     struct ConfigRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
         static let databaseTableName = "config"

         var id: String
         var default_claude_token_id: String?

         func toModel() -> Config {
             Config(
                 defaultClaudeTokenID: default_claude_token_id.flatMap(UUID.init(uuidString:))
             )
         }
     }

     public struct ConfigStore: Sendable {
         static let singletonID = "singleton"
         let writer: any DatabaseWriter

         init(writer: any DatabaseWriter) {
             self.writer = writer
         }

         public func get() async throws -> Config {
             try await writer.read { db in
                 try ConfigRecord.fetchOne(db, key: Self.singletonID)?.toModel() ?? Config()
             }
         }

         public func setDefaultClaudeTokenID(_ id: UUID?) async throws {
             try await writer.write { db in
                 try db.execute(
                     sql: "UPDATE config SET default_claude_token_id = ? WHERE id = ?",
                     arguments: [id?.uuidString, Self.singletonID]
                 )
             }
         }
     }
     ```
  4. Wire `public let config: ConfigStore` into `TBDDatabase` (both inits).
  5. Run `swift test --filter ConfigStoreTests`. Expected: 3 pass.
  6. Commit: `feat: add ConfigStore singleton for default Claude token ID`.

---

### 6. `RepoStore.setClaudeTokenOverride` + round-trip through `RepoRecord`

- [ ] **Files**
  - Modify: `Sources/TBDDaemon/Database/RepoStore.swift`
  - Test: extend `Tests/TBDDaemonTests/ClaudeTokenStoreTests.swift`

- [ ] **Steps**
  1. Write failing test (append to `ClaudeTokenStoreTests`):
     ```swift
     @Test func repoOverrideRoundTrip() async throws {
         let db = try TBDDatabase(inMemory: true)
         let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
         let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
         #expect(repo.claudeTokenOverrideID == nil)

         try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: tok.id)
         let fetched = try await db.repos.get(id: repo.id)
         #expect(fetched?.claudeTokenOverrideID == tok.id)

         try await db.repos.setClaudeTokenOverride(id: repo.id, tokenID: nil)
         let cleared = try await db.repos.get(id: repo.id)
         #expect(cleared?.claudeTokenOverrideID == nil)
     }
     ```
  2. Run and verify failure.
  3. Modify `RepoRecord` in `RepoStore.swift`:
     - Add `var claude_token_override_id: String?`.
     - Update `init(from repo:)` to set it from `repo.claudeTokenOverrideID?.uuidString`.
     - Update `toModel()` to pass `claudeTokenOverrideID: claude_token_override_id.flatMap(UUID.init(uuidString:))`.
  4. Add to `RepoStore`:
     ```swift
     public func setClaudeTokenOverride(id: UUID, tokenID: UUID?) async throws {
         try await writer.write { db in
             try db.execute(
                 sql: "UPDATE repo SET claude_token_override_id = ? WHERE id = ?",
                 arguments: [tokenID?.uuidString, id.uuidString]
             )
         }
     }
     ```
  5. Run `swift test --filter ClaudeTokenStoreTests/repoOverrideRoundTrip`. Expected: pass.
  6. Run full `swift test` to check no regressions in existing repo tests.
  7. Commit: `feat: round-trip claude_token_override_id on repo and add setClaudeTokenOverride`.

---

### 7. `TerminalStore.setClaudeTokenID` + round-trip through `TerminalRecord`

- [ ] **Files**
  - Modify: `Sources/TBDDaemon/Database/TerminalStore.swift`
  - Test: extend `Tests/TBDDaemonTests/ClaudeTokenStoreTests.swift`

- [ ] **Steps**
  1. Write failing test:
     ```swift
     @Test func terminalTokenIDRoundTrip() async throws {
         let db = try TBDDatabase(inMemory: true)
         let tok = try await db.claudeTokens.create(name: "Personal", kind: .oauth)
         let repo = try await db.repos.create(path: "/tmp/r2", displayName: "r2", defaultBranch: "main")
         let wt = try await db.worktrees.create(
             repoID: repo.id, name: "w", branch: "tbd/w",
             path: "/tmp/r2/.tbd/worktrees/w", tmuxServer: "tbd-test"
         )
         let term = try await db.terminals.create(
             worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
         )
         #expect(term.claudeTokenID == nil)

         try await db.terminals.setClaudeTokenID(id: term.id, tokenID: tok.id)
         let fetched = try await db.terminals.get(id: term.id)
         #expect(fetched?.claudeTokenID == tok.id)

         try await db.terminals.setClaudeTokenID(id: term.id, tokenID: nil)
         let cleared = try await db.terminals.get(id: term.id)
         #expect(cleared?.claudeTokenID == nil)
     }
     ```
  2. Run and verify failure.
  3. Modify `TerminalRecord` in `TerminalStore.swift`:
     - Add `var claude_token_id: String?`.
     - Update `init(from terminal:)` to set it from `terminal.claudeTokenID?.uuidString`.
     - Update `toModel()` to pass `claudeTokenID: claude_token_id.flatMap(UUID.init(uuidString:))`.
  4. Extend `TerminalStore.create` to accept `claudeTokenID: UUID? = nil` and pass through to the model. (Default `nil` keeps existing call sites compiling.)
  5. Add to `TerminalStore`:
     ```swift
     public func setClaudeTokenID(id: UUID, tokenID: UUID?) async throws {
         try await writer.write { db in
             try db.execute(
                 sql: "UPDATE terminal SET claude_token_id = ? WHERE id = ?",
                 arguments: [tokenID?.uuidString, id.uuidString]
             )
         }
     }
     ```
  6. Run `swift test --filter ClaudeTokenStoreTests/terminalTokenIDRoundTrip`. Expected: pass.
  7. Run full `swift test`. Expected: all green.
  8. Commit: `feat: round-trip claude_token_id on terminal and add setClaudeTokenID`.

---

### 8. Migration-on-existing-DB safety check

- [ ] **Files**
  - Test: extend `Tests/TBDDaemonTests/ClaudeTokenMigrationTests.swift`

- [ ] **Steps**
  1. Add a test that simulates an upgrade by creating a DB, populating a repo + terminal, closing it, reopening, and verifying the new columns are accessible and existing rows still decode:
     ```swift
     @Test func migrationPreservesExistingRowsAndAddsColumns() async throws {
         // Use a temp file (not :memory:) so the DB persists across reopen.
         let tmp = NSTemporaryDirectory() + "tbd-mig-test-\(UUID().uuidString).db"
         defer { try? FileManager.default.removeItem(atPath: tmp) }

         do {
             let db = try TBDDatabase(path: tmp)
             let repo = try await db.repos.create(path: "/tmp/x", displayName: "x", defaultBranch: "main")
             let wt = try await db.worktrees.create(
                 repoID: repo.id, name: "w", branch: "tbd/w",
                 path: "/tmp/x/.tbd/worktrees/w", tmuxServer: "tbd-test"
             )
             _ = try await db.terminals.create(
                 worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
             )
         }

         // Reopen — migrator must be a no-op past v13 and rows must decode.
         let db2 = try TBDDatabase(path: tmp)
         let repos = try await db2.repos.list()
         #expect(repos.count == 1)
         #expect(repos[0].claudeTokenOverrideID == nil)
         let terms = try await db2.terminals.list()
         #expect(terms.count == 1)
         #expect(terms[0].claudeTokenID == nil)
         let cfg = try await db2.config.get()
         #expect(cfg.defaultClaudeTokenID == nil)
     }
     ```
  2. Run `swift test --filter ClaudeTokenMigrationTests`. Expected: all pass.
  3. Run full `swift test`. Expected: all green.
  4. Commit: `test: verify v13 migration preserves existing rows and exposes new columns on reopen`.

---

## Phase exit checklist

- [ ] `swift build` clean
- [ ] `swift test` all green
- [ ] All 8 tasks committed in order
- [ ] No source files outside `Sources/TBDShared/Models.swift` and `Sources/TBDDaemon/Database/` modified
- [ ] No RPC, spawn, Keychain, UI, or fetcher code touched (those are later phases)
- [ ] New optional fields confirmed backward-compatible via JSON-decode tests in Task 1

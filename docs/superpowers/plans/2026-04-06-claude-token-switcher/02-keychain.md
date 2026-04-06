# Phase 02: Keychain Wrapper

> **Parent plan:** [../2026-04-06-claude-token-switcher.md](../2026-04-06-claude-token-switcher.md)
> **Depends on:** Phase 01 (only for knowing the UUID-as-account convention; no code dep)
> **Unblocks:** Phase 04 (token resolver), Phase 05 (CRUD RPC)

**Scope:** A thin `ClaudeTokenKeychain` enum wrapping `SecItem` APIs for secure token storage. Upsert via delete+add; default accessibility; no biometric gate.

---

## Conventions

- Swift Testing (`@Suite`, `@Test`, `#expect`) — see `Tests/TBDDaemonTests/DatabaseTests.swift`.
- Tests use unique random UUID per `id` and clean up via `defer { try? ClaudeTokenKeychain.delete(id: id) }`. No test-only API surface.
- Real login keychain is used; cleanup is mandatory.

---

## Task 1 — Write failing tests

- [ ] Create `Tests/TBDDaemonTests/ClaudeTokenKeychainTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemon

@Suite("ClaudeTokenKeychain")
struct ClaudeTokenKeychainTests {

    private func freshID() -> String {
        "test-\(UUID().uuidString)"
    }

    @Test("store + load round-trip")
    func roundTrip() throws {
        let id = freshID()
        defer { try? ClaudeTokenKeychain.delete(id: id) }

        try ClaudeTokenKeychain.store(id: id, token: "sk-ant-secret-A")
        let loaded = try ClaudeTokenKeychain.load(id: id)
        #expect(loaded == "sk-ant-secret-A")
    }

    @Test("store overwrites existing (upsert)")
    func upsert() throws {
        let id = freshID()
        defer { try? ClaudeTokenKeychain.delete(id: id) }

        try ClaudeTokenKeychain.store(id: id, token: "value-A")
        try ClaudeTokenKeychain.store(id: id, token: "value-B")
        let loaded = try ClaudeTokenKeychain.load(id: id)
        #expect(loaded == "value-B")
    }

    @Test("delete removes item")
    func deleteRemoves() throws {
        let id = freshID()
        defer { try? ClaudeTokenKeychain.delete(id: id) }

        try ClaudeTokenKeychain.store(id: id, token: "to-be-deleted")
        try ClaudeTokenKeychain.delete(id: id)
        let loaded = try ClaudeTokenKeychain.load(id: id)
        #expect(loaded == nil)
    }

    @Test("delete of nonexistent id is idempotent")
    func deleteIdempotent() throws {
        let id = freshID()
        // No store; delete should not throw.
        try ClaudeTokenKeychain.delete(id: id)
    }

    @Test("load of nonexistent id returns nil")
    func loadMissing() throws {
        let id = freshID()
        let loaded = try ClaudeTokenKeychain.load(id: id)
        #expect(loaded == nil)
    }
}
```

- [ ] Confirm tests fail to compile (symbol missing): `swift test 2>&1 | head -40`

---

## Task 2 — Implement `ClaudeTokenKeychain.swift`

- [ ] Create `Sources/TBDDaemon/Keychain/ClaudeTokenKeychain.swift`:

```swift
import Foundation
import Security

public enum ClaudeTokenKeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataEncoding
}

public enum ClaudeTokenKeychain {
    public static let service = "app.tbd.claude-token"

    /// Base query identifying a single item by (service, account).
    private static func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    /// Upsert a token. Implements delete+add because SecItemAdd returns
    /// errSecDuplicateItem on existing entries.
    public static func store(id: String, token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw ClaudeTokenKeychainError.dataEncoding
        }

        let base = baseQuery(id: id)

        // Clear any existing item with the same identity. Ignore not-found.
        let deleteStatus = SecItemDelete(base as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw ClaudeTokenKeychainError.unexpectedStatus(deleteStatus)
        }

        var addQuery = base
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ClaudeTokenKeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Returns nil if no item with the given id exists.
    public static func load(id: String) throws -> String? {
        var query = baseQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw ClaudeTokenKeychainError.dataEncoding
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw ClaudeTokenKeychainError.unexpectedStatus(status)
        }
    }

    /// Idempotent; does not throw on missing item.
    public static func delete(id: String) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw ClaudeTokenKeychainError.unexpectedStatus(status)
        }
    }
}
```

- [ ] Build: `swift build`

---

## Task 3 — Run tests

- [ ] `swift test --filter ClaudeTokenKeychainTests`
- [ ] All five tests pass.
- [ ] Verify no leftover `app.tbd.claude-token` test entries: open Keychain Access.app, search "app.tbd.claude-token", expect no `test-<uuid>` accounts. (If any leak, investigate `defer` cleanup before proceeding.)

---

## Task 4 — Commit

- [ ] Stage only the two new files:

```bash
git add Sources/TBDDaemon/Keychain/ClaudeTokenKeychain.swift Tests/TBDDaemonTests/ClaudeTokenKeychainTests.swift
```

- [ ] Commit:

```bash
git commit -m "feat: add ClaudeTokenKeychain wrapper for secure token storage"
```

---

## Acceptance

- `Sources/TBDDaemon/Keychain/ClaudeTokenKeychain.swift` exists with `store` / `load` / `delete` matching the spec.
- Service constant is `app.tbd.claude-token`; account field is the passed `id`.
- `store` uses delete+add upsert pattern with a shared base query.
- `load` returns nil on `errSecItemNotFound`; throws `unexpectedStatus` otherwise.
- `delete` is idempotent on missing items.
- Five Swift Testing cases pass; no Keychain pollution remains.
- `swift build` and `swift test` are clean.

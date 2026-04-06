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

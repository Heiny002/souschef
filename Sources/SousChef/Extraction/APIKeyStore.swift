import Foundation
import Security

/// Minimal Keychain wrapper for a single string secret (generic password).
enum KeychainStore {
    @discardableResult
    static func set(_ value: String?, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace any existing item.
        SecItemDelete(base as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            return true   // clearing is a successful no-op
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

/// Single source of truth for the Anthropic API key used by the LLM extraction layers.
///
/// Precedence:
/// 1. A user-supplied key stored in the Keychain (Settings → API Key).
/// 2. In DEBUG only, a build-injected key from `Info.plist` (via `Secrets.xcconfig`) so CI
///    and local development keep working.
///
/// Release builds never read a bundled key, so no shared provider key ships in the IPA
/// (audit C6) — each user supplies their own.
enum APIKeyProvider {
    private static let service = "com.souschef.app"
    private static let account = "anthropic-api-key"

    /// The effective key to use for LLM calls, or nil when none is configured.
    static var anthropicKey: String? {
        if let userKey = KeychainStore.get(service: service, account: account),
           !userKey.isEmpty {
            return userKey
        }
        #if DEBUG
        if let bundled = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String,
           !bundled.isEmpty {
            return bundled
        }
        #endif
        return nil
    }

    /// Whether the user has stored their own key (independent of the DEBUG bundled fallback).
    static var hasUserKey: Bool {
        guard let key = KeychainStore.get(service: service, account: account) else { return false }
        return !key.isEmpty
    }

    /// Store (or overwrite) the user's key. Whitespace is trimmed; empty clears it.
    @discardableResult
    static func setUserKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeychainStore.set(trimmed.isEmpty ? nil : trimmed, service: service, account: account)
    }

    /// Remove the user's stored key.
    static func clearUserKey() {
        KeychainStore.set(nil, service: service, account: account)
    }

    /// Lightweight shape check for the Settings UI (an Anthropic key looks like `sk-ant-…`).
    static func looksValid(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count >= 20
    }
}

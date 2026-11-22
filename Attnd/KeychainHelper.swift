// KeychainHelper.swift
// Attnd
//
// Minimal Keychain read/write/delete for storing sensitive strings (e.g. attestation JWTs).

import Foundation
import Security

enum KeychainHelper {

    /// Values read or written this run (perf, batch 7: `SecItemCopyMatching` took ~7 ms on the
    /// main thread at every read). `nil` in the cache = looked up and absent.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    private static func cached(_ key: String) -> String?? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    private static func remember(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = .some(value)
    }

    /// Write `value` to the Keychain under `key`, replacing any existing entry.
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first so SecItemAdd doesn't get errSecDuplicateItem
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrAccount as String:     key,
            kSecValueData as String:       data,
            // Token is needed immediately after first unlock (e.g. background refresh)
            kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let saved = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        remember(key, saved ? value : nil)
        return saved
    }

    /// Read the string stored under `key`, or nil if absent.
    static func read(key: String) -> String? {
        if let hit = cached(key) { return hit }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // Only a definite "not found" is remembered (a locked keychain is asked again).
            if status == errSecItemNotFound { remember(key, nil) }
            return nil
        }
        let value = String(data: data, encoding: .utf8)
        remember(key, value)
        return value
    }

    /// Delete the item stored under `key`. Returns true if deleted, false if not found.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        remember(key, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

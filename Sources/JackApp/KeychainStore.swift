import Foundation
import Security

/// Small wrapper over the login keychain for the one secret Jack holds.
///
/// The OpenRouter key used to live in `UserDefaults`, which was wrong twice
/// over: the plist is world-readable by any process running as the user, and
/// the Settings field writes straight through on every keystroke — so a
/// dictation that landed while Jack's own Settings window had focus silently
/// overwrote the key with the transcript. The keychain fixes the first problem;
/// `DictationController`'s frontmost-app paste guard fixes the second.
enum KeychainStore {

    /// Account name for the OpenRouter key item.
    static let openRouterAPIKeyAccount = "openrouter_api_key"

    /// Keychain items are scoped per bundle id so a debug build and a release
    /// build don't fight over one item. The fallback matches the release id
    /// rather than something invented, because a build with no bundle id is
    /// running from the command line against the user's real settings.
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.jack.app.v2"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns nil for both "no item" and "item is unreadable" — callers treat
    /// an unreadable key exactly like a missing one, which is the safe default.
    static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            if status != errSecSuccess, status != errSecItemNotFound {
                NSLog("[Jack] Keychain read failed for %@: OSStatus %d", account, Int(status))
            }
            return nil
        }
        return value
    }

    /// Writing an empty string deletes the item, so "cleared the field in
    /// Settings" and "no key" are the same state rather than an empty item that
    /// reads back as a key.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account: account) }
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(account: account)
        let updates: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // The key is only needed while the user is logged in and Jack is
            // running; it never has to survive a locked screen unattended.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[Jack] Keychain add failed for %@: OSStatus %d", account, Int(addStatus))
            }
            return addStatus == errSecSuccess
        }

        NSLog("[Jack] Keychain update failed for %@: OSStatus %d", account, Int(updateStatus))
        return false
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Migration

/// Pure decision logic for moving the key out of `UserDefaults`, split from the
/// keychain calls so it can be tested without touching a real keychain.
enum OpenRouterKeyMigration {

    /// OpenRouter issues `sk-or-v1-…`. This is deliberately a shape check and
    /// not a validity check — it exists to recognise a *destroyed* stored value,
    /// not to police what the user types.
    static func looksLikeAPIKey(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-or-") else { return false }
        guard trimmed.count >= 20 else { return false }
        // A real key has no whitespace anywhere in it; a dictation always will
        // eventually, and this is the cheapest way to tell them apart.
        return !trimmed.contains(where: { $0.isWhitespace })
    }

    /// What to do with whatever is sitting in `UserDefaults` at launch.
    enum Outcome: Equatable {
        /// Keychain already holds a key; drop the legacy copy unread.
        case keychainWins
        /// Legacy value looks like a real key — move it, then drop it.
        case migrate(String)
        /// Legacy value is corrupt or absent — drop it and start with no key.
        case discard
    }

    static func plan(keychainValue: String?, legacyValue: String?) -> Outcome {
        if let keychainValue, !keychainValue.isEmpty { return .keychainWins }
        guard let legacyValue, !legacyValue.isEmpty else { return .discard }
        return looksLikeAPIKey(legacyValue) ? .migrate(legacyValue) : .discard
    }
}

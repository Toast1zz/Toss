import Foundation
import Security

/// Generic-password items in the login keychain, scoped to this bundle id.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "app.toast.toss" }

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(_ account: String) -> String? {
        data(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func set(_ data: Data, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Toss (\(account))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ string: String, for account: String) -> Bool {
        set(Data(string.utf8), for: account)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Telegram API credentials from my.telegram.org.
struct APICredentials: Equatable {
    var apiID: Int32
    var apiHash: String

    private static let idAccount = "api_id"
    private static let hashAccount = "api_hash"

    static func load() -> APICredentials? {
        guard let idString = Keychain.string(idAccount), let id = Int32(idString),
              let hash = Keychain.string(hashAccount), !hash.isEmpty else { return nil }
        return APICredentials(apiID: id, apiHash: hash)
    }

    func save() -> Bool {
        Keychain.set(String(apiID), for: Self.idAccount) && Keychain.set(apiHash, for: Self.hashAccount)
    }

    static func remove() {
        Keychain.remove(idAccount)
        Keychain.remove(hashAccount)
    }
}

/// Key that encrypts the local TDLib database (which holds the session).
enum DatabaseKey {
    private static let account = "database_key"

    static func loadOrCreate() -> Data {
        if let existing = Keychain.data(account), existing.count == 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes)
        Keychain.set(key, for: account)
        return key
    }

    static func remove() { Keychain.remove(account) }
}

enum CredentialImport {
    static func run(path: String?) -> Int32 {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("usage: Toss --import-credentials <env file>\n".utf8))
            return 2
        }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if parts.count == 2 { values[parts[0].replacingOccurrences(of: "export ", with: "")] = parts[1] }
        }
        guard let id = values["TELEGRAM_API_ID"].flatMap(Int32.init),
              let hash = values["TELEGRAM_API_HASH"], !hash.isEmpty else {
            FileHandle.standardError.write(Data("TELEGRAM_API_ID / TELEGRAM_API_HASH missing or invalid\n".utf8))
            return 1
        }
        guard APICredentials(apiID: id, apiHash: hash).save() else {
            FileHandle.standardError.write(Data("Couldn't write to Keychain\n".utf8))
            return 1
        }
        print("Saved API credentials to Keychain for \(Bundle.main.bundleIdentifier ?? "Toss").")
        return 0
    }
}

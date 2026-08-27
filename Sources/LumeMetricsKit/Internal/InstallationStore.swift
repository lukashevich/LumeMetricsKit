import Foundation
import Security

/// What the SDK remembers about this installation. Persisted in the Keychain.
struct InstallationRecord: Codable, Sendable, Equatable {
    /// Anonymous, SDK-generated UUID. Not derived from any device or user identifier.
    var installationId: String
    /// `true` once a `firstOpen` event has been committed for this installation.
    var firstOpenRecorded: Bool
    /// Newest `CFBundleVersion` an event has been committed for.
    var lastRecordedBuild: String?
}

protocol InstallationStore: Sendable {
    /// Returns the stored record, or `nil` when this is a new installation.
    /// Throws when the store is unreadable — the caller must not assume "new installation" then.
    func load() throws -> InstallationRecord?
    func save(_ record: InstallationRecord) throws
}

enum InstallationStoreError: Error {
    case keychain(OSStatus)
}

/// Keychain-backed store.
///
/// Uses a single generic-password item so the record survives app updates and, on iOS,
/// app reinstalls — which is what makes `firstOpen` reliably once-per-installation.
struct KeychainInstallationStore: InstallationStore {

    private let service: String
    private let account: String

    init(service: String, account: String = "installation") {
        self.service = "\(service).LumeMetricsKit"
        self.account = account
    }

    func load() throws -> InstallationRecord? {
        #if os(macOS)
        // An unentitled process cannot see the data-protection keychain and is told the item
        // simply does not exist, so both keychains have to be consulted. Checking the modern one
        // first also migrates records written by an entitled build of the same app.
        var firstError: Error?
        for useDataProtection in [true, false] {
            do {
                if let record = try loadRecord(useDataProtection: useDataProtection) {
                    return record
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return nil
        #else
        return try loadRecord(useDataProtection: true)
        #endif
    }

    private func loadRecord(useDataProtection: Bool) throws -> InstallationRecord? {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            // A record we cannot decode is treated as absent; `save` overwrites it.
            return try? JSONDecoder().decode(InstallationRecord.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw InstallationStoreError.keychain(status)
        }
    }

    func save(_ record: InstallationRecord) throws {
        let data = try JSONEncoder().encode(record)

        try withKeychainFallback { useDataProtection in
            var attributes = baseQuery(useDataProtection: useDataProtection)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                let updateStatus = SecItemUpdate(
                    baseQuery(useDataProtection: useDataProtection) as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard updateStatus == errSecSuccess else {
                    throw InstallationStoreError.keychain(updateStatus)
                }
            default:
                throw InstallationStoreError.keychain(addStatus)
            }
        }
    }

    private func baseQuery(useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // Prefer the modern keychain so behaviour matches iOS and no legacy UI can appear.
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    /// Runs a keychain operation, retrying against the legacy macOS keychain when the process
    /// lacks the entitlement for the data-protection one (unsigned or ad-hoc signed Mac builds).
    private func withKeychainFallback<Value>(
        _ operation: (_ useDataProtection: Bool) throws -> Value
    ) throws -> Value {
        #if os(macOS)
        do {
            return try operation(true)
        } catch InstallationStoreError.keychain(errSecMissingEntitlement) {
            return try operation(false)
        }
        #else
        return try operation(true)
        #endif
    }
}

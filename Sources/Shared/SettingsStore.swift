import Foundation
import Combine
import Security
#if canImport(WatchAICore)
import WatchAICore
#endif

enum SecureKeyStore {
    private static let service = "com.watchai.doubao.credentials"
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func read(account: String = "speech-api-key") -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ value: String, account: String = "speech-api-key") throws {
        let query = query(account: account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw StoreError.keychain }
        } else if status != errSecSuccess { throw StoreError.keychain }
    }
    enum StoreError: LocalizedError {
        case keychain
        var errorDescription: String? { "API Key 无法安全保存，请解锁设备后重试。" }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var apiKey = ""
    @Published private(set) var searchAPIKey = ""
    @Published private(set) var isLoading = true
    private var credentialTask: Task<(String, String), Never>?
    private let credentialReader: @Sendable () -> (String, String)
    private let defaults: UserDefaults
    private let migratesTurnSettings: Bool
    @Published private(set) var settings: VoiceSettings
    @Published var error: String?
    var isConfigured: Bool { !apiKey.isEmpty }

    init(defaults: UserDefaults = .standard, credentialReader: @escaping @Sendable () -> (String, String) = {
        (SecureKeyStore.read(), SecureKeyStore.read(account: "search-api-key"))
    }) {
        self.defaults = defaults
        self.credentialReader = credentialReader
        let saved = defaults.data(forKey: "voice-settings")
        let oldFields = saved.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        migratesTurnSettings = oldFields?["conversationMode"] as? String == "turn"
        settings = saved
            .flatMap { try? JSONDecoder().decode(VoiceSettings.self, from: $0) } ?? VoiceSettings()
        // Apply the requested new default to already-installed watches once.
        // Subsequent choices remain intact; the key and instructions are preserved.
        let migrationKey = "voice-default-vivi-v1"
        if !defaults.bool(forKey: migrationKey) {
            settings.voice = VoiceSettings.defaultVoice
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: "voice-settings")
                defaults.set(true, forKey: migrationKey)
            }
        }
    }

    func loadCredentials() async {
        guard isLoading else { return }
        if credentialTask == nil {
            credentialTask = Task.detached(priority: .userInitiated, operation: credentialReader)
        }
        guard let credentialTask else { return }
        let (speech, search) = await credentialTask.value
        guard isLoading else { return }
        apiKey = speech; searchAPIKey = search
        // The removed mode used Ark search without a separate search credential.
        // Preserve realtime search when configured; otherwise allow the first call.
        if migratesTurnSettings {
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.webSearchEnabled = false
            }
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: "voice-settings")
            }
        }
        isLoading = false; self.credentialTask = nil
    }

    @discardableResult
    func save(key: String, searchKey: String, settings: VoiceSettings) -> Bool {
        guard !isLoading else { return false }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchKey = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var speechKeyChanged = false
        do {
            try settings.validate(searchAPIKey: searchKey)
            let data = try JSONEncoder().encode(settings)
            if key != apiKey {
                try SecureKeyStore.write(key)
                speechKeyChanged = true
            }
            if searchKey != searchAPIKey { try SecureKeyStore.write(searchKey, account: "search-api-key") }
            defaults.set(data, forKey: "voice-settings")
            apiKey = key
            searchAPIKey = searchKey
            self.settings = settings
            error = nil
            return true
        } catch {
            if speechKeyChanged { try? SecureKeyStore.write(apiKey) }
            self.error = error.localizedDescription
            return false
        }
    }
}

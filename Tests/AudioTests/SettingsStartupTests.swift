import XCTest
@testable import WatchAIAudio
import WatchAICore

final class SettingsStartupTests: XCTestCase {
    @MainActor func testSlowCredentialReadDoesNotBlockInitializationOrMainActor() async {
        let suite = "WatchAI-startup-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults, credentialReader: {
            Thread.sleep(forTimeInterval: 0.1) // Simulate a slow Keychain using fixture values only.
            return ("fixture-speech", "fixture-search")
        })
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(store.apiKey.isEmpty)
        let loading = Task { await store.loadCredentials() }
        // The actor can do UI work while the worker remains blocked.
        await Task.yield()
        XCTAssertTrue(store.isLoading)
        await loading.value
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.apiKey, "fixture-speech")
        XCTAssertEqual(store.searchAPIKey, "fixture-search")
        await store.loadCredentials()
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testRemovedModeMigratesWithoutArkAndDisablesUnconfiguredSearch() async throws {
        try await checkMigration(searchKey: "", expectedSearch: false)
    }

    @MainActor func testRemovedModePreservesConfiguredRealtimeSearch() async throws {
        try await checkMigration(searchKey: "fixture-search", expectedSearch: true)
    }

    @MainActor private func checkMigration(searchKey: String, expectedSearch: Bool) async throws {
        let suite = "WatchAI-migration-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "voice-default-vivi-v1")
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "conversationMode": "turn", "textModel": "old-model", "readingVoice": "old-reading-voice",
            "voice": "zh_male_xiaotian_jupiter_bigtts", "instructions": "保留我的回答风格",
            "bandwidthMode": "compatible", "webSearchEnabled": true, "webSearchType": "web_global_api"
        ]), forKey: "voice-settings")
        let store = SettingsStore(defaults: defaults, credentialReader: { ("fixture-speech", searchKey) })
        await store.loadCredentials()
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.settings.voice, "zh_male_xiaotian_jupiter_bigtts")
        XCTAssertEqual(store.settings.instructions, "保留我的回答风格")
        XCTAssertEqual(store.settings.bandwidthMode, .compatible)
        XCTAssertEqual(store.settings.webSearchType, .global)
        XCTAssertEqual(store.settings.webSearchEnabled, expectedSearch)
        XCTAssertNoThrow(try store.settings.validate(searchAPIKey: store.searchAPIKey))
        let saved = try XCTUnwrap(defaults.data(forKey: "voice-settings"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        for removed in ["conversationMode", "textModel", "readingVoice"] {
            XCTAssertNil(fields[removed])
        }
    }
}

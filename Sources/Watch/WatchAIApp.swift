import SwiftUI

@main
struct WatchAIApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var conversation = ConversationModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchHomeView(store: settings, model: conversation)
                .tint(Theme.mint)
                .preferredColorScheme(.dark)
                .task { await settings.loadCredentials() }
                .onChange(of: scenePhase) { _, phase in
                    // The first release is an explicit foreground conversation, with no hidden recording.
                    if phase == .background { conversation.end() }
                }
        }
    }
}

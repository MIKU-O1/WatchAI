import Foundation

@main
struct RealtimeSmoke {
    @MainActor
    static func main() async throws {
        let client = RealtimeClient(endpoint: URL(string: CommandLine.arguments[1])!,
                                    preferSystemTransport: CommandLine.arguments.contains("--system"))
        let rejection = CommandLine.arguments.contains("--reject")
        var progress: [String] = []
        var completed = false
        var failure: String?
        client.onProgress = { progress.append($0) }
        client.onFailure = { failure = $0; completed = true }
        client.onEvent = { event in
            if event.type == "session.created" { client.close() }
            if event.type == "session.closed" { completed = true }
        }
        try client.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        defer { client.shutdown() }
        let deadline = Date().addingTimeInterval(18)
        while !completed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard completed else { throw NSError(domain: "RealtimeSmokeTimeout", code: 1) }
        if rejection {
            guard let failure, !failure.contains("local-fixture-key"),
                  !progress.contains("正在创建豆包会话"), failure.contains("HTTP 401") else {
                throw NSError(domain: "RealtimeSmokeMissingSafeFailure", code: 2)
            }
            print("PASS: rejected WebSocket reports failure instead of waiting for a voice session")
        } else {
            guard failure == nil, progress.contains("正在创建豆包会话") else {
                throw NSError(domain: "RealtimeSmokeSessionFailure", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: failure ?? "No session progress"])
            }
            if CommandLine.arguments.contains("--fallback"), !progress.contains("正在尝试备用连接") {
                throw NSError(domain: "RealtimeSmokeMissingFallback", code: 4)
            }
            print("PASS: ready handshake, session.create, session.created and graceful close")
        }
    }
}

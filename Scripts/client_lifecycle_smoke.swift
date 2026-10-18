import Foundation

private final class LifecycleSocket: VoiceWebSocket, @unchecked Sendable {
    enum Mode { case healthy, serverErrorAfterSendError, disconnected, waiting, rejectHandshake, serverTemporaryError, forbidden, recoverWaiting }
    private let mode: Mode
    private let state: @Sendable (NetworkWebSocket.State) -> Void
    private let queue = DispatchQueue(label: "com.watchai.lifecycle-test")
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var audioCount = 0
    private let onSession: (@Sendable (String) -> Void)?

    init(mode: Mode, state: @escaping @Sendable (NetworkWebSocket.State) -> Void,
         onSession: (@Sendable (String) -> Void)? = nil) {
        self.mode = mode; self.state = state; self.onSession = onSession
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }
    func resume() {
        if mode == .rejectHandshake { state(.failed("fixture handshake rejection")) }
        else if mode == .forbidden { state(.failed("HTTP 403 fixture rejection")) }
        else { state(.ready) }
    }
    func cancel() { continuation.finish() }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CancellationError() }
        return data
    }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            let object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            switch object["type"] as? String {
            case "session.create":
                self.onSession?(text)
                self.continuation.yield(Data("{\"type\":\"session.created\",\"session\":{\"id\":\"fixture-dialog\"}}".utf8))
                completion(nil)
            case "session.close":
                self.continuation.yield(Data("{\"type\":\"session.closed\"}".utf8))
                completion(nil)
            case "input_audio_buffer.append":
                self.audioCount += 1
                let error = NSError(domain: NSPOSIXErrorDomain, code: 57,
                    userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"])
                switch self.mode {
                case .healthy, .rejectHandshake, .forbidden: completion(nil)
                case .serverTemporaryError:
                    self.continuation.yield(Data("{\"type\":\"error\",\"error\":{\"code\":503,\"message\":\"fixture temporary error\"}}".utf8))
                    completion(nil)
                case .recoverWaiting:
                    self.state(.waiting("fixture temporary wait")); completion(nil)
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(80)) { self.state(.ready) }
                case .serverErrorAfterSendError:
                    completion(error)
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(30)) {
                        self.continuation.yield(Data("{\"type\":\"error\",\"error\":{\"code\":45000001,\"message\":\"InvalidAudio local-fixture-key local-search-fixture-key\"}}".utf8))
                    }
                case .disconnected:
                    // The second pending packet completes after the next call starts.
                    let delay = self.audioCount == 1 ? 20 : 600
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { completion(error) }
                case .waiting:
                    self.state(.waiting("No route to host")); completion(nil)
                }
            default: completion(nil)
            }
        }
    }
}

@main
struct ClientLifecycleSmoke {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { throw NSError(domain: "LifecycleTimeout", code: 1) }
    }

    @MainActor
    static func main() async throws {
        var paths: [Bool] = []
        let provider = RealtimeClient(transportFactory: { system, state in
            paths.append(system)
            return LifecycleSocket(mode: .serverErrorAfterSendError, state: state)
        })
        var failures: [String] = []
        provider.onFailure = { failures.append($0) }
        try provider.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { provider.isReady }
        provider.sendAudio(Data(count: 640))
        try await waitFor { !failures.isEmpty }
        guard failures.count == 1, failures[0].contains("45000001"), failures[0].contains("InvalidAudio"),
              !failures[0].contains("local-fixture-key"), paths == [false] else {
            throw NSError(domain: "LostServerError", code: 2)
        }
        print("PASS: server error survives a prior send failure; key is redacted; no automatic second session")


        var searchSettings = VoiceSettings()
        searchSettings.webSearchEnabled = true
        var searchPaths: [Bool] = []
        var requests: [String] = []
        var searchFailures: [String] = []
        let searching = RealtimeClient(transportFactory: { system, state in
            searchPaths.append(system)
            return LifecycleSocket(mode: system ? .serverErrorAfterSendError : .rejectHandshake, state: state,
                onSession: { text in Task { @MainActor in requests.append(text) } })
        })
        do {
            try searching.connect(apiKey: "local-fixture-key", settings: searchSettings)
            throw NSError(domain: "MissingSearchKeyAccepted", code: 6)
        } catch ProtocolError.missingSearchKey { }
        guard searchPaths.isEmpty else { throw NSError(domain: "SocketOpenedWithoutSearchKey", code: 7) }
        searching.onFailure = { searchFailures.append($0) }
        try searching.connect(apiKey: "local-fixture-key", settings: searchSettings, searchAPIKey: "local-search-fixture-key")
        try await waitFor { searching.isReady && requests.count == 1 }
        let request = try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as! [String: Any]
        let extra = ((request["extension"] as! [String: Any])["dialog"] as! [String: Any])["extra"] as! [String: Any]
        guard searchPaths == [false, true], extra["enable_volc_websearch"] as? Bool == true,
              extra["volc_websearch_api_key"] as? String == "local-search-fixture-key",
              extra["volc_websearch_type"] as? String == "web_custom_api" else {
            throw NSError(domain: "SearchCredentialsLostOnFallback", code: 8)
        }
        searching.sendAudio(Data(count: 640))
        try await waitFor { !searchFailures.isEmpty }
        guard searchFailures.count == 1, !searchFailures[0].contains("local-fixture-key"),
              !searchFailures[0].contains("local-search-fixture-key"), searchPaths == [false, true] else {
            throw NSError(domain: "SearchKeyExposed", code: 9)
        }
        print("PASS: missing search key opens no socket; fallback preserves search configuration; both keys are redacted")

        for mode in [LifecycleSocket.Mode.disconnected, .waiting, .serverTemporaryError] {
            paths = []; failures = []
            var sessions: [String] = []
            let client = RealtimeClient(transportFactory: { system, state in
                paths.append(system)
                return LifecycleSocket(mode: system ? .healthy : mode, state: state,
                    onSession: { text in Task { @MainActor in sessions.append(text) } })
            })
            client.onFailure = { failures.append($0) }
            var recovering = false
            client.onRecovering = { recovering = $0 }
            var closed = false
            client.onEvent = { if $0.type == "session.closed" { closed = true } }
            try client.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
            try await waitFor { client.isReady }
            client.sendAudio(Data(count: 640)); client.sendAudio(Data(count: 640))
            try await waitFor { paths == [false, true] && client.isReady && !recovering && sessions.count == 2 }
            let resumed = try JSONSerialization.jsonObject(with: Data(sessions[1].utf8)) as! [String: Any]
            guard (resumed["session"] as? [String: Any])?["id"] as? String == "fixture-dialog" else {
                throw NSError(domain: "SessionHistoryNotResumed", code: 10)
            }
            try await Task.sleep(nanoseconds: 650_000_000)
            guard failures.isEmpty, client.isReady, paths == [false, true] else {
                throw NSError(domain: "StaleCallbackBrokeAutomaticRecovery", code: 4)
            }
            client.close(); try await waitFor { closed }
            print("PASS: \(mode) auto-reconnects, resumes session ID and ignores stale callbacks")
        }

        var shortWaitPaths = 0
        let shortWait = RealtimeClient(transportFactory: { _, state in
            shortWaitPaths += 1
            return LifecycleSocket(mode: .recoverWaiting, state: state)
        })
        var shortRecovering = false
        shortWait.onRecovering = { shortRecovering = $0 }
        try shortWait.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { shortWait.isReady }
        shortWait.sendAudio(Data(count: 640))
        try await waitFor { shortRecovering }
        try await waitFor { !shortRecovering && shortWait.isReady }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard shortWaitPaths == 1 else { throw NSError(domain: "ShortWaitCreatedAnotherSession", code: 11) }
        shortWait.close()
        print("PASS: short .waiting recovers on the same socket without a second session")

        var deniedPaths = 0
        let denied = RealtimeClient(transportFactory: { _, state in
            deniedPaths += 1; return LifecycleSocket(mode: .forbidden, state: state)
        })
        var deniedFailure: String?
        denied.onFailure = { deniedFailure = $0 }
        try denied.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { deniedFailure != nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard deniedPaths == 1 else { throw NSError(domain: "RetriesForbiddenKey", code: 12) }
        print("PASS: HTTP 403 stops automatic retry")

        var onlinePaths = 0
        let offline = RealtimeClient(transportFactory: { _, state in
            onlinePaths += 1
            return LifecycleSocket(mode: onlinePaths == 1 ? .waiting : .healthy, state: state)
        })
        try offline.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { offline.isReady }
        offline.networkAvailabilityChanged(available: false)
        offline.sendAudio(Data(count: 640))
        try await Task.sleep(nanoseconds: 400_000_000)
        guard onlinePaths == 1 else { throw NSError(domain: "ReconnectWhileOffline", code: 13) }
        offline.networkAvailabilityChanged(available: true)
        try await waitFor { onlinePaths == 2 && offline.isReady }
        offline.close()
        print("PASS: network restoration wakes backoff immediately without opening sockets while offline")

        var backoffPaths = 0
        let backoff = RealtimeClient(transportFactory: { _, state in
            backoffPaths += 1; return LifecycleSocket(mode: .waiting, state: state)
        })
        var backoffClosed = false
        backoff.onEvent = { if $0.type == "session.closed" { backoffClosed = true } }
        try backoff.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { backoff.isReady }
        backoff.networkAvailabilityChanged(available: false)
        backoff.sendAudio(Data(count: 640))
        try await Task.sleep(nanoseconds: 400_000_000)
        backoff.close()
        backoff.networkAvailabilityChanged(available: true)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        guard backoffPaths == 1, backoffClosed else { throw NSError(domain: "RetryAfterUserEnded", code: 14) }
        print("PASS: closing during backoff cancels timers and later network-restoration callbacks")

        var closePaths = 0
        let closing = RealtimeClient(transportFactory: { _, state in
            closePaths += 1; return LifecycleSocket(mode: .serverErrorAfterSendError, state: state)
        })
        var closeFailure: String?
        var closed = false
        closing.onFailure = { closeFailure = $0 }
        closing.onEvent = { if $0.type == "session.closed" { closed = true } }
        try closing.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        try await waitFor { closing.isReady }
        closing.sendAudio(Data(count: 640))
        try await waitFor { !closing.isReady }
        closing.close()
        try await waitFor { closed }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard closeFailure == nil, closePaths == 1 else { throw NSError(domain: "FailureAfterUserClosed", code: 5) }
        print("PASS: user close cancels deferred connection failure")
    }
}

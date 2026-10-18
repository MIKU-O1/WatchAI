import Foundation

/// A healthy transport whose completion notifications take 800 ms. The wire
/// accepts ordered writes immediately, as it can when callbacks cross processes.
private final class DelayedCompletionSocket: VoiceWebSocket, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.watchai.send-test")
    private let state: @Sendable (NetworkWebSocket.State) -> Void
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var sent: [String] = []
    private let holdCompletions: Bool
    private let delayMs: Int

    init(holdCompletions: Bool = false, delayMs: Int = 800, state: @escaping @Sendable (NetworkWebSocket.State) -> Void) {
        self.state = state
        self.holdCompletions = holdCompletions
        self.delayMs = delayMs
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }
    func resume() { state(.ready) }
    func cancel() { continuation.finish() }
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            self.sent.append(text)
            let object = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            switch object["type"] as? String {
            case "session.create": self.continuation.yield(Data("{\"type\":\"session.created\"}".utf8))
            case "session.close": self.continuation.yield(Data("{\"type\":\"session.closed\"}".utf8))
            default: break
            }
            if !self.holdCompletions {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(self.delayMs)) { completion(nil) }
            }
        }
    }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CancellationError() }
        return data
    }
    func messages() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.sent) }
        }
    }
}

@main
struct BackpressureSmoke {
    @MainActor
    static func main() async throws {
        var socket: DelayedCompletionSocket!
        let client = RealtimeClient(transportFactory: { _, state in
            let transport = DelayedCompletionSocket(state: state)
            socket = transport
            return transport
        })
        var failure: String?
        var closed = false
        client.onFailure = { failure = $0 }
        client.onEvent = { if $0.type == "session.closed" { closed = true } }
        try client.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        while !client.isReady && failure == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        for index in 0..<80 {
            client.sendAudio(Data(repeating: UInt8(index), count: 640))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 850_000_000)
        guard failure == nil else { throw NSError(domain: "SendBackpressure", code: 1) }
        client.close()
        while !closed && failure == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        let messages = await socket.messages()
        let events = try messages.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let audio = events.filter { $0["type"] as? String == "input_audio_buffer.append" }
        guard audio.count == 80, closed else { throw NSError(domain: "LostAudioPackets", code: 2) }
        for (index, event) in audio.enumerated() {
            guard Data(base64Encoded: event["audio"] as! String) == Data(repeating: UInt8(index), count: 640) else {
                throw NSError(domain: "AudioPacketOrder", code: 3)
            }
        }
        print("PASS: 50 packets/sec with 800ms completion delay; all 80 packets preserve order")

        // No completion can grow indefinitely; recovery replaces the stalled socket.
        var stallPaths = 0
        var stalledSocket: DelayedCompletionSocket!
        let stalled = RealtimeClient(transportFactory: { _, state in
            stallPaths += 1
            let socket = DelayedCompletionSocket(holdCompletions: stallPaths == 1, delayMs: 10, state: state)
            if stallPaths == 1 { stalledSocket = socket }
            return socket
        })
        var stallFailure: String?
        stalled.onFailure = { stallFailure = $0 }
        try stalled.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        while !stalled.isReady { try await Task.sleep(nanoseconds: 5_000_000) }
        for _ in 0..<140 { stalled.sendAudio(Data(count: 640)) }
        let deadline = Date().addingTimeInterval(3)
        while (stallPaths < 2 || !stalled.isReady) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let submitted = await stalledSocket.messages()
        guard stallFailure == nil, stallPaths == 2, stalled.isReady, submitted.count <= 100 else {
            throw NSError(domain: "UnboundedSendsOrMissingAutomaticRecovery", code: 4)
        }
        // One unanswered send also triggers time-based recovery without new microphone packets.
        var timeoutPaths = 0
        let timeoutClient = RealtimeClient(transportFactory: { _, state in
            timeoutPaths += 1
            return DelayedCompletionSocket(holdCompletions: timeoutPaths == 1, delayMs: 10, state: state)
        })
        try timeoutClient.connect(apiKey: "local-fixture-key", settings: VoiceSettings())
        while !timeoutClient.isReady { try await Task.sleep(nanoseconds: 5_000_000) }
        timeoutClient.sendAudio(Data(count: 640))
        let timeoutDeadline = Date().addingTimeInterval(4)
        while (timeoutPaths < 2 || !timeoutClient.isReady) && Date() < timeoutDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard timeoutPaths == 2 && timeoutClient.isReady else { throw NSError(domain: "IdleStallWasNeverDetected", code: 5) }
        timeoutClient.close()
        print("PASS: a stalled send recovers after its age limit even when no more audio arrives")

        stalled.close()
        print("PASS: stalled sends remain bounded and recover automatically without user input")
    }
}

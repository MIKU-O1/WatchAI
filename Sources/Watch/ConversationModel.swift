import Foundation
import Combine
import WatchKit

@MainActor
final class ConversationModel: ObservableObject {
    enum State: Equatable {
        case idle, connecting, reconnecting, listening, thinking, speaking, closing, failed
        var label: String {
            switch self {
            case .idle: return "准备好，随时聊"
            case .connecting: return "正在连接豆包"
            case .reconnecting: return "正在自动恢复"
            case .listening: return "我在听"
            case .thinking: return "豆包正在思考"
            case .speaking: return "豆包正在说话"
            case .closing: return "正在结束"
            case .failed: return "连接未完成"
            }
        }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = Transcript()
    @Published private(set) var isMuted = false
    @Published private(set) var isDemo = false
    @Published private(set) var isBuffering = false
    @Published private(set) var networkMetrics = VoiceNetworkMetrics()
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var inputBitRate = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var connectionStatus = "正在启用麦克风"
    @Published var error: String?
    private let client = RealtimeClient()
    private let audio = AudioController()
    private var startTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var runID = UUID()
    private var ignoredResponses: Set<String> = []
    private var currentResponseID: String?
    private var responseFinished = false
    private var playbackActive = false
    private var lastBufferLevelAt: Double = 0
    var messages: [TranscriptMessage] { transcript.messages }
    var isActive: Bool { [.connecting, .reconnecting, .listening, .thinking, .speaking, .closing].contains(state) }
    var canControl: Bool { [.listening, .thinking, .speaking].contains(state) && !isDemo }
    var canInterrupt: Bool { canControl && currentResponseID != nil }
    var networkSummary: String {
        guard !isDemo, inputBitRate > 0 else { return "" }
        return String(format: "上传 %.1f KB/s · 下载 %.1f KB/s\n累计上传 %.1f KB · 下载 %.1f KB\n声音缓冲 %.1f 秒 · 待发送 %.1f KB\n自动重连 %d 次 · 上传编码 %d kbps",
            networkMetrics.uploadBytesPerSecond / 1024, networkMetrics.downloadBytesPerSecond / 1024,
            Double(networkMetrics.uploadedBytes) / 1024, Double(networkMetrics.downloadedBytes) / 1024,
            bufferedSeconds, Double(networkMetrics.pendingBytes) / 1024, networkMetrics.reconnects, inputBitRate / 1000)
    }


    init() {
        client.onEvent = { [weak self] event in self?.receive(event) }
        client.onFailure = { [weak self] message in self?.fail(message) }
        client.onProgress = { [weak self] message in self?.connectionStatus = message }
        client.onMetrics = { [weak self] in self?.networkMetrics = $0 }
        client.onRecovering = { [weak self] recovering in
            guard let self, self.isActive, !self.isDemo, self.state != .closing else { return }
            if recovering {
                self.audio.suspendTransmission()
                self.state = .reconnecting
            } else if self.state == .reconnecting {
                // A brief .waiting recovered without replacing the WebSocket.
                self.audio.beginTransmission()
                self.state = self.playbackActive ? .speaking : .listening
            }
        }
        audio.onControl = { [weak self] in self?.client.control($0) }
        audio.onBufferingChanged = { [weak self] value in
            guard let self, self.isBuffering != value else { return }
            self.isBuffering = value
        }
        audio.onBufferLevel = { [weak self] seconds in
            guard let self, self.bufferedSeconds != seconds else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard seconds == 0 || now - self.lastBufferLevelAt >= 0.5 else { return }
            self.lastBufferLevelAt = now
            self.bufferedSeconds = seconds
        }
        audio.onPacket = { [weak self] packet in
            guard let self, !self.isMuted else { return }
            self.client.sendAudio(packet)
        }
        audio.onLevel = { [weak self] level in self?.level = level }
        audio.onFailure = { [weak self] message in self?.fail(message) }
        audio.onPlaybackChanged = { [weak self] playing in
            guard let self, self.isActive, !self.isDemo, self.state != .closing else { return }
            self.playbackActive = playing
            guard self.state != .reconnecting && self.state != .connecting else { return }
            if playing { self.state = .speaking }
            else {
                if self.responseFinished { self.currentResponseID = nil }
                if self.state == .speaking { self.state = .listening }
            }
        }
    }

    func start(store: SettingsStore) {
        guard !isActive else { return }
        guard store.isConfigured else { error = "请先在手表设置中填写豆包语音 API Key。"; return }
        do { try store.settings.validate(searchAPIKey: store.searchAPIKey) }
        catch { self.error = error.localizedDescription; return }
        error = nil
        transcript.clear()
        isDemo = false; isMuted = false; elapsed = 0
        ignoredResponses.removeAll(); currentResponseID = nil
        responseFinished = false; playbackActive = false; isBuffering = false
        networkMetrics = VoiceNetworkMetrics(); bufferedSeconds = 0
        state = .connecting
        connectionStatus = "正在启用麦克风"
        runID = UUID()
        let token = runID
        let key = store.apiKey
        let searchKey = store.searchAPIKey
        let settings = store.settings
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Activate real audio before using watchOS low-level networking.
                try await self.audio.start(bandwidthMode: settings.bandwidthMode, uploadRate: settings.uploadRate, suppressSilence: settings.suppressSilence)
                self.inputBitRate = self.audio.effectiveInputBitRate
                guard !Task.isCancelled, self.runID == token else { return }
                try self.client.connect(apiKey: key, settings: settings, searchAPIKey: searchKey)
            } catch {
                guard !Task.isCancelled, self.runID == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func end() {
        guard isActive else { return }
        runID = UUID()
        startTask?.cancel(); startTask = nil
        demoTask?.cancel(); demoTask = nil
        clockTask?.cancel(); clockTask = nil
        // Stop capture immediately while giving the server time to acknowledge session.close.
        audio.stop()
        transcript.finishOpenMessages()
        level = 0; isMuted = false
        if isDemo { isDemo = false; state = .idle }
        else if state == .connecting || state == .reconnecting { client.close() ; state = .idle }
        else { state = .closing; client.close() }
    }

    func toggleMute() {
        guard canControl else { return }
        isMuted.toggle()
        audio.setMuted(isMuted)
    }

    func interrupt() {
        guard canInterrupt else { return }
        transcript.interruptAssistant(responseID: currentResponseID)
        ignoreCurrentResponse()
        audio.interruptPlayback()
        client.control("response.cancel")
        state = .listening
        WKInterfaceDevice.current().play(.click)
    }

    func clear() {
        guard !isActive else { return }
        transcript.clear(); error = nil; state = .idle; isDemo = false
    }

    func startDemo() {
        guard !isActive else { return }
        error = nil; transcript.clear(); elapsed = 0
        isDemo = true; state = .listening
        startClock()
        demoTask = Task { [weak self] in
            guard let self else { return }
            let lines: [(String, String, String)] = [
                ("user", "demo-u", "怎么休息十分钟？"),
                ("assistant", "demo-a", "喝点水，活动肩颈，再看看远处。")
            ]
            for (role, id, text) in lines {
                self.state = role == "user" ? .listening : .speaking
                var recognized = ""
                for character in text {
                    guard !Task.isCancelled else { return }
                    recognized.append(character)
                    let type = role == "user" ? "conversation.item.input_audio_transcription.delta" : "response.output_text.delta"
                    let field = role == "user" ? "item_id" : "response_id"
                    if let event = try? ServerEvent(data: JSONSerialization.data(withJSONObject: [
                        "type": type, field: id, "delta": role == "user" ? recognized : String(character)
                    ])) { self.transcript.apply(event) }
                    self.level = Float.random(in: 0.1...0.6)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            self.transcript.finishOpenMessages()
            self.clockTask?.cancel(); self.level = 0; self.state = .idle
            // Keep the demo label visible with its sample transcript.
        }
    }

    private func receive(_ event: ServerEvent) {
        if event.type == "session.closed" {
            audio.stop(); clockTask?.cancel(); state = .idle; return
        }
        guard state != .closing, state != .failed else { return }
        switch event.type {
        case "session.created":
            if state == .reconnecting {
                transcript.interruptAssistant(responseID: currentResponseID)
                transcript.finishOpenMessages()
                audio.interruptPlayback()
                ignoreCurrentResponse()
                responseFinished = false; playbackActive = false
            }
            audio.setMuted(isMuted)
            audio.beginTransmission()
            state = .listening
            startClock()
            WKInterfaceDevice.current().play(.start)
        case "conversation.item.input_audio_transcription.started":
            transcript.interruptAssistant(responseID: currentResponseID)
            ignoreCurrentResponse()
            audio.interruptPlayback()
            if state != .reconnecting { state = .listening }
        case "conversation.item.input_audio_transcription.completed":
            if state != .reconnecting { state = .thinking }
        case "conversation.item.input_audio_transcription.failed":
            fail("没有识别到有效语音，请重新开始后再说一次。")
        case "response.output_text.delta", "response.output_audio.started":
            if let id = event.responseID, !ignoredResponses.contains(id) {
                if currentResponseID != id { responseFinished = false }
                currentResponseID = id
            }
        case "response.output_audio.delta":
            if let id = event.responseID, ignoredResponses.contains(id) { return }
            guard let data = event.audioData else { fail(ProtocolError.invalidAudio.localizedDescription); return }
            do { try audio.play(data, responseID: event.responseID) }
            catch { fail(error.localizedDescription) }
        case "response.output_audio.done":
            if let id = event.responseID, ignoredResponses.contains(id) { return }
            audio.finishPlayback(responseID: event.responseID)
        case "response.done":
            if event.responseID == currentResponseID || (event.responseID == nil && currentResponseID != nil) {
                responseFinished = true
                audio.finishPlayback(responseID: event.responseID)
                if !playbackActive { currentResponseID = nil }
            }
            if state == .thinking { state = .listening }
        default: break
        }
        transcript.apply(event)
    }

    private func ignoreCurrentResponse() {
        if let id = currentResponseID { ignoredResponses.insert(id) }
        currentResponseID = nil
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.elapsed += 1
            }
        }
    }

    private func fail(_ message: String) {
        runID = UUID()
        startTask?.cancel(); demoTask?.cancel(); clockTask?.cancel()
        client.shutdown(); audio.stop()
        transcript.finishOpenMessages()
        error = message; state = .failed; level = 0; isMuted = false; isDemo = false
        WKInterfaceDevice.current().play(.failure)
    }

}

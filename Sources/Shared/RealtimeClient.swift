import Foundation
import Combine
import Network

@MainActor
final class RealtimeClient {
    var onEvent: ((ServerEvent) -> Void)?
    var onFailure: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    var onRecovering: ((Bool) -> Void)?
    var onMetrics: ((VoiceNetworkMetrics) -> Void)?
    private var socket: (any VoiceWebSocket)?
    private var receiver: Task<Void, Never>?
    private var startupTimeout: Task<Void, Never>?
    private var closeTimeout: Task<Void, Never>?
    private var connectionFailureTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var networkUnavailable = false
    private var budget = SendBudget()
    private var metrics = VoiceNetworkMetrics()
    private var lastMetricsAt: Double = 0
    private var lastUploaded = 0
    private var lastDownloaded = 0
    private var retryAttempt = 0
    private var active = false
    private var recovering = false
    private var settings = VoiceSettings()
    private var sessionID = UUID().uuidString
    private(set) var isReady = false
    private var closing = false
    private var apiKey = ""
    private var searchAPIKey = ""
    private var generation = UUID()
    private var callGeneration = UUID()
    private var transportReady = false
    private var sessionCreateQueued = false
    private var waitingReason: String?
    private let endpoint: URL
    private let preferSystemTransport: Bool
    private var usingSystemTransport = false
    private var sessionEstablished = false
    typealias TransportFactory = (Bool, @escaping @Sendable (NetworkWebSocket.State) -> Void) -> any VoiceWebSocket
    private let transportFactory: TransportFactory?

    init(endpoint: URL = VoiceSettings.endpoint, preferSystemTransport: Bool = false,
         transportFactory: TransportFactory? = nil) {
        self.endpoint = endpoint; self.preferSystemTransport = preferSystemTransport
        self.transportFactory = transportFactory
    }

    func connect(apiKey: String, settings: VoiceSettings, searchAPIKey: String = "") throws {
        try settings.validate(searchAPIKey: searchAPIKey)
        shutdown()
        active = true
        self.apiKey = apiKey
        self.settings = settings
        self.searchAPIKey = settings.webSearchEnabled ? searchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        sessionID = UUID().uuidString
        metrics = VoiceNetworkMetrics(); lastUploaded = 0; lastDownloaded = 0
        lastMetricsAt = ProcessInfo.processInfo.systemUptime
        startMonitoring()
        openTransport(system: preferSystemTransport)
    }

    private func openTransport(system: Bool) {
        resetTransport()
        guard active, !closing else { return }
        retryTask?.cancel(); retryTask = nil
        usingSystemTransport = system
        let token = generation
        let handler: @Sendable (NetworkWebSocket.State) -> Void = { [weak self] state in
            Task { @MainActor in
                guard let self, self.active, self.generation == token else { return }
                self.transportChanged(state)
            }
        }
        let socket: any VoiceWebSocket
        if let transportFactory { socket = transportFactory(system, handler) }
        else if system { socket = SystemWebSocket(url: endpoint, apiKey: apiKey, onStateChange: handler) }
        else { socket = NetworkWebSocket(url: endpoint, apiKey: apiKey, onStateChange: handler) }
        self.socket = socket
        onProgress?(recovering ? "正在自动重连豆包" : system ? "正在尝试备用连接" : "正在连接豆包网络")
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await socket.receive()
                    guard let self, self.active, self.generation == token else { return }
                    self.metrics.downloadedBytes += data.count
                    let event = try ServerEvent(data: data)
                    if self.closing {
                        if event.type == "session.closed" { self.finishClose() }
                        continue
                    }
                    if event.type == "error" {
                        let code = event.statusCode.map { "（\($0)）" } ?? ""
                        let message = "豆包服务错误\(code)：\(event.errorMessage ?? "请检查服务开通状态和 API Key。")"
                        if ReconnectPolicy.retryServerCode(event.statusCode, message: event.errorMessage) {
                            self.scheduleRetry(throttled: event.statusCode == "429")
                        } else { self.fail(message) }
                        return
                    }
                    if event.type == "session.created" {
                        self.sessionEstablished = true
                        if let id = event.sessionID { self.sessionID = id }
                        guard self.connectionFailureTask == nil else { continue }
                        self.isReady = true
                        self.startupTimeout?.cancel()
                        self.onEvent?(event)
                        self.setRecovering(false)
                        // Only a stable connection clears the increasing retry delay.
                        continue
                    }
                    if event.type == "session.closed" {
                        self.scheduleRetry(); return
                    }
                    if self.sessionEstablished { self.onEvent?(event) }
                }
            } catch {
                guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
                if self.closing { self.finishClose() }
                else if error is ProtocolError { self.fail(error.localizedDescription) }
                else { self.transportFailed(error.localizedDescription) }
            }
        }
        startStartupTimeout(token: token)
    }

    private func transportChanged(_ state: NetworkWebSocket.State) {
        guard active, !closing else { return }
        switch state {
        case .preparing: break
        case .waiting(let reason):
            transportReady = false; waitingReason = reason
            if sessionEstablished { scheduleConnectionFailure() }
            else { onProgress?("等待手表网络，恢复后自动连接") }
        case .ready:
            transportReady = true
            if sessionEstablished && waitingReason != nil {
                waitingReason = nil
                connectionFailureTask?.cancel(); connectionFailureTask = nil
                isReady = true; setRecovering(false)
                return
            }
            waitingReason = nil
            guard !sessionCreateQueued else { return }
            sessionCreateQueued = true
            onProgress?(recovering ? "正在恢复豆包会话" : "正在创建豆包会话")
            do { try enqueue(DoubaoProtocol.createSession(settings: settings, searchAPIKey: searchAPIKey, sessionID: sessionID)) }
            catch { scheduleConnectionFailure() }
            startStartupTimeout(token: generation)
        case .failed(let reason): transportFailed(reason)
        case .cancelled: break
        }
    }

    private func transportFailed(_ reason: String) {
        guard active, !closing else { return }
        if let range = reason.range(of: #"HTTP\s*\d{3}"#, options: .regularExpression),
           let code = Int(reason[range].filter { $0.isNumber }) {
            if (400..<500).contains(code) && code != 408 && code != 429 {
                fail("无法建立语音连接：\(reason)"); return
            }
            if code == 429 { scheduleRetry(throttled: true); return }
        }
        // The native handshake may not expose HTTP status; the system path does.
        if !usingSystemTransport && !sessionCreateQueued {
            openTransport(system: true)
        } else { scheduleConnectionFailure() }
    }

    private func startStartupTimeout(token: UUID) {
        startupTimeout?.cancel()
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.active, !self.closing, self.generation == token, !self.isReady else { return }
            if !self.usingSystemTransport && !self.sessionCreateQueued { self.openTransport(system: true) }
            else { self.scheduleRetry() }
        }
    }

    func sendAudio(_ data: Data) {
        guard isReady, !closing else { return }
        do { try enqueue(DoubaoProtocol.audio(data)) }
        catch { scheduleConnectionFailure() }
    }

    func control(_ type: String) {
        guard isReady, !closing else { return }
        do { try enqueue(DoubaoProtocol.event(type)) }
        catch { scheduleConnectionFailure() }
    }

    func close() {
        guard active, !closing else { return }
        closing = true; isReady = false
        retryTask?.cancel(); retryTask = nil
        connectionFailureTask?.cancel(); connectionFailureTask = nil
        startupTimeout?.cancel(); statisticsTask?.cancel()
        pathMonitor?.cancel(); pathMonitor = nil
        guard socket != nil, sessionEstablished else { finishClose(); return }
        do { try enqueue(DoubaoProtocol.event("session.close")) }
        catch { finishClose(); return }
        let token = generation
        closeTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.finishClose()
        }
    }

    func shutdown() {
        active = false; closing = false; callGeneration = UUID()
        retryTask?.cancel(); retryTask = nil
        statisticsTask?.cancel(); statisticsTask = nil
        pathMonitor?.cancel(); pathMonitor = nil; networkUnavailable = false
        resetTransport()
        recovering = false; retryAttempt = 0
        apiKey = ""; searchAPIKey = ""
    }

    private func resetTransport() {
        generation = UUID()
        startupTimeout?.cancel(); startupTimeout = nil
        closeTimeout?.cancel(); closeTimeout = nil
        connectionFailureTask?.cancel(); connectionFailureTask = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(); socket = nil
        budget.reset(); isReady = false
        transportReady = false; sessionCreateQueued = false; sessionEstablished = false; waitingReason = nil
    }

    private func enqueue(_ event: [String: Any]) throws {
        guard let socket else { throw ProtocolError.slowConnection }
        let payload = try DoubaoProtocol.encode(event)
        let count = payload.utf8.count
        let now = ProcessInfo.processInfo.systemUptime
        let control = event["type"] as? String != "input_audio_buffer.append"
        guard budget.accepts(bytes: count, control: control, now: now) else { throw ProtocolError.slowConnection }
        let id = budget.insert(bytes: count, now: now)
        metrics.uploadedBytes += count
        let token = generation
        socket.send(payload) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.budget.complete(id)
                guard error != nil else { return }
                if self.closing { self.finishClose() }
                else { self.scheduleConnectionFailure() }
            }
        }
    }

    private func setRecovering(_ value: Bool) {
        guard recovering != value else { return }
        recovering = value; onRecovering?(value)
    }

    private func scheduleConnectionFailure() {
        guard active, !closing else { return }
        isReady = false
        setRecovering(true)
        onProgress?("网络不稳定，正在自动恢复")
        guard connectionFailureTask == nil else { return }
        let token = generation
        connectionFailureTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.active, !self.closing, self.generation == token else { return }
            // Keep a short receive window so a late configuration error stops retries.
            self.scheduleRetry()
        }
    }

    private func scheduleRetry(throttled: Bool = false) {
        guard active, !closing else { return }
        setRecovering(true)
        resetTransport()
        retryTask?.cancel()
        let delay = ReconnectPolicy.delay(attempt: retryAttempt, throttled: throttled)
        retryAttempt += 1
        onProgress?(networkUnavailable ? "等待网络，恢复后自动连接" : delay == 0 ? "正在自动重连豆包" : "网络不稳定，稍后自动重连")
        let token = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.active, !self.closing, self.generation == token else { return }
            self.retryTask = nil
            if self.networkUnavailable { self.scheduleRetry(); return }
            self.metrics.reconnects += 1
            self.openTransport(system: true)
        }
    }

    /// Also used by the local fixture; a path becoming available is only a hint.
    func networkAvailabilityChanged(available: Bool) {
        let wasUnavailable = networkUnavailable
        networkUnavailable = !available
        if available && wasUnavailable && active && !closing && retryTask != nil {
            retryTask?.cancel(); retryTask = nil
            metrics.reconnects += 1
            openTransport(system: true)
        }
    }

    private func startMonitoring() {
        if transportFactory == nil {
            let monitor = NWPathMonitor(); pathMonitor = monitor
            let callToken = callGeneration
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor in
                    guard let self, self.callGeneration == callToken, self.active else { return }
                    self.networkAvailabilityChanged(available: available)
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.watchai.network-path"))
        }
        statisticsTask = Task { [weak self] in
            var stableSince: Double?
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, self.active, !self.closing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.isReady {
                    if stableSince == nil { stableSince = now }
                    if now - (stableSince ?? now) >= 10 { self.retryAttempt = 0 }
                    if self.budget.oldestAge(now: now) >= 2 { self.scheduleConnectionFailure() }
                    else if self.budget.oldestAge(now: now) > 0.5 { self.onProgress?("网络较慢，正在缓冲") }
                } else { stableSince = nil }
                if now - self.lastMetricsAt >= 1 {
                    let elapsed = now - self.lastMetricsAt
                    self.metrics.uploadBytesPerSecond = Double(self.metrics.uploadedBytes - self.lastUploaded) / elapsed
                    self.metrics.downloadBytesPerSecond = Double(self.metrics.downloadedBytes - self.lastDownloaded) / elapsed
                    self.metrics.pendingBytes = self.budget.bytes
                    self.metrics.oldestSendSeconds = self.budget.oldestAge(now: now)
                    self.lastMetricsAt = now
                    self.lastUploaded = self.metrics.uploadedBytes; self.lastDownloaded = self.metrics.downloadedBytes
                    self.onMetrics?(self.metrics)
                }
            }
        }
    }

    private func fail(_ message: String) {
        var safe = message
        for key in [apiKey, searchAPIKey].filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            safe = safe.replacingOccurrences(of: key, with: "[已隐藏]")
        }
        shutdown(); onFailure?(safe)
    }

    private func finishClose() {
        shutdown()
        onEvent?(try! ServerEvent(data: Data("{\"type\":\"session.closed\"}".utf8)))
    }
}

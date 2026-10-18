import AVFoundation
import Foundation

@MainActor
final class AudioController {
    var onPacket: ((Data) -> Void)?
    var onControl: ((String) -> Void)?
    var onBufferingChanged: ((Bool) -> Void)?
    var onBufferLevel: ((Double) -> Void)?
    private(set) var effectiveInputBitRate = 0
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlaybackChanged: ((Bool) -> Void)?
    
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var capture: CapturePipeline?
    private var tapInstalled = false
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var playbackGeneration = UUID()
    private var playbackBuffer = PlaybackBufferPolicy()
    private var reportedPlaybackActive = false
    private var outputRemainder = Data()
    private var bandwidthMode: VoiceSettings.BandwidthMode = .economy
    private var uploadRate = VoiceSettings.UploadRate.balanced
    private var suppressSilence = true
    private var opusDecoder: OggOpusDecoder?
    private var playbackResponseID: String?
    private var observers: [NSObjectProtocol] = []
    private var configurationObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryPolicy = AudioRecoveryPolicy()
    private var muted = false
    private var transmitting = false
    private var transmissionGeneration = UUID()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!

    func start(bandwidthMode: VoiceSettings.BandwidthMode, uploadRate: VoiceSettings.UploadRate = .balanced, suppressSilence: Bool = true) async throws {
        stop()
        self.bandwidthMode = bandwidthMode
        self.uploadRate = uploadRate; self.suppressSilence = suppressSilence
        opusDecoder = bandwidthMode == .economy ? try OggOpusDecoder() : nil
        let token = generation
        let granted = await AVAudioApplication.requestRecordPermission()
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        guard granted else { throw AudioError.permission }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { activated, error in
                if let error { continuation.resume(throwing: error) }
                else if activated { continuation.resume() }
                else { continuation.resume(throwing: AudioError.activation) }
            }
        }
        guard generation == token, !Task.isCancelled else {
            // An older activation completion must not deactivate a newer recording session.
            if self.engine == nil { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
            throw CancellationError()
        }
        recoveryPolicy = AudioRecoveryPolicy()
        try startEngine(token: token)
        observeInterruptions(token: token)
    }

    private func startEngine(token: UUID) throws {
        let captureToken = UUID()
        captureGeneration = captureToken
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioError.noInput }
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        let capture = try CapturePipeline(inputFormat: inputFormat, bandwidthMode: bandwidthMode, uploadRate: uploadRate, suppressSilence: suppressSilence,
            onUpload: { [weak self] epoch, actions in
                let capturedAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    guard let self, self.generation == token, self.captureGeneration == captureToken,
                          self.transmitting, self.transmissionGeneration == epoch else { return }
                    // One callback preserves control-before-audio ordering at voice onset.
                    for action in actions {
                        switch action {
                        case .mute: self.onControl?("input_audio_mute.commit")
                        case .unmute:
                            if !self.muted { self.onControl?("input_audio_unmute.commit") }
                        case .packet(let data):
                            if !self.muted && ProcessInfo.processInfo.systemUptime - capturedAt < 0.1 { self.onPacket?(data) }
                        }
                    }
                }
            }, onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.generation == token, self.captureGeneration == captureToken else { return }
                    self.onLevel?(level)
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token, self.captureGeneration == captureToken else { return }
                    self.onFailure?(message)
                }
            })
        self.capture = capture
        effectiveInputBitRate = capture.effectiveBitRate
        capture.setMuted(muted)
        if transmitting { capture.beginTransmission(epoch: transmissionGeneration) }
        // Arm the pacer before the tap can receive audio, including during start().
        capture.start()
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in capture.consume(buffer) }
        tapInstalled = true
        observeConfiguration(engine: engine, token: token)
        engine.prepare()
        try engine.start()
    }

    func setMuted(_ muted: Bool) { self.muted = muted; capture?.setMuted(muted) }

    func beginTransmission() {
        transmissionGeneration = UUID(); transmitting = true
        capture?.beginTransmission(epoch: transmissionGeneration)
    }
    func suspendTransmission() {
        transmissionGeneration = UUID(); transmitting = false
        capture?.suspendTransmission()
    }

    func finishPlayback(responseID: String?) {
        guard responseID == nil || playbackResponseID == responseID else { return }
        let shouldPlay = playbackBuffer.finish()
        if shouldPlay { player?.play(); onBufferingChanged?(false) }
        else if playbackBuffer.queuedFrames == 0 { onBufferingChanged?(false); reportPlayback(false) }
    }

    func play(_ data: Data, responseID: String?) throws {
        if let responseID, playbackResponseID != responseID {
            interruptPlayback()
            playbackBuffer.nextResponse()
            playbackResponseID = responseID
        }
        if let opusDecoder {
            for buffer in try opusDecoder.decode(data) { try schedule(buffer) }
        } else { try playPCM(data) }
    }

    private func playPCM(_ pcm: Data) throws {
        guard engine?.isRunning == true else { return }
        // A network chunk can split an Int16 sample; carry the final byte to the next chunk.
        outputRemainder.append(pcm)
        let byteCount = outputRemainder.count / 2 * 2
        guard byteCount > 0 else { return }
        let data = Data(outputRemainder.prefix(byteCount))
        outputRemainder.removeFirst(byteCount)
        let frames = AVAudioFrameCount(byteCount / 2)
        guard frames <= 24000 * 30, playbackBuffer.queuedFrames + Int(frames) <= 24000 * 30 else { throw AudioError.playbackBacklog }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { throw ProtocolError.invalidAudio }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            for index in 0..<Int(frames) {
                let bits = UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8
                channel[index] = Float(Int16(bitPattern: bits)) / 32768
            }
        }
        try schedule(buffer)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) throws {
        guard let player else { return }
        let frames = buffer.frameLength
        guard frames <= 24000 * 30, playbackBuffer.queuedFrames + Int(frames) <= 24000 * 30 else { throw AudioError.playbackBacklog }
        let shouldPlay = try playbackBuffer.append(frames: Int(frames))
        reportPlayback(true)
        onBufferingChanged?(!shouldPlay)
        onBufferLevel?(playbackBuffer.seconds)
        let token = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playbackGeneration == token else { return }
                self.playbackBuffer.complete(frames: Int(frames))
                self.onBufferLevel?(self.playbackBuffer.seconds)
                if self.playbackBuffer.queuedFrames == 0 {
                    self.player?.pause()
                    self.onBufferingChanged?(!self.playbackBuffer.finished)
                    if self.playbackBuffer.finished { self.reportPlayback(false) }
                }
            }
        }
        if shouldPlay && !player.isPlaying { player.play() }
    }

    private func reportPlayback(_ active: Bool) {
        guard reportedPlaybackActive != active else { return }
        reportedPlaybackActive = active
        onPlaybackChanged?(active)
    }

    func interruptPlayback(resetDecoder: Bool = true) {
        playbackGeneration = UUID()
        player?.stop()
        playbackBuffer.nextResponse()
        onBufferLevel?(0)
        onBufferingChanged?(false)
        outputRemainder.removeAll()
        if resetDecoder { opusDecoder?.reset(); playbackResponseID = nil }
        reportPlayback(false)
    }

    func stop() {
        generation = UUID()
        recoveryTask?.cancel(); recoveryTask = nil
        stopEngine()
        opusDecoder = nil
        muted = false; transmitting = false; transmissionGeneration = UUID()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine(resetDecoder: Bool = true) {
        captureGeneration = UUID()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        capture?.stop(); capture = nil
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        interruptPlayback(resetDecoder: resetDecoder)
        player?.stop(); player = nil
        engine?.stop(); engine = nil
    }

    private func observeInterruptions(token: UUID) {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.onFailure?("通话被系统中断，点击开始可以重新连接。")
                }
            })
    }

    private func observeConfiguration(engine: AVAudioEngine, token: UUID) {
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self, weak engine] _ in
                Task { @MainActor in
                    guard let self, let engine, self.generation == token, self.engine === engine else { return }
                    self.scheduleRecovery(engine: engine, token: token)
                }
            }
    }

    private func scheduleRecovery(engine: AVAudioEngine, token: UUID) {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self, weak engine] in
            // Activation and voice processing can post several delayed notifications.
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard let self, let engine, self.generation == token, self.engine === engine else { return }
            let formatMatches = self.capture?.matches(engine.inputNode.outputFormat(forBus: 0)) == true
            switch self.recoveryPolicy.action(isRunning: engine.isRunning, formatMatches: formatMatches,
                                            now: ProcessInfo.processInfo.systemUptime) {
            case .ignore: return
            case .fail:
                self.onFailure?("音频设备持续变化，无法恢复录音。请检查耳机连接后重新开始通话。")
            case .restart:
                do {
                    if formatMatches {
                        self.interruptPlayback(resetDecoder: false)
                        self.capture?.clearBufferedAudio()
                        engine.prepare()
                        try engine.start()
                    } else {
                        // Keep the activated audio session and WebSocket alive while
                        // rebuilding the converter/tap for the new hardware format.
                        self.stopEngine(resetDecoder: false)
                        try self.startEngine(token: token)
                    }
                } catch {
                    self.onFailure?("无法恢复音频设备，请重新开始通话。\(error.localizedDescription)")
                }
            }
        }
    }

    enum AudioError: LocalizedError {
        case permission, activation, noInput, conversion, playbackBacklog
        var errorDescription: String? {
            switch self {
            case .permission: return "需要麦克风权限。请在手表「设置 → 隐私与安全性 → 麦克风」中允许豆包AI 使用麦克风。"
            case .activation: return "无法启用手表音频，请检查是否有其他通话正在进行。"
            case .noInput: return "没有可用的麦克风，请检查音频设备。"
            case .conversion: return "无法转换麦克风音频格式，请重新开始。"
            case .playbackBacklog: return "语音播放积压过多，请结束后重试。"
            }
        }
    }
}

/// Conversion runs on the audio tap; packet buffering and pacing run on a private serial queue.
/// No shared buffer is accessed by both the audio render thread and the main actor.
private final class CapturePipeline: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private let queue = DispatchQueue(label: "com.watchai.microphone", qos: .userInteractive)
    private var buffer = PCMBuffer()
    private var timer: DispatchSourceTimer?
    private var muted = false
    private var stopped = false
    private var transmitting = false
    private var transmissionGeneration = UUID()
    private var gate = SpeechGate()
    private let suppressSilence: Bool
    var effectiveBitRate: Int { opusEncoder?.effectiveBitRate ?? 256000 }
    private let opusEncoder: SpeechOpusEncoder?
    private var tick = 0
    private var level: Float = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastTickDelay: Double = 0
    private let onUpload: @Sendable (UUID, [SpeechUploadAction]) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(inputFormat: AVAudioFormat, bandwidthMode: VoiceSettings.BandwidthMode, uploadRate: VoiceSettings.UploadRate,
         suppressSilence: Bool, onUpload: @escaping @Sendable (UUID, [SpeechUploadAction]) -> Void,
         onLevel: @escaping @Sendable (Float) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw AudioController.AudioError.conversion }
        self.converter = converter
        opusEncoder = bandwidthMode == .economy ? try SpeechOpusEncoder(bitRate: uploadRate.rawValue) : nil
        self.inputFormat = inputFormat
        self.suppressSilence = suppressSilence; self.onUpload = onUpload
        self.onLevel = onLevel; self.onFailure = onFailure
    }

    func start() {
        queue.async { [self] in
            guard !self.stopped, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.lastTickDelay = now - self.lastTick
                self.lastTick = now
                guard !self.muted else { return }
                self.tick += 1
                if self.tick % 5 == 0 { self.onLevel(self.level) }
                // Muted idle periods use explicit service events rather than silence packets.
                let intervals = Int(min(self.timer?.data ?? 1, UInt(Int.max)))
                let pcm = self.buffer.nextPacket(elapsedIntervals: max(1, intervals)) ?? Data(count: PCMBuffer.packetBytes)
                guard self.transmitting else { return }
                do {
                    let actions = try self.gate.process(pcm, suppressSilence: self.suppressSilence).map { action in
                        if case .packet(let samples) = action { return SpeechUploadAction.packet(try self.opusEncoder?.encode(samples) ?? samples) }
                        return action
                    }
                    if !actions.isEmpty { self.onUpload(self.transmissionGeneration, actions) }
                } catch { self.reportFailure(error.localizedDescription) }
            }
            self.timer = timer
            self.lastTick = ProcessInfo.processInfo.systemUptime
            timer.resume()
        }
    }

    func consume(_ input: AVAudioPCMBuffer) {
        // A route change can deliver a final buffer in a new format before the
        // configuration notification is handled. Let recovery rebuild the converter.
        guard matches(input.format) else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, let channel = output.floatChannelData?[0] else {
            queue.async { self.reportFailure(AudioController.AudioError.conversion.localizedDescription) }
            return
        }
        var pcm = Data(count: Int(output.frameLength) * 2)
        var sum: Float = 0
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for index in 0..<Int(output.frameLength) {
                let value = max(-1, min(1, channel[index].isFinite ? channel[index] : 0))
                sum += value * value
                let sample = UInt16(bitPattern: Int16(max(-32768, min(32767, Int(value * 32767)))))
                raw[index * 2] = UInt8(truncatingIfNeeded: sample)
                raw[index * 2 + 1] = UInt8(truncatingIfNeeded: sample >> 8)
            }
        }
        let rms = min(1, sqrt(sum / Float(max(1, output.frameLength))) * 5)
        let bytes = pcm
        queue.async {
            guard !self.stopped, !self.muted else { return }
            self.level = rms
            do { try self.buffer.append(bytes) }
            catch {
                // Audio metrics only; no credentials or recorded content.
                let batchMs = bytes.count * 1000 / 32000
                let queuedMs = self.buffer.count * 1000 / 32000
                let tickMs = Int(self.lastTickDelay * 1000)
                self.reportFailure("\(error.localizedDescription)\n音频信息：输入 \(Int(self.inputFormat.sampleRate)) Hz，批次 \(batchMs) ms，缓冲 \(queuedMs) ms，分包间隔 \(tickMs) ms。")
            }
        }
    }

    func beginTransmission(epoch: UUID) {
        queue.async {
            self.transmissionGeneration = epoch
            self.buffer.clear(); self.gate.reset(); self.opusEncoder?.reset(); self.transmitting = true
            if self.muted { self.onUpload(epoch, [.mute]) }
        }
    }
    func setMuted(_ value: Bool) {
        queue.async {
            self.muted = value; self.buffer.clear(); self.gate.reset(); self.level = 0; self.onLevel(0)
            if value && self.transmitting { self.onUpload(self.transmissionGeneration, [.mute]) }
        }
    }
    func matches(_ format: AVAudioFormat) -> Bool { inputFormat.isEqual(format) }
    func suspendTransmission() {
        queue.async { self.transmitting = false; self.buffer.clear(); self.gate.reset() }
    }
    func clearBufferedAudio() {
        queue.async { self.buffer.clear(); self.gate.reset(); self.level = 0 }
    }
    func stop() {
        queue.async { self.stopped = true; self.timer?.cancel(); self.timer = nil; self.buffer.clear() }
    }
    private func reportFailure(_ message: String) {
        guard !stopped else { return }
        stopped = true
        timer?.cancel(); timer = nil
        onFailure(message)
    }
}

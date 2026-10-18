import Foundation

/// Decisions use monotonic time, so callback latency alone is not called bandwidth.
public struct SendBudget: Sendable {
    private var entries: [UUID: (time: Double, bytes: Int)] = [:]
    public static let maximumAudioRequests = 100
    public static let maximumBytes = 128 * 1024
    public init() {}
    public var count: Int { entries.count }
    public var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    public func oldestAge(now: Double) -> Double { entries.values.map { max(0, now - $0.time) }.max() ?? 0 }
    public func accepts(bytes: Int, control: Bool, now: Double) -> Bool {
        count < Self.maximumAudioRequests + (control ? 8 : 0)
            && bytes >= 0 && self.bytes + bytes <= Self.maximumBytes
            && (control || oldestAge(now: now) < 2)
    }
    public mutating func insert(bytes: Int, now: Double) -> UUID {
        let id = UUID(); entries[id] = (now, bytes); return id
    }
    public mutating func complete(_ id: UUID) { entries.removeValue(forKey: id) }
    public mutating func reset() { entries.removeAll() }
}

public enum SpeechUploadAction: Equatable, Sendable {
    case mute, unmute, packet(Data)
}

/// Keeps 240 ms of pre-roll; emits at most one 20 ms packet per tick, even at onset.
/// A conservative energy detector, not speaker identification.
public struct SpeechGate: Sendable {
    private var history: [Data] = []
    private var active = false
    private var initialized = false
    private var candidateFrames = 0
    private var quietFrames = 0
    private var noiseFloor: Double = 0.0008
    public init() {}
    public var bufferedPackets: Int { history.count }
    public mutating func reset() { self = SpeechGate() }
    public mutating func process(_ pcm: Data, suppressSilence: Bool) -> [SpeechUploadAction] {
        guard pcm.count == PCMBuffer.packetBytes else { return [] }
        var actions: [SpeechUploadAction] = []
        if !initialized {
            initialized = true
            actions.append(suppressSilence ? .mute : .unmute)
        }
        if !suppressSilence { actions.append(.packet(pcm)); return actions }
        let level = Self.rms(pcm)
        let threshold = min(0.012, max(0.0035, noiseFloor * 2.8))
        let voiced = level > threshold
        if !active && !voiced { noiseFloor = noiseFloor * 0.98 + level * 0.02 }
        history.append(pcm)
        if !active {
            if history.count > 12 { history.removeFirst(history.count - 12) }
            candidateFrames = voiced ? candidateFrames + 1 : 0
            guard candidateFrames >= 2 else { return actions }
            active = true; quietFrames = 0
            actions.append(.unmute)
        }
        quietFrames = voiced ? 0 : quietFrames + 1
        // 800 ms hangover leaves ample silence for server end-of-speech detection.
        if quietFrames >= 40 {
            active = false; candidateFrames = 0
            history.removeAll(keepingCapacity: true)
            actions.append(.mute)
        } else if !history.isEmpty {
            actions.append(.packet(history.removeFirst()))
        }
        return actions
    }
    public static func rms(_ pcm: Data) -> Double {
        var energy: Double = 0
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                let sample = Double(Int16(bitPattern: bits)) / 32768
                energy += sample * sample
            }
        }
        return sqrt(energy / Double(max(1, pcm.count / 2)))
    }
}

/// The player queues decoded audio while paused, then starts at this threshold.
public struct PlaybackBufferPolicy: Sendable {
    public private(set) var queuedFrames = 0
    public private(set) var targetSeconds: Double = 0.5
    public private(set) var playing = false
    public private(set) var finished = false
    public private(set) var underruns = 0
    public init() {}
    public var seconds: Double { Double(queuedFrames) / 24000 }
    public mutating func append(frames: Int) throws -> Bool {
        guard frames >= 0, frames <= 720000 - queuedFrames else { throw ProtocolError.playbackBacklog }
        queuedFrames += frames
        return startIfReady()
    }
    public mutating func finish() -> Bool { finished = true; return startIfReady() }
    public mutating func complete(frames: Int) {
        queuedFrames = max(0, queuedFrames - frames)
        if queuedFrames == 0 {
            if playing && !finished {
                underruns += 1
                targetSeconds = min(2, max(1, targetSeconds * 1.5))
            }
            playing = false
        }
    }
    public mutating func nextResponse() {
        queuedFrames = 0; playing = false; finished = false
    }
    private mutating func startIfReady() -> Bool {
        if !playing && queuedFrames > 0 && (seconds >= targetSeconds || finished) { playing = true }
        return playing
    }
}

public enum ReconnectPolicy {
    public static func delay(attempt: Int, throttled: Bool = false) -> Double {
        if throttled { return min(30, 4 * pow(2, Double(min(3, max(0, attempt))))) }
        return attempt <= 0 ? 0 : min(8, pow(2, Double(min(3, attempt - 1))))
    }
    public static func retryServerCode(_ code: String?, message: String? = nil) -> Bool {
        let detail = (message ?? "").lowercased()
        let permanent = ["invalidspeaker", "invalidparameter", "authentication", "unauthorized", "permission denied", "invalid_api_key", "insufficientbalance", "余额不足", "未开通"]
        if permanent.contains(where: { detail.contains($0) }) { return false }
        guard let code else { return false }
        return code == "429" || code.hasPrefix("5")
    }
}

public struct VoiceNetworkMetrics: Equatable, Sendable {
    public var uploadedBytes = 0
    public var downloadedBytes = 0
    public var uploadBytesPerSecond: Double = 0
    public var downloadBytesPerSecond: Double = 0
    public var pendingBytes = 0
    public var oldestSendSeconds: Double = 0
    public var reconnects = 0
    public init() {}
}

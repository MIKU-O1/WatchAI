import Foundation

/// 16 kHz, mono, signed Int16 LE; each packet is exactly 20 milliseconds.
public struct PCMBuffer: Sendable {
    public static let packetBytes = 640
    // A tap's requested buffer size is a hint; hardware may deliver a much
    // larger batch. Allow up to two seconds without retaining unbounded audio.
    public static let maximumBytes = 64000
    private var bytes = Data()
    public init() {}
    public var count: Int { bytes.count }
    public mutating func append(_ data: Data) throws {
        guard data.count <= Self.maximumBytes - bytes.count else { throw ProtocolError.microphoneBacklog }
        bytes.append(data)
    }
    public mutating func nextPacket(elapsedIntervals: Int = 1) -> Data? {
        // Dispatch timers coalesce missed deadlines. Discard audio for those
        // expired slots rather than increasing latency or uploading a burst.
        let expiredPackets = min(max(1, elapsedIntervals) - 1, bytes.count / Self.packetBytes)
        if expiredPackets > 0 { bytes.removeFirst(expiredPackets * Self.packetBytes) }
        guard bytes.count >= Self.packetBytes else { return nil }
        let result = Data(bytes.prefix(Self.packetBytes))
        bytes.removeFirst(Self.packetBytes)
        return result
    }
    public mutating func clear() { bytes.removeAll(keepingCapacity: true) }
}

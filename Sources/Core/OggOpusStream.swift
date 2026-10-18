import Foundation

/// Incremental Ogg framing. WebSocket boundaries need not coincide with pages or packets.
public struct OggOpusStream {
    public struct Page: Sendable {
        public let packets: [Data]
        public let granule: UInt64
        public let beginsStream: Bool
        public let endsStream: Bool
    }
    private var buffer = Data()
    private var partial = Data()
    private var serial: UInt32?
    private var sequence: UInt32?
    private static let limit = 256 * 1024
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Page] {
        guard bytes.count <= Self.limit, buffer.count + bytes.count <= Self.limit else { throw ProtocolError.invalidAudio }
        buffer.append(bytes)
        var pages: [Page] = []
        var offset = 0
        while buffer.count - offset >= 27 {
            let start = buffer.startIndex + offset
            guard buffer[start..<start + 4].elementsEqual("OggS".utf8), buffer[start + 4] == 0 else {
                throw ProtocolError.invalidAudio
            }
            let flags = buffer[start + 5]
            let segments = Int(buffer[start + 26])
            let headerSize = 27 + segments
            guard buffer.count - offset >= headerSize else { break }
            let lengths = buffer[start + 27..<start + headerSize].map(Int.init)
            let pageSize = headerSize + lengths.reduce(0, +)
            guard buffer.count - offset >= pageSize else { break }
            let page = Data(buffer[start..<start + pageSize])
            let pageSerial = UInt32(readLE(page, 14, 4))
            let pageSequence = UInt32(readLE(page, 18, 4))
            let begins = flags & 2 != 0
            if begins {
                guard partial.isEmpty else { throw ProtocolError.invalidAudio }
                serial = pageSerial; sequence = nil
            }
            guard serial == pageSerial, (sequence == nil || pageSequence == sequence! &+ 1),
                  (flags & 1 != 0) == !partial.isEmpty else { throw ProtocolError.invalidAudio }
            guard Self.checksum(page) == UInt32(readLE(page, 22, 4)) else { throw ProtocolError.invalidAudio }
            sequence = pageSequence
            var packets: [Data] = []
            var position = headerSize
            for length in lengths {
                guard partial.count + length <= Self.limit else { throw ProtocolError.invalidAudio }
                partial.append(page[position..<position + length])
                position += length
                if length < 255 { packets.append(partial); partial = Data() }
            }
            let ends = flags & 4 != 0
            guard !ends || partial.isEmpty else { throw ProtocolError.invalidAudio }
            pages.append(Page(packets: packets, granule: readLE(page, 6, 8), beginsStream: begins, endsStream: ends))
            offset += pageSize
            if ends { serial = nil; sequence = nil }
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return pages
    }

    private func readLE(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    public static func checksum(_ page: Data) -> UInt32 {
        var crc: UInt32 = 0
        for (index, byte) in page.enumerated() {
            crc ^= UInt32((22..<26).contains(index) ? 0 : byte) << 24
            for _ in 0..<8 { crc = crc & 0x80000000 != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1 }
        }
        return crc
    }

    /// Duration at the Ogg granule clock (always 48 kHz), per RFC 6716 §3.1.
    public static func frames(in packet: Data) throws -> Int {
        guard let toc = packet.first else { throw ProtocolError.invalidAudio }
        let config = Int(toc >> 3)
        let perFrame: Int
        if config < 12 { perFrame = [480, 960, 1920, 2880][config & 3] }
        else if config < 16 { perFrame = [480, 960][config & 1] }
        else { perFrame = [120, 240, 480, 960][config & 3] }
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { throw ProtocolError.invalidAudio }
            count = Int(packet[packet.startIndex + 1] & 63)
        }
        let frames = perFrame * count
        guard frames > 0, frames <= 5760 else { throw ProtocolError.invalidAudio }
        return frames
    }
}

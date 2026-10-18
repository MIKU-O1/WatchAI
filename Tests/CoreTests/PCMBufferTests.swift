import XCTest
@testable import WatchAICore

final class PCMBufferTests: XCTestCase {
    func testHardwareBatchLargerThanOldHalfSecondLimit() throws {
        var buffer = PCMBuffer()
        // A hardware tap may ignore the requested 1024 frames and deliver 16384.
        let batch = Data((0..<32768).map { UInt8(truncatingIfNeeded: $0) })
        try buffer.append(batch)
        var received = Data()
        while let packet = buffer.nextPacket() {
            XCTAssertEqual(packet.count, 640)
            received.append(packet)
        }
        XCTAssertEqual(received, batch.prefix(received.count))
        XCTAssertEqual(buffer.count, batch.count % 640)
    }

    func testCoalescedTimerResumesAtCurrentAudioWithoutBurst() throws {
        var buffer = PCMBuffer()
        for ordinal in 0..<40 {
            try buffer.append(Data(repeating: UInt8(ordinal), count: 640))
        }
        // A 500 ms scheduling stall represents 25 deadlines, not just one.
        XCTAssertEqual(buffer.nextPacket(elapsedIntervals: 25), Data(repeating: 24, count: 640))
        XCTAssertEqual(buffer.count, 15 * 640)
        XCTAssertEqual(buffer.nextPacket(), Data(repeating: 25, count: 640))
    }

    func testLongSchedulingPauseKeepsSubpacketSampleAlignment() throws {
        var buffer = PCMBuffer()
        try buffer.append(Data(repeating: 1, count: 640))
        try buffer.append(Data(repeating: 2, count: 100))
        XCTAssertNil(buffer.nextPacket(elapsedIntervals: Int.max))
        try buffer.append(Data(repeating: 3, count: 540))
        let packet = try XCTUnwrap(buffer.nextPacket())
        XCTAssertEqual(packet.prefix(100), Data(repeating: 2, count: 100))
        XCTAssertEqual(packet.suffix(540), Data(repeating: 3, count: 540))
        XCTAssertNil(buffer.nextPacket(elapsedIntervals: Int.min))
    }

    func testThirtySecondsOfBatchedCaptureRetainsContentsAndBoundedLatency() throws {
        var buffer = PCMBuffer()
        var nextBatchAt = 0
        var produced = 0
        var consumed = 0
        for timeMs in stride(from: 0, to: 30000, by: 20) {
            while nextBatchAt <= timeMs {
                // 4096 samples at 16 kHz arrive every 256 ms, independent of pacer.
                let batch = Data((produced..<(produced + 8192)).map { UInt8(truncatingIfNeeded: $0) })
                try buffer.append(batch)
                produced += batch.count
                nextBatchAt += 256
            }
            if let packet = buffer.nextPacket() {
                XCTAssertEqual(packet, Data((consumed..<(consumed + 640)).map { UInt8(truncatingIfNeeded: $0) }))
                consumed += packet.count
            }
            XCTAssertLessThanOrEqual(buffer.count, 8192)
        }
        XCTAssertGreaterThan(consumed, 32000 * 29)
        XCTAssertEqual(produced - consumed, buffer.count)
    }
}

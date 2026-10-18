import XCTest
@testable import WatchAICore

final class OggOpusStreamTests: XCTestCase {
    func page(flags: UInt8, sequence: UInt32, body: Data, lengths: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 27)
        bytes.replaceSubrange(0..<4, with: "OggS".utf8)
        bytes[5] = flags; bytes[14] = 7; bytes[26] = UInt8(lengths.count)
        for i in 0..<4 { bytes[18 + i] = UInt8(truncatingIfNeeded: sequence >> (i * 8)) }
        var data = Data(bytes + lengths); data.append(body)
        let checksum = OggOpusStream.checksum(data)
        for i in 0..<4 { data[22 + i] = UInt8(truncatingIfNeeded: checksum >> (i * 8)) }
        return data
    }
    func testPacketContinuesAcrossPagesAndEmptyLaceTerminates255BytePacket() throws {
        let first = page(flags: 2, sequence: 0, body: Data(repeating: 42, count: 255), lengths: [255])
        let second = page(flags: 1 | 4, sequence: 1, body: Data([9]), lengths: [0, 1])
        var stream = OggOpusStream()
        XCTAssertEqual(try stream.append(first).first?.packets.count, 0)
        let packets = try XCTUnwrap(stream.append(second).first).packets
        XCTAssertEqual(packets, [Data(repeating: 42, count: 255), Data([9])])
    }
    func testMissingPageAndMissingContinuationFlagAreRejected() throws {
        let first = page(flags: 2, sequence: 0, body: Data(repeating: 42, count: 255), lengths: [255])
        var gap = OggOpusStream()
        _ = try gap.append(first)
        XCTAssertThrowsError(try gap.append(page(flags: 1 | 4, sequence: 2, body: Data([9]), lengths: [1])))
        var missing = OggOpusStream()
        _ = try missing.append(first)
        XCTAssertThrowsError(try missing.append(page(flags: 4, sequence: 1, body: Data([9]), lengths: [1])))
    }
    func testOpusDurationChecksRejectEmptyZeroFramesAndMoreThan120ms() throws {
        XCTAssertEqual(try OggOpusStream.frames(in: Data([0x08])), 960)
        XCTAssertEqual(try OggOpusStream.frames(in: Data([0xf8])), 960)
        XCTAssertThrowsError(try OggOpusStream.frames(in: Data()))
        XCTAssertThrowsError(try OggOpusStream.frames(in: Data([0x0b, 0])))
        XCTAssertThrowsError(try OggOpusStream.frames(in: Data([0x1b, 3])))
    }
}

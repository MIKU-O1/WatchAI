import XCTest
import AVFoundation
@testable import WatchAIAudio
import WatchAICore

final class OpusCodecTests: XCTestCase {
    func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "tone-24k", withExtension: "opus", subdirectory: "Fixtures")))
    }
    func testIndependentLibOpusFixtureStreamsAcrossEveryByteBoundary() throws {
        let decoder = try OggOpusDecoder()
        var frames = 0
        var energy: Double = 0
        var crossing = 0
        var previous: Float = 0
        for byte in try fixture() {
            for pcm in try decoder.decode(Data([byte])) {
                for index in 0..<Int(pcm.frameLength) {
                    let value = pcm.floatChannelData![0][index]
                    XCTAssertTrue(value.isFinite)
                    energy += Double(value * value)
                    if previous <= 0 && value > 0 { crossing += 1 }
                    previous = value
                }
                frames += Int(pcm.frameLength)
            }
        }
        XCTAssertEqual(frames, 48000, "Pre-skip and EOS granule must preserve the two-second duration")
        XCTAssertEqual(Double(crossing) / 2, 440, accuracy: 3)
        XCTAssertGreaterThan(sqrt(energy / Double(frames)), 0.05)
    }
    func testChainedAnswersAndInterruptedPartialPageReset() throws {
        let data = try fixture()
        let decoder = try OggOpusDecoder()
        _ = try decoder.decode(Data(data.prefix(17)))
        decoder.reset()
        let first = try decoder.decode(data).reduce(0) { $0 + Int($1.frameLength) }
        let second = try decoder.decode(data).reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertEqual(first, 48000)
        XCTAssertEqual(second, first)
    }
    func testUploadIs20msOpusAndReducesWireBytesIncludingJSON() throws {
        let encoder = try SpeechOpusEncoder()
        var compressedWire = 0
        var pcmWire = 0
        for n in 0..<250 {
            var bytes = Data(count: 640)
            bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                for i in 0..<320 {
                    // Vary pitch and envelope, rather than measuring compression on silence.
                    let t = Float(n * 320 + i) / 16000
                    let value = Int16(sin(t * 2 * .pi * (200 + Float(n % 9) * 35)) * (0.1 + 0.05 * sin(t * 7)) * 32767)
                    let bits = UInt16(bitPattern: value)
                    raw[i * 2] = UInt8(truncatingIfNeeded: bits); raw[i * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
            let packet = try encoder.encode(bytes)
            XCTAssertEqual(try OggOpusStream.frames(in: packet), 960)
            compressedWire += try DoubaoProtocol.encode(DoubaoProtocol.audio(packet)).utf8.count
            pcmWire += try DoubaoProtocol.encode(DoubaoProtocol.audio(bytes)).utf8.count
        }
        XCTAssertLessThan(compressedWire, pcmWire / 4)
        print("Opus upload fixture: JSON \(compressedWire) bytes / 5 s; PCM \(pcmWire) bytes / 5 s")
        XCTAssertThrowsError(try encoder.encode(Data(count: 639)))
        encoder.reset()
        XCTAssertFalse(try encoder.encode(Data(count: 640)).isEmpty)
    }
    func testLowBitRatesProduceValid20msPacketsAndReduceAudioBytes() throws {
        var sizes: [Int: Int] = [:]
        for requested in [8000, 12000, 16000] {
            let encoder = try SpeechOpusEncoder(bitRate: requested)
            XCTAssertTrue([8000, 12000, 16000].contains(encoder.effectiveBitRate))
            var total = 0
            for n in 0..<250 {
                var bytes = Data(count: 640)
                bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    for i in 0..<320 {
                        let t = Double(n * 320 + i) / 16000
                        let sample = Int16(sin(t * 2 * .pi * (200 + Double(n % 7) * 45)) * 6000)
                        let bits = UInt16(bitPattern: sample)
                        raw[i * 2] = UInt8(truncatingIfNeeded: bits); raw[i * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                    }
                }
                let packet = try encoder.encode(bytes)
                XCTAssertEqual(try OggOpusStream.frames(in: packet), 960)
                total += packet.count
            }
            sizes[encoder.effectiveBitRate] = total
            print("Opus target \(requested): effective \(encoder.effectiveBitRate), \(total) audio bytes / 5 s")
        }
        if let low = sizes[8000], let clear = sizes[16000] { XCTAssertLessThan(low, clear) }
        if let balanced = sizes[12000], let clear = sizes[16000] { XCTAssertLessThan(balanced, clear) }
    }

    func testCorruptCompressedDataFailsWithoutUnboundedBuffer() throws {
        var data = try fixture()
        data[30] ^= 1
        XCTAssertThrowsError(try OggOpusDecoder().decode(data))
        XCTAssertThrowsError(try OggOpusDecoder().decode(Data(count: 256 * 1024 + 1)))
    }
}

import AVFoundation
import Foundation
#if canImport(WatchAICore)
import WatchAICore
#endif

public enum OpusCodecError: LocalizedError {
    case unavailable, encoding, decoding
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "设备无法启用 Opus 压缩，请在设置中选择兼容模式后重试。"
        case .encoding: return "麦克风音频压缩失败，请重新开始通话。"
        case .decoding: return "压缩语音解码失败，请重新开始；若持续出现，请选择兼容模式。"
        }
    }
}

private func opusFormat(rate: Double, frames: UInt32) throws -> AVAudioFormat {
    var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus,
        mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: frames, mBytesPerFrame: 0,
        mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    guard let format = AVAudioFormat(streamDescription: &description) else { throw OpusCodecError.unavailable }
    return format
}

/// One raw Opus packet per 20 ms. Owned exclusively by the capture pacing queue.
public final class SpeechOpusEncoder {
    public let effectiveBitRate: Int
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer
    public init(bitRate: Int = 12000) throws {
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let opus = try opusFormat(rate: 16000, frames: 320)
        guard let converter = AVAudioConverter(from: pcm, to: opus),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 320) else { throw OpusCodecError.unavailable }
        let supported = converter.applicableEncodeBitRates?.map { $0.intValue } ?? []
        let requested = [bitRate, 12000, 16000].first { supported.isEmpty || supported.contains($0) } ?? 16000
        converter.bitRate = requested
        effectiveBitRate = converter.bitRate
        guard converter.maximumOutputPacketSize > 0 else { throw OpusCodecError.unavailable }
        self.converter = converter
        self.input = input
        output = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
    }
    public func reset() { converter.reset() }
    public func encode(_ pcm: Data) throws -> Data {
        guard pcm.count == 640, let channel = input.floatChannelData?[0] else { throw OpusCodecError.encoding }
        input.frameLength = 320
        pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<320 {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                channel[index] = Float(Int16(bitPattern: bits)) / 32768
            }
        }
        output.packetCount = 0; output.byteLength = 0
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { [input] _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard error == nil, result != .error, output.packetCount == 1,
              let packet = output.packetDescriptions?.pointee,
              packet.mDataByteSize > 0, packet.mStartOffset >= 0,
              packet.mStartOffset + Int64(packet.mDataByteSize) <= Int64(output.byteLength) else { throw OpusCodecError.encoding }
        // No Ogg container or Apple magic cookie is uploaded: speech_opus uses raw packets.
        return Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
    }
}

/// Decode pages as they arrive, without downloading a complete answer before playback.
public final class OggOpusDecoder {
    public let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var stream = OggOpusStream()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var preSkip = 0
    private var timeline = 0
    private var emittedFrames = 0
    private var gain: Float = 1
    public init() throws {
        let format = try opusFormat(rate: 24000, frames: 0)
        guard AVAudioConverter(from: format, to: outputFormat) != nil else { throw OpusCodecError.unavailable }
    }
    public func reset() {
        stream = OggOpusStream(); converter = nil; inputFormat = nil
        preSkip = 0; timeline = 0; emittedFrames = 0; gain = 1
    }
    public func decode(_ bytes: Data) throws -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []
        for page in try stream.append(bytes) {
            if page.beginsStream { converter = nil; inputFormat = nil; timeline = 0; emittedFrames = 0 }
            var buffers: [AVAudioPCMBuffer] = []
            for packet in page.packets {
                if packet.starts(with: "OpusHead".utf8) { try configure(packet); continue }
                if packet.starts(with: "OpusTags".utf8) { continue }
                guard !packet.isEmpty, let converter, let inputFormat else { throw OpusCodecError.decoding }
                let frames48 = try OggOpusStream.frames(in: packet)
                let input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
                input.packetCount = 1; input.byteLength = UInt32(packet.count)
                packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
                input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0,
                    mVariableFramesInPacket: UInt32(frames48 / 2), mDataByteSize: UInt32(packet.count))
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 2880) else { throw OpusCodecError.decoding }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    guard !supplied else { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return input
                }
                guard error == nil, status != .error, Int(output.frameLength) * 2 <= frames48,
                      let channel = output.floatChannelData?[0] else { throw OpusCodecError.decoding }
                // Apple's decoder can remove its own leading priming frames. Count those
                // toward Ogg pre-skip rather than trimming the beginning twice.
                let nativeSkip = frames48 - Int(output.frameLength) * 2
                let skip = min(Int(output.frameLength), max(0, preSkip - timeline - nativeSkip) / 2)
                timeline += frames48
                let length = Int(output.frameLength) - skip
                for index in 0..<length { channel[index] = channel[index + skip] * gain }
                output.frameLength = AVAudioFrameCount(length)
                if length > 0 { buffers.append(output) }
            }
            var pageFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
            if page.endsStream, page.granule != UInt64.max {
                guard page.granule <= UInt64(timeline), page.granule >= UInt64(preSkip) else { throw OpusCodecError.decoding }
                let target = Int((page.granule - UInt64(preSkip)) / 2)
                guard target >= emittedFrames else { throw OpusCodecError.decoding }
                var excess = max(0, emittedFrames + pageFrames - target)
                for buffer in buffers.reversed() {
                    let trim = min(excess, Int(buffer.frameLength))
                    buffer.frameLength -= AVAudioFrameCount(trim); excess -= trim; pageFrames -= trim
                }
            }
            emittedFrames += pageFrames
            result.append(contentsOf: buffers.filter { $0.frameLength > 0 })
            if page.endsStream { converter = nil; inputFormat = nil }
        }
        return result
    }
    private func configure(_ header: Data) throws {
        let bytes = [UInt8](header)
        guard bytes.count >= 19, bytes[8] < 16, bytes[9] == 1, bytes[18] == 0 else { throw OpusCodecError.decoding }
        preSkip = Int(bytes[10]) | Int(bytes[11]) << 8
        let gainBits = UInt16(bytes[16]) | UInt16(bytes[17]) << 8
        gain = pow(10, Float(Int16(bitPattern: gainBits)) / (256 * 20))
        timeline = 0; emittedFrames = 0
        let format = try opusFormat(rate: 24000, frames: 0)
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else { throw OpusCodecError.unavailable }
        self.inputFormat = format; self.converter = converter
    }
}

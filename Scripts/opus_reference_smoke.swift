import Foundation

@main
struct OpusReferenceSmoke {
    static func main() throws {
        let encoder = try SpeechOpusEncoder(bitRate: CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 12000)
        var packets: [String] = []
        for n in 0..<250 {
            var pcm = Data(count: 640)
            pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                for i in 0..<320 {
                    let value = Int16(sin(Double(n * 320 + i) * 2 * .pi * 440 / 16000) * 0.2 * 32767)
                    let bits = UInt16(bitPattern: value)
                    raw[i * 2] = UInt8(truncatingIfNeeded: bits); raw[i * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                }
            }
            packets.append(try encoder.encode(pcm).base64EncodedString())
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: packets))
    }
}

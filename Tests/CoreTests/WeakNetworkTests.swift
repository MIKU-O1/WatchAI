import XCTest
@testable import WatchAICore

final class WeakNetworkTests: XCTestCase {
    func pcm(_ amplitude: Int16) -> Data {
        let bits = UInt16(bitPattern: amplitude)
        return Data((0..<320).flatMap { _ in [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)] })
    }
    func testIdleStopsPacketsButOnsetKeepsBothFirstFramesAndCadence() {
        var gate = SpeechGate()
        let silence = pcm(0), speech = pcm(1800)
        XCTAssertEqual(gate.process(silence, suppressSilence: true), [.mute])
        for _ in 0..<500 { XCTAssertEqual(gate.process(silence, suppressSilence: true), []) }
        var sent: [Data] = []
        var controls: [SpeechUploadAction] = []
        for frame in [speech, speech] + Array(repeating: silence, count: 50) {
            let actions = gate.process(frame, suppressSilence: true)
            var packets = 0
            for action in actions {
                if case .packet(let data) = action { sent.append(data); packets += 1 }
                else { controls.append(action) }
            }
            XCTAssertLessThanOrEqual(packets, 1, "Pre-roll must not create a burst")
            XCTAssertLessThanOrEqual(gate.bufferedPackets, 12)
        }
        XCTAssertEqual(sent.filter { $0 == speech }.count, 2)
        XCTAssertEqual(controls, [.unmute, .mute])
        XCTAssertGreaterThan(sent.count, 30, "Hangover must let the server detect speech end")
        XCTAssertEqual(gate.process(silence, suppressSilence: true), [])
    }
    func testQuietSpeechPauseAndSecondUtteranceAreNotCut() {
        var gate = SpeechGate()
        let silence = pcm(0), quiet = pcm(150)
        var sent = [Data]()
        var unmuteCount = 0
        for frame in Array(repeating: silence, count: 25) + Array(repeating: quiet, count: 30)
            + Array(repeating: silence, count: 15) + Array(repeating: quiet, count: 30)
            + Array(repeating: silence, count: 50) {
            for action in gate.process(frame, suppressSilence: true) {
                if case .packet(let data) = action { sent.append(data) }
                if action == .unmute { unmuteCount += 1 }
            }
        }
        XCTAssertEqual(sent.filter { $0 == quiet }.count, 60)
        XCTAssertEqual(unmuteCount, 1, "A 300 ms pause must remain one utterance")
        for _ in 0..<15 { _ = gate.process(quiet, suppressSilence: true) }
        XCTAssertLessThanOrEqual(gate.bufferedPackets, 12)
    }
    func testGateCanBeDisabledAndResetDoesNotLeakAnOldUtterance() {
        var gate = SpeechGate()
        let silence = pcm(0)
        XCTAssertEqual(gate.process(silence, suppressSilence: false), [.unmute, .packet(silence)])
        XCTAssertEqual(gate.process(silence, suppressSilence: false), [.packet(silence)])
        gate.reset()
        XCTAssertEqual(gate.process(silence, suppressSilence: true), [.mute])
        XCTAssertEqual(gate.process(Data(count: 12), suppressSilence: true), [])
    }
    func testBufferWaitsThenRecoversFromUnderrunAndFlushesShortEnding() throws {
        var buffer = PlaybackBufferPolicy()
        XCTAssertFalse(try buffer.append(frames: 6000))
        XCTAssertTrue(try buffer.append(frames: 6000))
        buffer.complete(frames: 12000)
        XCTAssertFalse(buffer.playing)
        XCTAssertEqual(buffer.targetSeconds, 1)
        XCTAssertEqual(buffer.underruns, 1)
        XCTAssertFalse(try buffer.append(frames: 12000))
        XCTAssertTrue(try buffer.append(frames: 12000))
        buffer.complete(frames: 24000)
        XCTAssertEqual(buffer.targetSeconds, 1.5)
        buffer.nextResponse()
        XCTAssertFalse(try buffer.append(frames: 2400))
        XCTAssertTrue(buffer.finish(), "A short completed answer must not wait forever")
        buffer.complete(frames: 2400)
        XCTAssertEqual(buffer.seconds, 0)
        XCTAssertEqual(buffer.underruns, 2, "Completed audio is not an underrun")
        buffer.nextResponse()
        XCTAssertThrowsError(try buffer.append(frames: 720001))
    }
    func testRetryDelaysAndTerminalServerErrors() {
        XCTAssertEqual((0..<7).map { ReconnectPolicy.delay(attempt: $0) }, [0, 1, 2, 4, 8, 8, 8])
        XCTAssertGreaterThanOrEqual(ReconnectPolicy.delay(attempt: 0, throttled: true), 4)
        for code in ["50000000", "503", "429"] { XCTAssertTrue(ReconnectPolicy.retryServerCode(code)) }
        for code in ["403", "45000001", "400", "42000020"] { XCTAssertFalse(ReconnectPolicy.retryServerCode(code)) }
        XCTAssertFalse(ReconnectPolicy.retryServerCode(nil))
        XCTAssertFalse(ReconnectPolicy.retryServerCode("55000001", message: "ClientError:InvalidSpeaker"))
    }
    func testDelayedCompletionsAreAcceptedButByteAndTimeBudgetsRemainBounded() {
        var budget = SendBudget()
        var ids = [UUID]()
        for _ in 0..<40 {
            XCTAssertTrue(budget.accepts(bytes: 200, control: false, now: 0.8))
            ids.append(budget.insert(bytes: 200, now: 0))
        }
        XCTAssertEqual(budget.bytes, 8000)
        XCTAssertFalse(budget.accepts(bytes: 200, control: false, now: 2.1))
        XCTAssertTrue(budget.accepts(bytes: 200, control: true, now: 2.1))
        for id in ids { budget.complete(id) }
        XCTAssertTrue(budget.accepts(bytes: 200, control: false, now: 2.1))
        _ = budget.insert(bytes: SendBudget.maximumBytes, now: 3)
        XCTAssertFalse(budget.accepts(bytes: 1, control: false, now: 3))
        budget.reset(); XCTAssertEqual(budget.count, 0)
    }
    func testOldSettingsEnableSavingsWithoutChangingExistingVoiceOrInstructions() throws {
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"voice":"my-voice","instructions":"原风格"}"#.utf8))
        XCTAssertEqual(settings.uploadRate, .balanced)
        XCTAssertTrue(settings.suppressSilence)
        XCTAssertEqual(settings.voice, "my-voice")
        XCTAssertEqual(settings.instructions, "原风格")
    }
}

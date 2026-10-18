import XCTest
@testable import WatchAICore

final class ProtocolTests: XCTestCase {
    func event(_ object: [String: Any]) throws -> ServerEvent {
        try ServerEvent(data: JSONSerialization.data(withJSONObject: object))
    }

    func testSessionDefaultsToCompressedDuplexFormatsAndTopLevelExtension() throws {
        let encoded = try DoubaoProtocol.encode(DoubaoProtocol.createSession(settings: VoiceSettings()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["model"] as? String, "1.2.6.1")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "ogg_opus")
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let inputFormat = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(inputFormat["type"] as? String, "speech_opus")
        XCTAssertEqual(inputFormat["rate"] as? Int, 16000)
        XCTAssertEqual(format["rate"] as? Int, 24000)
        XCTAssertEqual(output["voice"] as? String, "zh_female_vv_jupiter_bigtts")
        XCTAssertNotNil(object["extension"])
        XCTAssertNil(object["api_key"])
    }


    func testCompatibleModeAndExistingSettingsKeepVoiceAndInstructions() throws {
        let old = Data(#"{"voice":"custom_voice","instructions":"保持这个风格"}"#.utf8)
        var settings = try JSONDecoder().decode(VoiceSettings.self, from: old)
        XCTAssertEqual(settings.voice, "custom_voice")
        XCTAssertEqual(settings.instructions, "保持这个风格")
        XCTAssertEqual(settings.bandwidthMode, .economy)
        XCTAssertFalse(settings.webSearchEnabled)
        XCTAssertEqual(settings.webSearchType, .custom)
        settings.bandwidthMode = .compatible
        let session = try XCTUnwrap(DoubaoProtocol.createSession(settings: settings)["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual((input["format"] as? [String: Any])?["type"] as? String, "pcm")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "pcm_s16le")
        XCTAssertEqual(try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertNil(DoubaoProtocol.audio(Data([1, 2]))["event_id"])
    }


    func testWebSearchUsesSeparateKeyForBothSupportedServices() throws {
        for type in VoiceSettings.WebSearchType.allCases {
            var settings = VoiceSettings()
            settings.webSearchEnabled = true
            settings.webSearchType = type
            let session = try DoubaoProtocol.createSession(settings: settings, searchAPIKey: "  fixture-search-key\n")
            let extensions = try XCTUnwrap(session["extension"] as? [String: Any])
            let dialog = try XCTUnwrap(extensions["dialog"] as? [String: Any])
            let extra = try XCTUnwrap(dialog["extra"] as? [String: Any])
            XCTAssertEqual(extra["enable_volc_websearch"] as? Bool, true)
            XCTAssertEqual(extra["volc_websearch_type"] as? String, type.rawValue)
            XCTAssertEqual(extra["volc_websearch_api_key"] as? String, "fixture-search-key")
            XCTAssertEqual(extra["enable_loudness_norm"] as? Bool, true)
            let instructions = try XCTUnwrap((session["session"] as? [String: Any])?["instructions"] as? String)
            XCTAssertTrue(instructions.hasPrefix(settings.instructions))
            XCTAssertTrue(instructions.contains("查询失败"))
            XCTAssertFalse(instructions.contains("fixture-search-key"))
            let persisted = try JSONEncoder().encode(settings)
            XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains("fixture-search-key"))
            XCTAssertEqual(try JSONDecoder().decode(VoiceSettings.self, from: persisted), settings)
        }
    }

    func testSearchWithoutKeyFailsAndDisabledSearchDoesNotSendStoredKey() throws {
        var settings = VoiceSettings()
        let session = try DoubaoProtocol.createSession(settings: settings, searchAPIKey: "stored-secret")
        XCTAssertFalse(try DoubaoProtocol.encode(session).contains("stored-secret"))
        XCTAssertFalse(try DoubaoProtocol.encode(session).contains("volc_websearch"))
        XCTAssertTrue(((session["session"] as? [String: Any])?["instructions"] as? String)?.hasPrefix(settings.instructions) == true)
        settings.webSearchEnabled = true
        for key in ["", "  \n"] {
            XCTAssertThrowsError(try DoubaoProtocol.createSession(settings: settings, searchAPIKey: key)) { error in
                guard case ProtocolError.missingSearchKey = error else { return XCTFail("Wrong missing search credential error") }
            }
        }
    }

    func testInterleavedTurnsAndLateFinalAreKeptSeparate() throws {
        var transcript = Transcript()
        try transcript.apply(event(["type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "今天"] ))
        try transcript.apply(event(["type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "今天怎么样"] ))
        try transcript.apply(event(["type": "response.output_text.delta", "response_id": "r1", "delta": "很好"] ))
        try transcript.apply(event(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "今天怎么样？"] ))
        XCTAssertEqual(transcript.messages.map(\.text), ["今天怎么样？", "很好"])
        XCTAssertTrue(transcript.messages[0].isComplete)
        try transcript.apply(event(["type": "response.output_text.done", "response_id": "r1", "text": "很好。"] ))
        XCTAssertEqual(transcript.messages[1].text, "很好。")
    }

    func testInterruptionDiscardsLateResponseAndPreservesNewReply() throws {
        var transcript = Transcript()
        try transcript.apply(event(["type": "response.output_text.delta", "response_id": "r1", "delta": "旧回答"] ))
        try transcript.apply(event(["type": "conversation.item.input_audio_transcription.started", "item_id": "u2"] ))
        try transcript.apply(event(["type": "response.output_text.delta", "response_id": "r1", "delta": "不应显示"] ))
        try transcript.apply(event(["type": "response.output_text.delta", "response_id": "r2", "delta": "新回答"] ))
        try transcript.apply(event(["type": "response.canceled"] ))
        XCTAssertEqual(transcript.messages.map(\.text), ["旧回答", "新回答"])
        XCTAssertTrue(transcript.messages[0].isInterrupted)
        XCTAssertFalse(transcript.messages[1].isInterrupted)
    }

    func testPacketBoundariesAndOverflow() throws {
        var buffer = PCMBuffer()
        try buffer.append(Data(repeating: 1, count: 1000))
        XCTAssertEqual(buffer.nextPacket()?.count, 640)
        XCTAssertNil(buffer.nextPacket())
        try buffer.append(Data(repeating: 2, count: 280))
        let packet = try XCTUnwrap(buffer.nextPacket())
        XCTAssertEqual(packet.prefix(360), Data(repeating: 1, count: 360))
        XCTAssertEqual(packet.suffix(280), Data(repeating: 2, count: 280))
        XCTAssertThrowsError(try buffer.append(Data(count: PCMBuffer.maximumBytes + 1))) { error in
            guard case ProtocolError.microphoneBacklog = error else {
                return XCTFail("Capture overflow must not be reported as a network error")
            }
        }
    }

    func testInterruptAfterTextFinishesWhileAudioStillPlays() throws {
        var transcript = Transcript()
        try transcript.apply(event(["type": "response.output_text.done", "response_id": "r1", "text": "完整回答"] ))
        try transcript.apply(event(["type": "response.done", "response_id": "r1"] ))
        transcript.interruptAssistant(responseID: "r1")
        try transcript.apply(event(["type": "response.output_text.delta", "response_id": "r1", "delta": "迟到内容"] ))
        XCTAssertEqual(transcript.messages[0].text, "完整回答")
        XCTAssertTrue(transcript.messages[0].isInterrupted)
    }

    func testAudioAndErrors() throws {
        let data = Data([0, 1, 255, 127])
        let audio = try event(["type": "response.output_audio.delta", "delta": data.base64EncodedString()])
        XCTAssertEqual(audio.audioData, data)
        let failure = try event(["type": "error", "error": ["code": 45000001, "message": "InvalidSpeaker"]])
        XCTAssertEqual(failure.statusCode, "45000001")
        XCTAssertEqual(failure.errorMessage, "InvalidSpeaker")
        XCTAssertThrowsError(try ServerEvent(data: Data("{}".utf8)))
    }
}

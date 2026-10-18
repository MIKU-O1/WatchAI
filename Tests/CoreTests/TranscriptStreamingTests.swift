import XCTest
@testable import WatchAICore

final class TranscriptStreamingTests: XCTestCase {
    private func event(_ type: String, fields: [String: Any]) throws -> ServerEvent {
        var object = fields
        object["type"] = type
        return try ServerEvent(data: JSONSerialization.data(withJSONObject: object))
    }

    func testASRHypothesesReplaceIncludingRepeatedTextAndRevisions() throws {
        var transcript = Transcript()
        let type = "conversation.item.input_audio_transcription.delta"
        for hypothesis in ["今天", "今天", "今天心情不好", "今天心情不太好"] {
            transcript.apply(try event(type, fields: ["item_id": "u1", "delta": hypothesis]))
            XCTAssertEqual(transcript.messages.map(\.text), [hypothesis])
        }
        // Repeated words spoken by the user are legitimate and must remain.
        transcript.apply(try event(type, fields: ["item_id": "u1", "delta": "谢谢，谢谢"] ))
        XCTAssertEqual(transcript.messages[0].text, "谢谢，谢谢")
    }

    func testAssistantDeltasStillAppendAndFinalASRRejectsLateHypothesis() throws {
        var transcript = Transcript()
        transcript.apply(try event("conversation.item.input_audio_transcription.completed",
                                   fields: ["item_id": "u1", "transcript": "今天怎么样？"]))
        transcript.apply(try event("conversation.item.input_audio_transcription.delta",
                                   fields: ["item_id": "u1", "delta": "今天"]))
        for word in ["好", "好", "休息"] {
            transcript.apply(try event("response.output_text.delta", fields: ["response_id": "a1", "delta": word]))
        }
        XCTAssertEqual(transcript.messages.map(\.text), ["今天怎么样？", "好好休息"])
    }

    func testIDLessASRUpdatesRemainOneUtterance() throws {
        var transcript = Transcript()
        transcript.apply(try event("conversation.item.input_audio_transcription.started", fields: [:]))
        for text in ["帮我", "帮我设闹钟"] {
            transcript.apply(try event("conversation.item.input_audio_transcription.delta", fields: ["text": text]))
        }
        transcript.apply(try event("conversation.item.input_audio_transcription.completed", fields: ["transcript": "帮我设闹钟。"] ))
        XCTAssertEqual(transcript.messages.map(\.text), ["帮我设闹钟。"])
        XCTAssertTrue(transcript.messages[0].isComplete)
    }
}

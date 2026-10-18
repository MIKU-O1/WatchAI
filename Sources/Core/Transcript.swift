import Foundation

public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: String
    public let role: Role
    public var text: String
    public var isComplete = false
    public var isInterrupted = false
}

/// Keeps independent ASR and response IDs: late final events must not overwrite a newer turn.
public struct Transcript: Sendable {
    public private(set) var messages: [TranscriptMessage] = []
    private var activeUserID: String?
    private var activeAssistantID: String?
    private var canceledResponses: Set<String> = []
    public init() {}

    public mutating func clear() { self = Transcript() }

    public mutating func interruptAssistant(responseID: String? = nil) {
        guard let id = responseID ?? activeAssistantID else { return }
        canceledResponses.insert(id)
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isInterrupted = true
            messages[index].isComplete = true
        }
        activeAssistantID = nil
    }

    public mutating func finishOpenMessages() {
        for index in messages.indices { messages[index].isComplete = true }
        activeUserID = nil
        activeAssistantID = nil
    }

    public mutating func apply(_ event: ServerEvent) {
        switch event.type {
        case "conversation.item.input_audio_transcription.started":
            interruptAssistant()
            activeUserID = event.itemID ?? UUID().uuidString
        case "conversation.item.input_audio_transcription.delta":
            let id = event.itemID ?? activeUserID ?? UUID().uuidString
            activeUserID = id
            // ASR sends a revised hypothesis for the whole utterance. The
            // official Web demo replaces it; assistant text deltas are appended.
            update(id: id, role: .user, delta: nil, final: event.text ?? event.delta, complete: false)
        case "conversation.item.input_audio_transcription.completed":
            let id = event.itemID ?? activeUserID ?? UUID().uuidString
            update(id: id, role: .user, delta: nil, final: event.text, complete: true)
            if activeUserID == id { activeUserID = nil }
        case "response.output_text.delta", "response.output_text.done":
            let id = event.responseID ?? activeAssistantID ?? UUID().uuidString
            guard !canceledResponses.contains(id) else { return }
            let done = event.type == "response.output_text.done"
            if !done { activeAssistantID = id }
            update(id: id, role: .assistant, delta: done ? nil : event.delta,
                   final: done ? event.text : nil, complete: done)
        case "response.done":
            let id = event.responseID ?? activeAssistantID
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].isComplete = true }
            if activeAssistantID == id { activeAssistantID = nil }
        case "response.canceled": break // The client or ASR-start event already interrupted the exact response.
        default: break
        }
    }

    private mutating func update(id: String, role: TranscriptMessage.Role, delta: String?, final: String?, complete: Bool) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            // A delayed hypothesis must not undo the final recognition result.
            if role == .user, messages[index].isComplete, !complete { return }
            if let final, !final.isEmpty { messages[index].text = final }
            else if let delta { messages[index].text += delta }
            messages[index].isComplete = messages[index].isComplete || complete
        } else {
            let text = final ?? delta ?? ""
            guard !text.isEmpty else { return }
            messages.append(.init(id: id, role: role, text: text, isComplete: complete))
            if messages.count > 100 { messages.removeFirst(messages.count - 100) }
        }
    }
}

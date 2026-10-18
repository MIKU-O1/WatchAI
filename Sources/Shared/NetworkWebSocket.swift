import Foundation
import Network

protocol VoiceWebSocket: Sendable {
    func resume()
    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func receive() async throws -> Data
    func cancel()
}

extension VoiceWebSocket {
    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(text) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

/// Uses the in-process Network stack, including TLS certificate validation and WebSocket masking.
/// The URL argument is injectable for a local transport smoke test; the app always uses Doubao's WSS URL.
final class NetworkWebSocket: VoiceWebSocket, @unchecked Sendable {
    enum State: Sendable {
        case preparing, waiting(String), ready, failed(String), cancelled
    }
    private let connection: NWConnection

    init(url: URL, apiKey: String, onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 2 * 1024 * 1024
        options.setAdditionalHeaders([(name: "X-Api-Key", value: apiKey)])
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil,
                                      tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .setup, .preparing: onStateChange(.preparing)
            case .waiting(let error): onStateChange(.waiting(String(describing: error)))
            case .ready: onStateChange(.ready)
            case .failed(let error): onStateChange(.failed(String(describing: error)))
            case .cancelled: onStateChange(.cancelled)
            @unknown default: break
            }
        }
    }

    func resume() { connection.start(queue: DispatchQueue(label: "com.watchai.websocket", qos: .userInitiated)) }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in completion(error) })
    }

    func receive() async throws -> Data {
        while true {
            let data: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receiveMessage { data, context, _, error in
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if metadata?.opcode == .close, let metadata {
                        let code: UInt16
                        switch metadata.closeCode {
                        case .protocolCode(let defined): code = defined.rawValue
                        case .applicationCode(let value), .privateCode(let value): code = value
                        @unknown default: code = 1006
                        }
                        // Some Network versions include the two-byte close code.
                        var reason = data ?? Data()
                        if reason.count >= 2, UInt16(reason[reason.startIndex]) << 8 | UInt16(reason[reason.startIndex + 1]) == code {
                            reason = Data(reason.dropFirst(2))
                        }
                        continuation.resume(throwing: TransportError.serverClosed(code: Int(code), reason: String(data: reason, encoding: .utf8)))
                        return
                    }
                    if let error { continuation.resume(throwing: error); return }
                    switch metadata?.opcode {
                    case .text, .binary, .cont:
                        continuation.resume(returning: data)
                    case .ping, .pong:
                        continuation.resume(returning: nil)
                    case .close, .none:
                        continuation.resume(throwing: TransportError.closed)
                    @unknown default:
                        continuation.resume(throwing: TransportError.closed)
                    }
                }
            }
            if let data { return data }
        }
    }

    func cancel() { connection.cancel() }

    enum TransportError: LocalizedError {
        case closed
        case serverClosed(code: Int, reason: String?)
        var errorDescription: String? {
            switch self {
            case .closed: return "服务器关闭了语音连接。"
            case .serverClosed(let code, let reason):
                let detail = reason.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }.map { "：\($0)" } ?? "。"
                return "服务端关闭连接（WebSocket \(code)）\(detail)"
            }
        }
    }
}

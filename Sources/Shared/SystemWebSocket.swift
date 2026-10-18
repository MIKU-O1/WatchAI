import Foundation

/// Uses the system WebSocket implementation as a fallback for paths on which
/// the in-process Network connection cannot complete its handshake.
final class SystemWebSocket: NSObject, VoiceWebSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let onStateChange: @Sendable (NetworkWebSocket.State) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL, apiKey: String, onStateChange: @escaping @Sendable (NetworkWebSocket.State) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.timeoutInterval = 15
        self.request = request
        self.onStateChange = onStateChange
        super.init()
    }

    // Lifecycle methods are called on the client's main actor. The task and
    // session are assigned before send/receive and remain until cancellation.
    func resume() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 * 1024 * 1024
        self.session = session
        self.task = task
        onStateChange(.preparing)
        task.resume()
    }

    func send(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        guard let task else { completion(CancellationError()); return }
        task.send(.string(text)) { [self] error in
            completion(error.map { responseError(task: task, underlying: $0) })
        }
    }

    func receive() async throws -> Data {
        guard let task else { throw CancellationError() }
        do {
            switch try await task.receive() {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: throw NetworkWebSocket.TransportError.closed
            }
        } catch { throw responseError(task: task, underlying: error) }
    }

    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onStateChange(.ready)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onStateChange(.failed(NetworkWebSocket.TransportError.serverClosed(code: closeCode.rawValue,
            reason: reason.flatMap { String(data: $0, encoding: .utf8) }).localizedDescription))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled else { return }
        onStateChange(.failed(responseError(task: task, underlying: error).localizedDescription))
    }

    private func responseError(task: URLSessionTask, underlying: Error) -> Error {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return underlying }
        let code = response.statusCode
        let message: String
        switch code {
        case 400, 401, 403:
            message = "语音服务拒绝连接（HTTP \(code)）。请检查豆包语音 API Key 和全双工服务权限。"
        case 502, 503, 504:
            message = "语音网络或服务暂时不可用（HTTP \(code)），请稍后重试。"
        default: message = "语音连接返回 HTTP \(code)。"
        }
        return NSError(domain: "WatchAISpeechHTTP", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

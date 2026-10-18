import Foundation

@main
struct TransportSmoke {
    static func main() async throws {
        let socket = NetworkWebSocket(url: URL(string: CommandLine.arguments[1])!, apiKey: "local-fixture-key")
        socket.resume()
        defer { socket.cancel() }
        try await socket.send("hello")
        let first = try await socket.receive()
        let event = try ServerEvent(data: first)
        guard event.type == "response.output_text.delta", event.delta == "你好" else {
            throw NSError(domain: "TransportSmoke", code: 1)
        }
        try await socket.send("session.close")
        let closed = try ServerEvent(data: await socket.receive())
        guard closed.type == "session.closed" else { throw NSError(domain: "TransportSmoke", code: 2) }
        print("PASS: Network WebSocket auth header, masked upload, ping/pong, fragmented UTF-8 text and close response")
    }
}

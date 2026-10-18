#!/usr/bin/env python3
"""Local-only WebSocket transport test; uses a dummy key and no third-party Python packages."""
import base64
import hashlib
import json
import socket
import struct
import subprocess
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
binary = "/tmp/watchai-transport-smoke"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(ROOT / "Sources/Shared/NetworkWebSocket.swift"),
                str(ROOT / "Sources/Core/DoubaoProtocol.swift"),
                str(ROOT / "Sources/Core/WeakNetworkPolicies.swift"), str(ROOT / "Sources/Core/PCMBuffer.swift"), str(ROOT / "Scripts/transport_smoke.swift"),
                "-o", binary], check=True)
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(1)
port = listener.getsockname()[1]
failures = []


def exact(connection, count):
    result = b""
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise EOFError("Unexpected close")
        result += part
    return result


def read_frame(connection):
    flags, length = exact(connection, 2)
    masked = bool(length & 128)
    length &= 127
    if length == 126:
        length = struct.unpack("!H", exact(connection, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exact(connection, 8))[0]
    mask = exact(connection, 4) if masked else None
    payload = exact(connection, length)
    if mask:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return flags & 15, payload, masked


def send_frame(connection, flags, payload):
    assert len(payload) < 126
    connection.sendall(bytes([flags, len(payload)]) + payload)


def serve():
    try:
        with listener.accept()[0] as connection:
            connection.settimeout(10)
            headers = b""
            while not headers.endswith(b"\r\n\r\n"):
                headers += exact(connection, 1)
            lines = headers.decode().split("\r\n")
            assert lines[0].startswith("GET /duplex ")
            fields = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip() for line in lines[1:] if ":" in line}
            assert fields["x-api-key"] == "local-fixture-key"
            accept = base64.b64encode(hashlib.sha1((fields["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
            connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
            opcode, payload, masked = read_frame(connection)
            assert opcode == 1 and masked and payload == b"hello"
            send_frame(connection, 0x89, b"check")
            data = json.dumps({"type": "response.output_text.delta", "response_id": "smoke", "delta": "你好"}, ensure_ascii=False).encode()
            # Deliberately split in the middle of the first Chinese character.
            split = data.index("你".encode()) + 1
            send_frame(connection, 0x01, data[:split])
            send_frame(connection, 0x80, data[split:])
            got_pong = False
            while True:
                opcode, payload, masked = read_frame(connection)
                assert masked
                if opcode == 10:
                    assert payload == b"check"
                    got_pong = True
                elif opcode == 1:
                    assert payload == b"session.close"
                    break
            assert got_pong
            send_frame(connection, 0x81, b'{"type":"session.closed"}')
    except BaseException as error:
        failures.append(error)
    finally:
        listener.close()


thread = threading.Thread(target=serve, daemon=True)
thread.start()
result = subprocess.run([binary, f"ws://127.0.0.1:{port}/duplex"], timeout=15, capture_output=True, text=True)
thread.join(timeout=2)
if failures:
    raise failures[0]
if result.returncode:
    raise RuntimeError(result.stderr)
print(result.stdout.strip())

lifecycle_binary = "/tmp/watchai-client-lifecycle-smoke"
subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                str(ROOT / "Sources/Shared/NetworkWebSocket.swift"),
                str(ROOT / "Sources/Shared/SystemWebSocket.swift"),
                str(ROOT / "Sources/Shared/RealtimeClient.swift"),
                str(ROOT / "Sources/Core/DoubaoProtocol.swift"),
                str(ROOT / "Sources/Core/WeakNetworkPolicies.swift"), str(ROOT / "Sources/Core/PCMBuffer.swift"),
                str(ROOT / "Scripts/client_lifecycle_smoke.swift"), "-o", lifecycle_binary], check=True)
result = subprocess.run([lifecycle_binary], timeout=15, capture_output=True, text=True)
if result.returncode:
    raise RuntimeError(result.stderr)
print(result.stdout.strip())

# Exercise the actual client startup and rejection paths with the same local fixture.
client_binary = "/tmp/watchai-realtime-smoke"
subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                str(ROOT / "Sources/Shared/NetworkWebSocket.swift"),
                str(ROOT / "Sources/Shared/RealtimeClient.swift"),
                str(ROOT / "Sources/Shared/SystemWebSocket.swift"),
                str(ROOT / "Sources/Core/DoubaoProtocol.swift"),
                str(ROOT / "Sources/Core/WeakNetworkPolicies.swift"), str(ROOT / "Sources/Core/PCMBuffer.swift"),
                str(ROOT / "Scripts/realtime_smoke.swift"), "-o", client_binary], check=True)


def test_session(rejection, system=False, fallback=False):
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(20)
    port = server.getsockname()[1]
    errors = []

    def handle():
        try:
            if fallback:
                with server.accept()[0] as first:
                    first.settimeout(10)
                    headers = b""
                    while not headers.endswith(b"\r\n\r\n"):
                        headers += exact(first, 1)
                    assert b"X-Api-Key: local-fixture-key" in headers
                    # Reject the native handshake, then accept the system retry.
                    # There must be no session.create on the rejected connection.
                    first.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            with server.accept()[0] as connection:
                connection.settimeout(10)
                headers = b""
                while not headers.endswith(b"\r\n\r\n"):
                    headers += exact(connection, 1)
                fields = {line.split(":", 1)[0].lower(): line.split(":", 1)[1].strip()
                          for line in headers.decode().split("\r\n")[1:] if ":" in line}
                assert fields["x-api-key"] == "local-fixture-key"
                if rejection:
                    connection.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    return
                accept = base64.b64encode(hashlib.sha1((fields["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
                connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                opcode, payload, masked = read_frame(connection)
                assert opcode == 1 and masked
                request = json.loads(payload)
                assert request["type"] == "session.create"
                assert request["session"]["model"] == "1.2.6.1"
                send_frame(connection, 0x81, b'{"type":"session.created","session":{"id":"local"}}')
                opcode, payload, masked = read_frame(connection)
                assert opcode == 1 and masked and json.loads(payload)["type"] == "session.close"
                send_frame(connection, 0x81, b'{"type":"session.closed"}')
        except BaseException as error:
            errors.append(error)
        finally:
            server.close()

    thread = threading.Thread(target=handle, daemon=True)
    thread.start()
    args = [client_binary, f"ws://127.0.0.1:{port}/duplex"]
    if rejection:
        args.append("--reject")
    if system:
        args.append("--system")
    if fallback:
        args.append("--fallback")
    result = subprocess.run(args, timeout=20, capture_output=True, text=True)
    thread.join(timeout=2)
    if errors:
        raise errors[0]
    if result.returncode:
        raise RuntimeError(result.stderr)
    print(result.stdout.strip())


test_session(False)
test_session(False, system=True)
test_session(True, system=True)
test_session(False, fallback=True)

backpressure_binary = "/tmp/watchai-backpressure-smoke"
subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                str(ROOT / "Sources/Shared/NetworkWebSocket.swift"),
                str(ROOT / "Sources/Shared/SystemWebSocket.swift"),
                str(ROOT / "Sources/Shared/RealtimeClient.swift"),
                str(ROOT / "Sources/Core/DoubaoProtocol.swift"),
                str(ROOT / "Sources/Core/WeakNetworkPolicies.swift"), str(ROOT / "Sources/Core/PCMBuffer.swift"),
                str(ROOT / "Scripts/backpressure_smoke.swift"), "-o", backpressure_binary], check=True)
result = subprocess.run([backpressure_binary], timeout=10, capture_output=True, text=True)
if result.returncode:
    raise RuntimeError(result.stderr)
print(result.stdout.strip())

#!/usr/bin/env python3
"""Optional interoperability check using an independently installed libopus (test only)."""
import base64
import ctypes
import ctypes.util
import json
import math
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
library = ctypes.util.find_library("opus")
if not library:
    candidate = Path("/opt/homebrew/lib/libopus.dylib")
    if candidate.exists():
        library = str(candidate)
if not library:
    raise SystemExit("Reference test requires local libopus; the Watch app has no such dependency.")
binary = "/tmp/watchai-opus-reference-smoke"
subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                str(ROOT / "Sources/Core/DoubaoProtocol.swift"),
                str(ROOT / "Sources/Core/OggOpusStream.swift"),
                str(ROOT / "Sources/Shared/OpusCodec.swift"),
                str(ROOT / "Scripts/opus_reference_smoke.swift"), "-o", binary], check=True)
opus = ctypes.CDLL(library)
opus.opus_decoder_create.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
opus.opus_decoder_create.restype = ctypes.c_void_p
opus.opus_decode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int16), ctypes.c_int, ctypes.c_int]
opus.opus_decode.restype = ctypes.c_int
opus.opus_decoder_destroy.argtypes = [ctypes.c_void_p]
for rate in (8000, 12000, 16000):
    packets = json.loads(subprocess.check_output([binary, str(rate)], timeout=15))
    error = ctypes.c_int()
    decoder = opus.opus_decoder_create(16000, 1, ctypes.byref(error))
    assert decoder and error.value == 0
    samples = []
    try:
        for encoded in packets:
            data = base64.b64decode(encoded)
            output = (ctypes.c_int16 * 320)()
            count = opus.opus_decode(decoder, data, len(data), output, 320, 0)
            assert count == 320, f"Invalid 20 ms packet: {count}"
            samples.extend(output)
    finally:
        opus.opus_decoder_destroy(decoder)
    assert len(samples) == 5 * 16000
    steady = samples[16000:]
    rms = math.sqrt(sum(value * value for value in steady) / len(steady)) / 32768
    crossings = sum(a <= 0 < b for a, b in zip(steady, steady[1:]))
    assert 0.10 < rms < 0.17, rms
    assert abs(crossings / 4 - 440) < 3, crossings / 4
    print(f"PASS: target {rate} bps, 250 Apple-encoded packets decoded by independent libopus; 5 s, 440 Hz, RMS {rms:.3f}")

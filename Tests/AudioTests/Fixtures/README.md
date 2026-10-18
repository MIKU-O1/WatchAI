The fixture is a locally generated two-second 440 Hz sine wave, not a recording of a person. It is encoded by FFmpeg's independent libopus encoder, mono 24 kHz, 24 kbps VBR, 20 ms frames:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=24000:duration=2' -c:a libopus -b:a 24k -application voip -frame_duration 20 tone-24k.opus
```

Tests check streaming decode across single-byte boundaries, exact duration after Ogg pre-skip/EOS trimming, pitch, signal energy, chained streams, reset after interruption, and checksum corruption. This synthesized test audio is released under CC0. FFmpeg/libopus are used only to create/verify fixtures; they are not linked into the app.

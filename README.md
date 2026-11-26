# Morse Code Translator

This Linux x86-64 prototype reads clean Morse beeps from a WAV file and prints an ASCII transcription. Build it with NASM, a C compiler, and Make.

```sh
make
./translate sample.wav
```

The included 20 WPM sample prints `SOS 123`. To decode a file at a known speed, run `./translate --wpm 20 recording.wav`. Use 16-bit PCM WAV with one or two channels and regular Morse spacing. Supported speeds range from 5 to 30 WPM. Short recordings can require an explicit speed. Unknown symbols appear as `?`.

C reads and validates WAV chunks, allocates buffers, and handles terminal I/O. NASM measures the audio, detects tone and silence, estimates timing, and translates the Morse symbols. The timing and alphabet follow [ITU-R M.1677](https://www.itu.int/rec/R-REC-M.1677/en).

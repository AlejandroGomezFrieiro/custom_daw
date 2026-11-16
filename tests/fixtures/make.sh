#!/bin/sh
# Regenerates the audio fixtures for tests/suite.lua. Run from this directory:
#   nix shell nixpkgs#ffmpeg nixpkgs#python3 -c sh make.sh
# Each tone is 0.25 s of 440 Hz at 0.5, and at 0.25 on the right of the stereo ones.
set -e
mono="aevalsrc=0.5*sin(2*PI*440*t):d=0.25"
stereo="aevalsrc=0.5*sin(2*PI*440*t)|0.25*sin(2*PI*440*t):d=0.25"
ff="ffmpeg -hide_banner -loglevel error -y -bitexact"
$ff -f lavfi -i "$mono:s=8000" -c:a pcm_s16le tone-mono-8k.wav
$ff -f lavfi -i "$mono:s=11025" -c:a pcm_s16be tone-mono-11k.aiff
$ff -f lavfi -i "$stereo:s=11025" -c:a flac -sample_fmt s16 -compression_level 12 tone-stereo-11k.flac
$ff -f lavfi -i "$stereo:s=44100" -c:a libmp3lame -b:a 64k tone-stereo-44k.mp3
$ff -f lavfi -i "$stereo:s=48000" -c:a libvorbis -q:a 0 tone-stereo-48k.ogg
# A codec that is not supported, for the error message.
$ff -f lavfi -i "$mono:s=48000" -c:a libopus -b:a 16k tone-mono-48k.opus

# A known waveform at 8 kHz, mono: four parts of 500 frames, silence, a sine
# peaking at 0.5, one peaking at 0.75, and -0.25 held.
python3 - <<'PY'
import math, struct, wave
parts = [lambda k: 0, lambda k: 16384 * math.sin(k * math.pi / 8),
         lambda k: 24576 * math.sin(k * math.pi / 8), lambda k: -8192]
frames = [round(part(k)) for part in parts for k in range(500)]
out = wave.open("shape.wav", "wb")
out.setnchannels(1)
out.setsampwidth(2)
out.setframerate(8000)
out.writeframes(struct.pack("<%dh" % len(frames), *frames))
out.close()
PY

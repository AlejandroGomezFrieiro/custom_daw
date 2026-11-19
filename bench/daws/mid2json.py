#!/usr/bin/env python3
# mid2json.py <in.mid> <out.json>: the notes of each track of a Standard
# MIDI File as [start_beats, length_beats, pitch, velocity, channel], with
# the track names and the tempo.
import json, struct, sys

data = open(sys.argv[1], "rb").read()
fmt, ntracks, ppq = struct.unpack(">HHH", data[8:14])
p, tracks, tempo = 14, [], 120.0
for _ in range(ntracks):
    assert data[p:p + 4] == b"MTrk"
    size = struct.unpack(">I", data[p + 4:p + 8])[0]
    q, end, tick, status = p + 8, p + 8 + size, 0, 0
    name, on, notes = "", {}, []
    def var():
        global q
        v = 0
        while True:
            b = data[q]; q += 1
            v = (v << 7) | (b & 0x7F)
            if b < 0x80:
                return v
    while q < end:
        tick += var()
        b = data[q]
        if b >= 0x80:
            status = b; q += 1
        if status == 0xFF:
            kind = data[q]; q += 1
            n = var(); body = data[q:q + n]; q += n
            if kind == 0x03:
                name = body.decode("utf8", "replace")
            elif kind == 0x51:
                tempo = 60e6 / int.from_bytes(body, "big")
        elif status in (0xF0, 0xF7):
            n = var(); q += n
        else:
            hi, ch = status & 0xF0, status & 0x0F
            if hi in (0xC0, 0xD0):
                q += 1; continue
            a, v = data[q], data[q + 1]; q += 2
            if hi == 0x90 and v > 0:
                on.setdefault((ch, a), []).append((tick, v))
            elif hi in (0x80, 0x90):
                if on.get((ch, a)):
                    t0, vel = on[(ch, a)].pop(0)
                    notes.append([t0 / ppq, (tick - t0) / ppq, a, vel, ch])
    p = end
    if notes:
        tracks.append({"name": name, "notes": sorted(notes)})
json.dump({"tempo": tempo, "tracks": tracks}, open(sys.argv[2], "w"))
print(tempo, [(t["name"], len(t["notes"]), t["notes"][0][4]) for t in tracks])

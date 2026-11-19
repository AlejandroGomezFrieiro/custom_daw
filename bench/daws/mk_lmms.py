#!/usr/bin/env python3
# mk_lmms.py <song.json> <out.mmp> <home> [view]: the demo song as an LMMS
# project (a TripleOscillator on each track, LMMS's Delay on the keys,
# ReverbSC on the master), the 8 bars looped; and <home>/.lmmsrc.xml with the
# dummy audio device (512 frames) and folders in <home>. view "mixer"
# maximizes the mixer; otherwise the song editor.
import json, os, sys
from xml.sax.saxutils import quoteattr as q

song = json.load(open(sys.argv[1]))
out, home = sys.argv[2], sys.argv[3]
view = sys.argv[4] if len(sys.argv) > 4 else "arrange"
TPB = 48  # ticks a beat (192 a bar)

def osc(name):
    # The synth of each part, near paw's demo: saw bass, square keys, saw lead,
    # short noise-ish drums from the default sine stack.
    wave = {"Bass": 2, "Keys": 3, "Lead": 2}.get(name, 0)
    return (f'<tripleoscillator wavetype0="{wave}" wavetype1="{wave}" wavetype2="0" vol0="33" vol1="33" vol2="33" '
            'coarse0="0" coarse1="-12" coarse2="-24" modalgo1="2" modalgo2="2" useWaveTable1="1" useWaveTable2="1" useWaveTable3="1"/>')

def fx(name):
    return f'<effect on="1" wet="1" name="{name}" gate="0" autoquit="0"><{name}/></effect>'

tracks, channels = [], []
for ch, t in enumerate(song["tracks"], 1):
    notes = "".join(
        f'<note pos="{round(n[0] * TPB)}" len="{max(1, round(n[1] * TPB))}" key="{n[2] - 12}" vol="{round(n[3] * 100 / 127)}" pan="0"/>'
        for n in t["notes"])
    chain = fx("delay") if t["name"] == "Keys" else ""
    tracks.append(f'''<track muted="0" type="0" name={q(t["name"])} solo="0">
  <instrumenttrack pan="0" mixch="{ch}" usemasterpitch="1" pitchrange="1" pitch="0" basenote="57" vol="80">
    <instrument name="tripleoscillator">{osc(t["name"])}</instrument>
    <fxchain numofeffects="{1 if chain else 0}" enabled="{1 if chain else 0}">{chain}</fxchain>
  </instrumenttrack>
  <pattern pos="0" len="{32 * TPB}" steps="16" muted="0" type="1" name={q(t["name"])}>{notes}</pattern>
</track>''')
    # Each track on a mixer channel of its own, sent to the master.
    channels.append(f'<mixerchannel num="{ch}" muted="0" volume="1" name={q(t["name"])} soloed="0">'
                    '<fxchain numofeffects="0" enabled="0"/><send channel="0" amount="1"/></mixerchannel>')

editor_max = "0" if view == "mixer" else "1"
mixer = 'width="1400" x="0" y="0" maximized="1" height="900" visible="1" minimized="0"' if view == "mixer" else \
        'width="543" x="5" y="310" maximized="0" height="335" visible="0" minimized="0"'
open(out, "w").write(f'''<?xml version="1.0"?>
<!DOCTYPE lmms-project>
<lmms-project version="1.0" creator="LMMS" creatorversion="1.2.0" type="song">
  <head timesig_numerator="4" mastervol="100" timesig_denominator="4" bpm="{round(song["tempo"])}" masterpitch="0"/>
  <song>
    <trackcontainer width="1400" x="0" y="0" maximized="{editor_max}" height="900" visible="1" type="song" minimized="0">
      {"".join(tracks)}
    </trackcontainer>
    <mixer {mixer}>
      <mixerchannel num="0" muted="0" volume="1" name="Master" soloed="0">
        <fxchain numofeffects="1" enabled="1">{fx("reverbsc")}</fxchain>
      </mixerchannel>
      {"".join(channels)}
    </mixer>
    <timeline lp1pos="{32 * TPB}" lp0pos="0" lpstate="1"/>
    <controllers/>
  </song>
</lmms-project>
''')

docs = os.path.join(home, "Documents", "lmms")
for d in ("", "plugins/ladspa", "plugins/vst", "samples/gig", "samples/soundfonts", "projects", "presets"):
    os.makedirs(os.path.join(docs, d), exist_ok=True)
open(os.path.join(home, ".lmmsrc.xml"), "w").write(f'''<?xml version="1.0"?>
<!DOCTYPE lmms-config-file>
<lmms version="1.3.0-alpha" configversion="3">
  <app disablebackup="0" openlastproject="0" nommpz="0" loopmarkermode="dual" configured="1" language="en" sololegacybehavior="0" nanhandler="1"/>
  <audioengine audiodev="Dummy (no sound output)" samplerate="44100" framesperaudiobuffer="512" mididev="Dummy (no MIDI support)"/>
  <paths ladspadir="{docs}/plugins/ladspa/" gigdir="{docs}/samples/gig/" defaultsf2="" backgroundtheme="" workingdir="{docs}/" sf2dir="{docs}/samples/soundfonts/" theme="data:/themes/default/" vstdir="{docs}/plugins/vst/"/>
  <ui enableautosave="0" disableautoquit="1"/>
</lmms>
''')

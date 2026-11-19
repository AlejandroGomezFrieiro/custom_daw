#!/usr/bin/env python3
# mk_reaper.py <song.json> <__startup.lua> [view]: a REAPER startup script
# that builds the demo song (a ReaSynth on each track, ReaDelay on the keys,
# a reverb track with ReaVerbate the others send to, as paw's demo does),
# loops the 8 bars and plays. view "mixer" also shows the mixer; view "roll"
# opens the keys' item in the built-in MIDI editor.
import json, sys

song = json.load(open(sys.argv[1]))
view = sys.argv[3] if len(sys.argv) > 3 else "arrange"
out = ["local tempo = %r" % song["tempo"], "local tracks = {"]
for t in song["tracks"]:
    notes = ",".join("{%r,%r,%d,%d,%d}" % tuple(n) for n in t["notes"])
    out.append("  { name = %r, notes = { %s } }," % (t["name"], notes))
out.append("}")
out.append("local view = %r" % view)
out.append(r'''
reaper.SetCurrentBPM(0, tempo, false)
local beats = 32
local len = beats * 60 / tempo
reaper.InsertTrackAtIndex(0, true)
local verb = reaper.GetTrack(0, 0)
reaper.GetSetMediaTrackInfo_String(verb, "P_NAME", "Reverb", true)
reaper.TrackFX_AddByName(verb, "ReaVerbate", false, -1)
for i, t in ipairs(tracks) do
  reaper.InsertTrackAtIndex(i - 1, true) -- before the reverb, which ends last
  local tr = reaper.GetTrack(0, i - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", t.name, true)
  reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
  if t.name == "Keys" then reaper.TrackFX_AddByName(tr, "ReaDelay", false, -1) end
  if t.name ~= "Bass" then reaper.CreateTrackSend(tr, verb) end
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, len, false)
  local take = reaper.GetActiveTake(item)
  for _, n in ipairs(t.notes) do
    local s = reaper.MIDI_GetPPQPosFromProjQN(take, n[1])
    local e = reaper.MIDI_GetPPQPosFromProjQN(take, n[1] + n[2])
    reaper.MIDI_InsertNote(take, false, false, s, e, n[5], n[3], n[4], true)
  end
  reaper.MIDI_Sort(take)
end
reaper.GetSet_LoopTimeRange(true, true, 0, len, false)
reaper.GetSetRepeat(1)
reaper.Main_OnCommand(40295, 0) -- View: Zoom out project
if view ~= "mixer" then reaper.Main_OnCommand(40078, 0) end -- View: Toggle mixer visible (shown by default)
if view == "roll" then
  -- The keys' item in the built-in MIDI editor, as paw's piano roll.
  reaper.Main_OnCommand(40289, 0) -- Item: Unselect all items
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if name == "Keys" then reaper.SetMediaItemSelected(reaper.GetTrackMediaItem(tr, 0), true) end
  end
  reaper.UpdateArrange()
  reaper.Main_OnCommand(40153, 0) -- Item: Open in built-in MIDI editor
end
reaper.OnPlayButton()
local f = io.open(os.getenv("DAW_OUT") .. "/started", "w")
f:write(string.format("editor %s; %d tracks, %d items, play %d, 40295=%s, 40078=%s\n", tostring(reaper.MIDIEditor_GetActive()), reaper.CountTracks(0), reaper.CountMediaItems(0), reaper.GetPlayState(), reaper.kbd_getTextFromCmd(40295, 0), reaper.kbd_getTextFromCmd(40078, 0)))
f:close()
''')
open(sys.argv[2], "w").write("\n".join(out))

-- Lesson 12: recording audio and MIDI.
local api = daw.api

--- What a person does with a MIDI keyboard, done by the tests: three notes.
local function play_three_notes()
  for _, pitch in ipairs({ "C4", "E4", "G4" }) do
    daw.midi.note_on(pitch, 100)
    api.sleep(150)
    daw.midi.note_off(pitch)
    api.sleep(50)
  end
end

return {
  id = "recording",
  title = "Recording audio and MIDI",
  intro = [[
A track records what comes in: audio from an input of your sound card (a
microphone, a guitar), or notes from a MIDI keyboard. Arm the tracks that should
record, press record, play, stop: each armed track gets a new clip where
recording began.

A track with an audio input records audio; an armed track with no input records
MIDI. You need a microphone or other input for the first part and a MIDI
keyboard for the second; without them, read along, and `,hn` skips a step.
Recordings of this practice project go in the tutor's own folder.]],
  idea = [[
In the arrange view: `I` lists what the track can take in (no audio input, each
channel of the input device and each pair such as `UR22mkII · 1/2`, MIDI from
every port or one, one MIDI channel) to choose from, `<A-i>` or the `I` in the
header monitors the input (hear it without recording), `r` arms the
track, `R` starts recording from the playhead and `R` again stops recording while
playback goes on; `<Space>` then stops playing. `:midi.inputs` lists MIDI ports and
`:midi.select` chooses some. `:audio` chooses the input and output devices. Each
take is one undo step.]],
  vim = [[
`r` here arms a track; it does not replace anything. `R` is record, not replace
mode.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 16, notes = look.drums(look.beat, 4) })
    daw.add_track({ name = "Voice" })
    local keys = daw.add_track({ name = "Keys", volume = -6 })
    keys:add_device("synth", { wave = 3, attack = 0.01, release = 0.3, cutoff = 2000 })
  end,
  at = function() daw.cursor.set_track(daw.track("Voice")) end,
  -- The tests' audio engine plays a test tone as its input, the way the suite
  -- tests recording.
  test = {
    before = function() api.engine_restart({ backend = "null", test_input = { frequency = 440, level = -12, channels = 2 } }) end,
    after = function() api.engine_restart({ backend = "null" }) end,
  },
  steps = {
    {
      say = "The cursor is on Voice, a track with no device. `I` lists what it can take in: press `I`, type a few letters of the input your microphone is on (`1/2` for the first pair of channels, `· 1` for the first channel alone) and press `<CR>`. The header then shows it, with the level arriving there.",
      keys = { "I", "1/2", "<CR>" },
      check = function(_, look) return look.track("Voice").input ~= nil end,
      done = "Voice takes its sound from that input. (`<A-i>` would let you hear it without recording.)",
      hint = "If the list has no channels, no input device is open: `:audio` lists the devices and chooses one.",
    },
    {
      say = "`r` arms the track for recording: its `R` lights up red. Press `r`.",
      keys = { "r" },
      check = function(_, look) return look.track("Voice").armed end,
      done = "Armed. An armed track also lets you hear its input.",
    },
    {
      say = "`R` starts recording from the playhead. Press `R`, sing or play for a few seconds, then `R` again to stop recording and `<Space>` to stop playing.",
      keys = { "R", { wait = 1000 }, "R", "<Space>" },
      check = function(_, look)
        local clip = look.clips("Voice")[1]
        return clip and clip.kind == "audio" and not daw.transport.playing and not daw.transport.recording
      end,
      hint = "Stop recording with `R` before `<Space>`: after `<Space>` alone, record mode stays on (`rec` is lit in the status line) and the next `<Space>` records again.",
      done = "A new audio clip with your take, where recording began; its waveform is drawn in it.",
    },
    {
      say = "Now MIDI. Press `r` to disarm Voice, `j` to go to Keys, and `r` to arm it.",
      keys = { "r", "j", "r" },
      check = function(_, look) return not look.track("Voice").armed and look.track("Keys").armed end,
      done = "Keys is armed and has no audio input, so it records MIDI. Play your keyboard: you hear the synth.",
      hint = "`:midi.inputs` lists the MIDI ports paw sees.",
    },
    {
      say = "Press `gs` to go back to the start, `R` to record, play a few notes on your MIDI keyboard, then `R` and `<Space>` to stop.",
      keys = { "gs", "R", { sim = play_three_notes, instead = {} }, "R", "<Space>" },
      check = function(_, look)
        local clip = look.clips("Keys")[1]
        return clip and clip.kind == "midi" and #clip:notes() > 0 and not daw.transport.playing and not daw.transport.recording
      end,
      done = "A MIDI clip with what you played: `<CR>` on it opens it in the piano roll.",
    },
    {
      say = "Disarm Keys with `r`, then listen: `gs`, `<Space>`, and `<Space>` to stop.",
      keys = { "r", "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return not look.track("Keys").armed and look.played(ctx) end,
      done = "Your recordings, with the drums.",
    },
  },
  outro = "`I` for the input, `r` to arm, `R` to record, `<Space>` to stop: an audio take and a MIDI take.",
}

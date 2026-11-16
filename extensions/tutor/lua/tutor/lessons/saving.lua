-- Lesson 13: saving and rendering.
return {
  id = "saving",
  title = "Saving and rendering",
  intro = [[
A project is a file (JSON) with everything in it: tracks, devices and their
settings, clips and notes, automation, the loop. Recordings sit in a `media`
folder beside it. Rendering plays the whole song into a WAV file that any
other program can play.

This practice project already has a file, in the tutor's folder, so `:w` saves
it there. Your own projects are saved wherever you say: `:w song.json`.]],
  idea = [[
`:w` saves (`<C-s>` too), `:w name.json` saves under a new name, `:e name.json`
opens a project (`:e song.mid` makes one of a MIDI file, with no file of its own
until `:w name.json`), `:new` starts an empty one, `:wq` or `ZZ` save and quit, `:q` or
`ZQ` quit without saving. The status line shows the project's name, with `[+]`
when there are changes not saved yet. `:render name.wav` writes the song to a
file; `tail=2` adds two seconds for echoes to die away, `bits=16` makes a 16-bit
file. A relative name is relative to the folder the DAW was started from.]],
  vim = [[
`:w`, `:e`, `:wq`, `:x`, `ZZ`, `ZQ` as in Vim, with projects for files. There
is one project open at a time; `:e` replaces it. `:w name.json` is Vim's
`:saveas`: the project goes on in the new file. Vim's `:w name` writes a copy
and stays in the old one; there is no such copy here.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    drums:add_clip({ name = "beat", start = 0, length = 8, notes = look.drums(look.beat, 2) })
    local keys = daw.add_track({ name = "Keys", volume = -8 })
    keys:add_device("synth", { wave = 3, attack = 0.02, release = 0.5, cutoff = 1800 })
    keys:add_device("delay", { time = 450, feedback = 0.35, mix = 0.25 })
    local chords = look.chord({ "D4", "F4", "A4" }, 4)
    for _, n in ipairs(look.chord({ "C4", "E4", "G4" }, 4, 4)) do chords[#chords + 1] = n end
    keys:add_clip({ name = "chords", start = 0, length = 8, notes = chords })
  end,
  at = function() daw.cursor.set_track(daw.track("Keys")) end,
  test = {
    -- Rendering writes beside where the DAW was started; the test tidies up.
    after = function() os.remove("tutor-song.wav") end,
  },
  steps = {
    {
      say = "Change something first: `&` repeats the chords after themselves. Press `&`: the status line's project name gets a `[+]`.",
      keys = { "&" },
      check = function() return daw.project.modified and #daw.track("Keys"):clips() == 2 end,
      done = "`[+]`: there are changes that are not saved.",
    },
    {
      say = "Type `:w` and `<CR>` to save. (`<C-s>` does the same.)",
      keys = { ":w", "<CR>" },
      check = function(ctx, look) return look.saw(ctx, "project.saved") and not daw.project.modified end,
      done = "Saved: the `[+]` is gone, and the message line says where.",
    },
    {
      say = "`:render` plays the song into a WAV file. Type `:render tutor-song.wav tail=2` and `<CR>`.",
      keys = { ":render tutor-song.wav tail=2", "<CR>" },
      check = function(ctx, look) return look.ran(ctx, "render") and look.said(ctx, "tutor-song.wav") end,
      done = "tutor-song.wav is in the folder you started the DAW from: its length and peak level are on the message line.",
      hint = "`tail=2` keeps two more seconds after the last note, so the echo is not cut off.",
    },
    {
      say = "`:messages` shows the messages you have missed. Type `:messages` and `<CR>`, then `q` to close it.",
      keys = { ":messages", "<CR>", "q" },
      check = function(ctx, look) return look.ran(ctx, "messages") and not look.float() end,
      done = "Every message since the DAW started, saves and renders among them.",
    },
    {
      say = "Listen to the song you rendered in any player. Here, `<Space>` plays it in the DAW; `<Space>` stops.",
      keys = { "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.played(ctx) end,
      done = "Saved and rendered.",
    },
  },
  outro = "`:w` to save, `[+]` for unsaved changes, `:render name.wav tail=2` to make a file, `:messages` for what was said.",
}

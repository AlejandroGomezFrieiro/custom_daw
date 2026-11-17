-- Lesson 16: what each bundled extension adds, one thing to try in each.
local function loaded(name)
  return daw.ext.loaded[name] ~= nil and daw.ext.loaded[name].ok
end

return {
  id = "extensions",
  title = "The bundled extensions",
  intro = [[
Much of what paw can do comes in extensions: directories of Lua in
`extensions/` beside the program, which use the same `daw` module as your
`init.lua`. Seven come with it besides the tutor. This lesson loads each for this session with
`:tutor.try` and tries one thing in it; to have one always, link its directory
into `~/.config/daw/extensions`.

Each extension's README.md says everything it does. Their keys live under
their own prefixes: `]s` `[s` and `,S` (sections), `gz` (musicops), `,t`
(pattern), `,x` and `]d` `[d` (mixdiag), `,u` `g-` `g+` (undotree), `,v`
(utau).]],
  idea = [[
An extension adds commands, keys, text objects, operators and views with the
calls of lesson 15, so what it adds obeys the grammar you know: sections are
text objects (`dis`, `yis`), musicops are operators (`gzkip`), and `.`, counts
and macros work with them.]],
  vim = [[
`:tutor.try name` is like `:packadd`. `:extensions` lists what is loaded.]],
  setup = function(look)
    daw.project.tempo = 100
    local drums = daw.add_track({ name = "Drums", volume = -6 })
    drums:add_device("drums")
    local keys = daw.add_track({ name = "Keys", volume = -8 })
    keys:add_device("synth", { wave = 1, attack = 0.01, release = 0.3, cutoff = 2200 })
    keys:add_clip({ name = "tune", start = 0, length = 8, notes = look.notes("C4:0:1 D4:1:1 E4:2:1 G4:3:1 E4:4:1 D4:5:1 C4:6:2") })
    daw.transport.loop_start, daw.transport.loop_end, daw.transport.loop_enabled = 0, 8, true
  end,
  at = function() daw.cursor.set_track(daw.track("Drums")) end,
  test = {
    after = function() os.remove("tutor-song.rpp") end,
  },
  steps = {
    {
      say = "pattern writes drum parts as text. Type `:tutor.try pattern` and `<CR>`, then `:pattern.set bd*2 [~ sn]` and `<CR>`: a new clip on Drums plays it.",
      keys = { ":tutor.try pattern", "<CR>", ":pattern.set bd*2 [~ sn]", "<CR>" },
      check = function(_, look)
        local clip = look.clips("Drums")[1]
        return loaded("pattern") and clip and #clip:notes() > 0
      end,
      done = "Kick, kick, rest, snare, as a clip. `,tt` edits the text of the clip under the cursor.",
    },
    {
      say = "musicops adds musical operators under `gz`. Type `:tutor.try musicops` and `<CR>`, press `j` to go to Keys, and `gzkic` to move every note of the clip a step up the scale.",
      keys = { ":tutor.try musicops", "<CR>", "j", "gzkic" },
      check = function(_, look)
        return loaded("musicops") and look.melody(look.clip("Keys")) == "62@0+1 64@1+1 65@2+1 69@3+1 65@4+1 64@5+1 62@6+2"
      end,
      done = "D E F A F E D: the tune moved within C major. `gzh` humanizes, `gzs` strums, and `.` repeats any of them.",
    },
    {
      say = "sections names the parts of a song. Type `:tutor.try sections` and `<CR>`, then `,Sa`, type `Verse` and `<CR>` to mark a section at the cursor.",
      keys = { ":tutor.try sections", "<CR>", ",Sa", "Verse", "<CR>" },
      check = function()
        if not loaded("sections") then return false end
        for _, s in ipairs(require("sections").list()) do
          if s.name == "Verse" then return true end
        end
      end,
      done = "Verse is on the ruler. `is` is now a text object: `yis` yanks the section on every track, `]s` goes to the next.",
    },
    {
      say = "undotree shows every state the project has been in. Type `:tutor.try undotree` and `<CR>`, press `,uu` to open the undo tree, look, and `q` to close it.",
      keys = { ":tutor.try undotree", "<CR>", ",uu", "q" },
      check = function(ctx, look)
        if look.float() == "undotree" then ctx.seen = true end
        return loaded("undotree") and ctx.seen and not look.float()
      end,
      done = "Nothing undone is lost: `g-` and `g+` walk through time across branches.",
    },
    {
      say = "mixdiag measures the mix and lists problems. Type `:tutor.try mixdiag` and `<CR>`, then press `,xa` to measure the song.",
      keys = { ":tutor.try mixdiag", "<CR>", ",xa" },
      check = function(ctx, look) return loaded("mixdiag") and look.ran(ctx, "mix.analyze") end,
      done = "It measures in the background; the message line gives the loudness when it is done, and `,xx` lists what it found.",
    },
    {
      say = "rpp opens and writes REAPER projects. Type `:tutor.try rpp` and `<CR>`, then `:rpp.export tutor-song.rpp` and `<CR>`; a list of what REAPER cannot take opens, and `q` closes it.",
      keys = { ":tutor.try rpp", "<CR>", ":rpp.export tutor-song.rpp", "<CR>", "q" },
      check = function(ctx, look) return loaded("rpp") and look.ran(ctx, "rpp.export") and not look.float() end,
      done = "tutor-song.rpp is in the folder you started from. The built-in devices stay behind, as the list said.",
    },
    {
      say = "utau sings notes with lyrics through OpenUtau's engines. Type `:tutor.try utau` and `<CR>`, press `o` for a new track, then type `:utau.voice` and `<CR>` to make it a vocal track.",
      keys = { ":tutor.try utau", "<CR>", "o", ":utau.voice", "<CR>" },
      check = function(_, look)
        for _, t in ipairs(daw.tracks()) do
          if look.device(t, "lua:utau") then return loaded("utau") end
        end
      end,
      done = "A vocal track. It sings once `reautau-engine` and a voicebank are installed (see extensions/utau/README.md); `,v` then adds a vocal track and asks for its singer in one go.",
    },
    {
      say = "Listen to the pattern and the tune: `gs`, `<Space>`, and `<Space>` to stop.",
      keys = { "gs", "<Space>", { wait = 300 }, "<Space>" },
      check = function(ctx, look) return look.ran(ctx, "transport.start") and look.played(ctx) end,
      done = "That is the course.",
    },
  },
  outro = "pattern, musicops, sections, undotree, mixdiag, rpp and utau: each one thing. Their READMEs have the rest.",
}

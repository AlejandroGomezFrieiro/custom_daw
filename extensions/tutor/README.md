# tutor

A course for first-time users, inside paw, in the way `vimtutor` teaches
Vim: sixteen lessons of about ten minutes, each in a practice project of its
own. A panel along the bottom says what to do next in a sentence or two with
the exact keys, notices when it is done, says so, and goes on. Every lesson
ends with something you made or changed and can hear.

The same lessons, as text for reading away from the program, are in
[docs/course](../../docs/course/README.md), with a page of keys to keep beside
the keyboard, [keys.md](../../docs/course/keys.md).

## Start it

```lua
daw.ext.load("/path/to/daw/extensions/tutor")   -- in ~/.config/daw/init.lua
```

or link the directory into `~/.config/daw/extensions`. Then, in paw:

| | |
| --- | --- |
| `:tutor` | the course, where you left off (lesson 1 the first time) |
| `:tutor 5`, `:tutor visual` | a lesson by number or name; one you were in carries on where you were |
| `:tutor list`, `,hl` | the lessons and how far you got, to choose one |
| `,hh` (`:tutor hint`) | a hint for the step |
| `,hn` (`:tutor next`) | skip the step; at the end of a lesson, go on to the next one |
| `,hr` (`:tutor restart`) | start the lesson again from a fresh practice project |
| `,hq` (`:tutor quit`) | leave the tutor and reopen your own project |
| `:tutor reset` | forget all progress |
| `:tutor.try sections` | load one of the bundled extensions for this session (lesson 16) |

A lesson begins with a page about it: what it is about, the idea behind its
keys, and what differs for someone who knows Vim. Any key closes it.

### What happens to the project you have open

A lesson opens its own practice project, so the project you were working on
is closed while you practise, and reopened, as it was on disk, by `,hq`.

- If it has changes that are not saved, the lesson does not start: the tutor
  says so, and you save first (`:w`) or start with `:tutor! 3` to throw the
  changes away.
- An untitled project with nothing in it is simply replaced.
- Nothing is ever written to your project. Your options that lessons change
  (`grid`, `note_grid`, `octave`, `velocity`, `ripple`, `clip_length`) are put
  back when you leave.
- If you open another project during a lesson (`:e`), the tutor waits, and
  `:tutor` goes back to the lesson.

### Where your progress is kept

In the tutor's own directory: `$XDG_STATE_HOME/daw/tutor`
(`~/.local/state/daw/tutor`), or wherever the option `tutor_dir` says.
`progress.lua` holds the lesson and step you are on and the steps you have
done; `practice/<lesson>.json` are the practice projects (and `practice/media`
their recordings). Quitting paw in a lesson (`:q`, `ZZ`, `ZQ`) saves the
practice project and your place; `:tutor` next time carries on from there.
`:reload` keeps the tutor where it was.

## The lessons

| | Lesson | |
| --- | --- | --- |
| 1 | First steps | the screen, playing, `?`, `:`, quitting |
| 2 | Moving around | motions and counts; why keys mean other things in other modes and views |
| 3 | Tracks, clips and notes | `o`, `grn`, `a`, `i`, `&`, `x`, `u` |
| 4 | The piano roll | moving by pitch, changing a note, insert mode, chords |
| 5 | The grammar | operator + motion or text object, counts, `dd`, `.`, on clips |
| 6 | The grammar on notes | the same in the piano roll, and `/` |
| 7 | Visual mode | `v`, `V`, `gv`, a count in visual mode |
| 8 | Registers and macros | `p` with counts, `"a`, `:registers`, `2u`, `qq` `@q` `@@` |
| 9 | Devices | the device panel, parameters, adding and bypassing, plugin windows |
| 10 | Mixing | the mixer, pan, solo, mute, a bus, a send, automation |
| 11 | Loops and marks | `gL`, `gl`, `gm`, `/`, `ma` `'a` `''` |
| 12 | Recording | `I`, `r`, `R`: an audio take and a MIDI take |
| 13 | Saving and rendering | `[+]`, `:w`, `:render`, `:messages` |
| 14 | Finding things | key hints, `:commands`, Tab, `,,` and the `,f` pickers, `K` |
| 15 | Making it your own | an option, a mapping and a command with `:lua`; `init.lua` |
| 16 | The extensions | one thing in each of pattern, musicops, sections, undotree, mixdiag, rpp, utau |

The order is the order a person needs things in. You can play and quit before
anything else (1), then get about (2), then make something to hear (3, 4).
The grammar (5 to 8) comes as soon as there is something to edit, because
everything after it is easier with it: first on clips, where it is easiest to
see, then on notes, then selecting first, then where deleted and yanked
things go. The studio (9 to 13) follows in the order a song is made: sounds,
balance, loops to work on a part, recording, and a file at the end. The last
three are for going on alone: how to find any key, how to change paw, and
what the extensions add.

Every lesson teaches the idea behind a family of keys rather than a list (the
`?` page and the pickers are there for lists), and every lesson's opening page
says where the keys differ from Vim, so a Vim user can move fast and someone
who has never used Vim still has the whole explanation.

## Writing lessons

A lesson is a Lua table; `require("tutor").register(lesson)` adds it at the
end, `register(lesson, { after = "visual" })` after another. The built-in
ones are in `lua/tutor/lessons/`, listed in order in `lua/tutor/lessons/init.lua`.
An extension can add lessons about itself the same way.

```lua
require("tutor").register({
  id = "euclid",                          -- letters, digits, dashes: names the practice file
  title = "Euclidean rhythms",
  intro = [[What the lesson is about, shown when it starts.]],
  idea = [[The idea behind the keys.]],    -- optional
  vim = [[Where this differs from Vim.]],  -- optional
  setup = function(look)                   -- builds the practice project, with the public API
    local t = daw.add_track({ name = "Drums" })
    t:add_device("drums")
  end,
  at = function(look) daw.cursor.set_track(daw.track("Drums")) end,   -- optional: where to start
  steps = {
    {
      say = "Press `o` to add a track.",   -- one or two sentences, with every key in backticks
      keys = { "o" },                     -- exactly what the learner types, for the tests
      start = function(ctx, look) ctx.tracks = #daw.tracks() end,      -- optional
      check = function(ctx, look) return #daw.tracks() == ctx.tracks + 1 end,
      done = "A new track.",              -- said once it is done
      hint = "`o` is a small o.",         -- optional, for `,hh`
    },
  },
  outro = "What the learner did.",
})
```

**Checks.** `check(ctx, look)` is called after every event and a few times a
second; it returns true once the step is done. `ctx` is the step's own table:
`start` fills it, and the tutor records in it what happened since the step
began, which `look` reads:

| `look.` | |
| --- | --- |
| `ran(ctx, "undo")` | the command ran (aliases count as their command: `:w` is `write`) |
| `saw(ctx, "transport.play")` | the event happened |
| `said(ctx, "text")` | a message containing the text was shown |
| `played(ctx)` | the transport played and has stopped |
| `became(ctx, "name", condition)` | the condition, once it has been false: for an end state that may already hold |
| `names(track)`, `layout(track)`, `clips(track)`, `clip(track, name)`, `melody(clip)` | what a track or clip holds, as text |
| `cursor_track()`, `focused()`, `mode()`, `float()`, `visible(view)`, `roll()`, `device(track, kind)`, `param(device, key)`, `register(name)` | where the learner is |
| `notes("C4:0:1 E4:1:1")`, `drums(rows, bars)`, `beat`, `pulse(pitch, beats)`, `chord(pitches, beats)` | for `setup` |

A check must not be true before the step is done, also when the step before
was skipped: use `ran`, `became` or a value saved in `start` rather than an
end state the project may already be in.

**Keys.** `keys` lists what is typed, in Vim's notation; each string must also
appear in backticks in `say` (or `hint`), which the tests check, so the text
and the test cannot drift apart. Other items: `{ wait = 300 }` (milliseconds,
for listening), `{ sim = function(lesson) end, instead = { "keys" } }` for what
a person does away from the computer keyboard (a test tone on the input, MIDI
notes, quitting), and `{ sim = "quit", instead = { ":q", "<CR>" } }`.

**Steps the tutor cannot see** have `unchecked = "why"` in place of `check`;
the panel tells the learner to press `,hn` when done. `on_quit = true` makes a
step done by quitting paw. `test = { before = fn, after = fn }` on a lesson
prepares the test run (an audio engine with a test input) and tidies up after
it (files written beside the program).

**Tests.** `tests.lua` plays every registered lesson from start to finish by
typing each step's keys one at a time, as the kernel receives them, and checks
that the panel shows the step on screen, that the step is not noticed before
its keys are typed nor before the last of them, that it is noticed after, that
skipping any step does not pass the next one, and the hints, restarting,
leaving, coming back after a restart of the program, unsaved projects, and the
lesson list. A new lesson is tested by adding it; nothing else to write.

**The text.** After changing a lesson, run

```sh
daw --clean --no-plugins -l extensions/tutor/make-docs.lua
```

from the top of the repository to write `docs/course/`; the tests fail while
the files and the lessons disagree. `docs/course/keys.md` is written by hand,
and the tests check that every key in its first column is a key paw has.

## Steps the tests cannot perform

The tests type every step's keys. Where a person does something else, the
tests stand in for it, and two steps are not checked at all:

| Lesson, step | What the learner does | What the tests do |
| --- | --- | --- |
| 1, 8 | `:q` quits paw | announce `:q` (`command.pre`) without quitting; the tutor saves the place on that |
| 12, 1 to 3 | records from a microphone | the silent engine's test tone is the input |
| 12, 5 | plays a MIDI keyboard | `daw.midi.note_on` and `note_off`, as if from a port |
| 9, 9 | adds a plugin and opens its window | **unchecked**: which plugins exist differs between computers, and a window needs a desktop |
| 15, 4 | copies lines into `~/.config/daw/init.lua` and `:reload`s | **unchecked**: the tutor neither reads nor writes your configuration |

Listening steps are checked by the transport having played and stopped; what
was heard is not. Lesson 16's mixdiag step checks that measuring started, not
its result. Lesson 9 teaches plugin windows through what paw reports for a
built-in device (that it has no window).

## What the extension interface could not do

- **A key hook.** There is no event for "a key was handled", and closing a
  floating window (`daw.ui.close`) or the key hints appearing make no event, so
  the tutor also looks on a 200 ms timer. Timers do not run in `daw -l`
  scripts, so the tests call `tutor.poll()` after each key in the timer's
  place. Wanted: an event `key.done` emitted by `daw._kernel.key` after each
  key, with the key and the mode, and `ui.float_closed`.
- **A state directory.** `daw.api.env()` gives `config_dir` only; the tutor
  works out `$XDG_STATE_HOME/daw` itself. Wanted: `env().state_dir` (and
  `data_dir`, where recordings go), so that extensions and the runtime agree,
  and tests can move it with one variable.
- **Writing a copy of the project.** `daw.project.save(path)` makes `path` the
  project's file (Vim's `:saveas`). The tutor can only save the practice
  project in place, so a step's state is kept only when the practice project
  is saved (on leaving, quitting, or `:w`); after a crash the lesson resumes
  at the step the file was last saved at. Wanted: `daw.project.write_copy(path)`
  or `save(path, { copy = true })`.
- **Resetting a view's remembered state** has no call: the tutor sets
  `daw.ui.views.devices.row = 1` and `daw.ui.views.pianoroll:set_step(nil)`
  directly at the start of a lesson.

## What the course does not cover

The graphical frontend (`daw-gui`) and the mouse; the control socket
(`daw ctl`) and the MCP server; writing extensions beyond a mapping and a
command (operators, text objects and views of your own are in the main
README); the Lua API beyond `:lua` one-liners; plugin parameters through
automation (`:lane.add ... device=`) and pan automation; audio clip editing
(fades, crossfades, `:clip.import`); `:engine`, sample rates and latency;
`:midi.select`; `<C-v>` blocks in the piano roll, `o` in visual mode, `ac`
`it` `ie`, `=`, `S` `J` on clips, `<A-j>` `<A-k>`, zooming and scrolling (in
the lessons' text and keys.md, not practised); ripple editing; tempo and time
signature beyond `:tempo`. Features being changed elsewhere and not in this
tree (controller editing, autosave, stems and other export options, more
recording options) are not taught.

## Rough edges met while writing the lessons

Left as they are in paw and taught as they are; each with the lesson
where it came up and what would make it easier for a newcomer.

| Lesson | What happens | What would help |
| --- | --- | --- |
| 12 | After `<Space>` stops a take, record mode stays on (`rec` lit): the next `R` switches recording *off* instead of recording, and the next `<Space>` records again. The lesson has to teach `R` then `<Space>`. | Stopping the transport ends record mode, or `R` always starts a take when stopped. |
| 10 | Sends have no key and no command: the lesson types `:lua daw.track("Lead"):send(daw.track("Echo"), -6)`. | `:track.send Echo -6` and a key in the mixer. |
| 10 | The mixer shows no pan, and the arrange header neither: `>` in the mixer gives no feedback (only `K` shows it). | A pan readout on the strip. |
| 10 | `>` `<` pan in the mixer but move clips in the arrange view; pan there is `(` `)`. | The same key for pan in both, or say so in the mixer. |
| 9, 10 | `<Esc>` does nothing in the device panel and the mixer; in the piano roll it goes back to the arrange view. | `<Esc>` in any panel returns to the arrange view. |
| 9 | The device panel has no way to jump between devices: the lesson has to say `5j` to reach the second device's heading. | `w` `b` (or `]]` `[[`) between device headings, `gg` `G`. |
| 9 | The device panel keeps its row when the track changes, so `,d` can open on a row of another device's list. | Start at the top for a new track. |
| 3, 10 | Prompts come filled in (`grn` with the old name, `A` with the current value), and typing appends: the lesson must teach `<C-u>` first. | The first key typed replaces the filled-in text, as the vocal editor's lyric prompt does. |
| 4 | The note length set with a digit in insert mode lasts for the rest of the session, across clips, and is also the length `<CR>` gives a new note in normal mode; nothing shows it outside insert mode. | Reset it when insert mode ends, or show it in the piano roll's title row always. |
| 3 | A clip made with `i` is named `midi`. | No name, or the track's name. |
| 3, 4 | `a` adds a device in the arrange view but appends notes in the piano roll; a Vim user expects "append" in both. | Say so in `?`, or move "add device" to another key. |
| 5, 7 | Muting has four spellings with two meanings: `M` the track, `~` the clip, `gc` clips and `gcc` the track, and `~` on a `V` selection mutes the tracks but on a `v` selection the clips. | One rule: `gc` for clips, `M` for tracks, everywhere. |
| 6 | `dw` from inside a gap deletes nothing (a note belongs to where it starts), so `.` after moving into a gap silently does nothing. | A message when an operator's region holds nothing. |
| 2 | `<S-CR>` (play from the cursor) is indistinguishable from Enter in many terminals and in tmux. | A second key, such as `g<Space>`. |
| 13 | `:w name.json` is Vim's `:saveas` (the project moves to the new file); a Vim user expects a copy. There is no way to write a copy. | `:saveas` for moving, `:w name` for a copy, as in Vim. |
| 13 | `:render name.wav` writes relative to the folder paw was started from, `~` is not expanded, and the message gives only the name. | Expand `~`, and say the full path. |
| 14 | Key hints group `grn` and `grc` as `r +2 more` under `g`, hiding the rename keys. | List the group's keys when there are few. |
| — | `command.pre` and `command.post` carry the alias typed (`q`, `w`), not the command (`quit`, `write`); an extension listening for `quit` misses `:q`. | Add the command's own name to the event. |
| — | In a script, `daw.project.save` while an undo step is open counts edits made later in that step as saved (`modified` is false after adding a track). | Close the open step before saving. |
| — | `extensions/sections/tests.lua` sets `daw.pick = nil` and does not put it back, so every test after it runs without pickers. | Restore it, as the mixdiag and undotree tests do. |

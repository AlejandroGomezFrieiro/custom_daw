# Keys, by idea

One page to keep beside the keyboard. Keys are written as Vim writes them:
`<C-r>` is Ctrl and r, `<A-j>` Alt and j, `<CR>` Enter, `<Esc>` Escape, `,` is
the leader key. **A** is the arrange view, **R** the piano roll, **M** the mixer,
**D** the device panel. Every key here is checked against the DAW's mappings by
the tutor's tests; `?` in the DAW lists every key of the view you are in.

## The sentence

**count** · **operator** · **motion** or **text object** — `3>ic`, `d2W`, `yic`,
`gl4W`. An operator typed twice takes whole rows (tracks in A, pitches in R):
`dd`, `3yy`. `"a` before it names a register: `"ayic`. `.` repeats the last
change.

## Move (motions)

| Keys | A | R |
| --- | --- | --- |
| `h` `l` | a grid step | a step in time |
| `j` `k` | next, previous track | a semitone down, up |
| `J` `K` | | an octave down, up |
| `w` `b` `e` | next clip's start, this clip's start, this clip's end | the same for notes |
| `W` `B` | next, previous bar | next, previous bar |
| `0` `^` `$` | start of the project, first clip, end of the last clip | start of the clip, first note, end of the clip |
| `gg` `G` | first, last track (`5G` track 5) | highest, lowest note |
| `5\|` | bar 5 (also `:5`) | |
| `<C-d>` `<C-u>` | four tracks down, up | |
| `gP` | cursor to the playhead | |
| `]'` `['` | next marker or region, the one before | |
| `zz` `zh` `zl` | centre the cursor, scroll a bar | |

In **M**: `h` `l` are tracks. In **D**: `j` `k` are rows.

## Act (operators and single keys)

| Keys | A | R |
| --- | --- | --- |
| `d` | delete | delete notes |
| `y` | yank | yank notes |
| `c` | empty and enter notes in a new clip | delete and enter notes |
| `>` `<` | move clips later, earlier | move notes |
| `=` | snap clips and notes to the grid | snap notes |
| `gc` | mute or unmute clips (`gcc` the track) | |
| `gl` | loop it | loop it |
| `x` | delete the clip | delete the note |
| `D` `C` `Y` | delete, change, yank to the end of the track | to the end of the clip |
| `p` `P` | paste after the clip (tracks below), at the cursor (tracks above) | after the note, at the cursor |
| `&` `S` `J` `~` | repeat, split, join, mute the clip | |
| `H` `L` `<A-h>` `<A-l>` | move the clip, shorten and lengthen it | `H` `L` move the note |
| `<C-a>` `<C-x>` | transpose the clip | transpose the note |
| `+` `-` | track volume | note length |
| `(` `)` | pan | |
| `[` `]` | | velocity |
| `<CR>` | open the clip in R | add or remove a note |
| `gh` | | hear the pitch |
| `o` `O` | add a track below, above | |
| `grn` `grc` | rename the track, the clip | |
| `<A-j>` `<A-k>` | move the track down, up | |
| `M` `s` `r` | mute, solo, arm the track | |
| `I` `<A-i>` | choose the input (audio, MIDI port and channel), monitor it | |
| `a` | add a device | enter notes after the note |
| `A` | add a volume automation point | |
| `,at` `,ax` | automation off and on, clear it | |
| `,am` | the track's automation mode: read, touch, latch, write, off in turn | |
| `]t` `[t` | the clip's next take, the one before | |
| `zt` `zT` | show or hide the track's take lanes, the tempo lane under the ruler | |
| `g'` `g"` | put a marker at the cursor; go to one from a list | |
| `K` | describe what is under the cursor | |
| `u` `<C-r>` | undo, redo (`3u`) | the same |

In **M**: `k` `j` the fader, `>` `<` pan, `M` `s` `r` `I`, `dd` `yy` `p` tracks.
In **D**: `h` `l` (`H` `L` a lot) change the parameter, `a` add, `x` remove,
`b` bypass, `e` the plugin's window, `yy` `dd` `p` devices, `<A-j>` `<A-k>` reorder,
`K` the track the device listens to (side-chain), `O` where its further output pairs play.

## Name a region (text objects)

| Keys | A | R |
| --- | --- | --- |
| `ic` | the clip under the cursor | every note of the clip |
| `ac` | the clip and the gap after it | every note of the clip |
| `in` | | the note under the cursor |
| `ib` | this bar (`2ib` two) | this bar |
| `il` | the loop | |
| `it` | everything on the track | |
| `ie` | the entire project | every note of the clip |

## Select (visual mode)

| Keys | |
| --- | --- |
| `v` `V` `<C-v>` | select time, whole rows, a block (R) |
| `o` | go to the other end |
| `gv` | select the last selection again |
| `x` `p` | delete it, replace it with the register |
| `~` `J` | mute, join (A) |
| `<C-a>` `<C-x>` | transpose; a count first is how much: `12<C-a>` |
| `<Esc>` | back to normal mode |

## Enter notes (insert mode, R)

| Keys | |
| --- | --- |
| `i` | insert at the cursor (in A: in the clip under the cursor, or a new one) |
| `a w s e d f t g y h u j k` | C, C♯, D, … up to the next C; a capital stays, for chords |
| `1` … `9` | notes that many steps long |
| `<Space>` `<BS>` | a rest; step back and remove |
| `z` `x` | octave down, up |
| `[` `]` | softer, louder |
| `<Esc>` | back to normal mode |

## Repeat and remember

| Keys | |
| --- | --- |
| `.` | repeat the last change (`3.` with a new count) |
| `"a` | the register for the next command; `"0` last yank, `"_` nowhere |
| `qa` … `q` | record keys into register a |
| `@a` `@@` `@:` | play them, the last macro again, the last command line |
| `ma` `'a` `''` | set mark a, go to it, back to before the jump |
| `<C-o>` `<C-i>` | back, forward through jumps |

## Play

| Keys | |
| --- | --- |
| `<Space>` | play, stop |
| `<S-CR>` | play from the cursor |
| `gs` `gp` | playhead to the start, to the cursor |
| `gL` `gm` | loop on and off, metronome |
| `gC` | count a bar in before recording, or not |
| `gI` | punch recording on and off (over a selection: punch there); `:preroll 2` plays two bars before the punch in |
| `R` | record armed tracks, or stop recording; with the loop on, every time round is a take |

## Find

| Keys | |
| --- | --- |
| `?` | every key of this view |
| `:` | a command by name; `<Tab>` completes, `<Up>` for history |
| `/` `n` `N` `*` | find a clip or track by name (in R a pitch: `/c4`); next, previous; next with this name |
| `,,` | pick a command |
| `,fk` `,ft` `,fl` `,fa` `,fd` | pick a key, track, clip, device to add, device of the track |
| `,fm` `,fr` `,fn` `,ff` `,fo` `,fp` `,f.` | marks, registers, messages, files, options, every picker, the last picker |
| `,fR` | recent projects (`:recent 2` opens the second) |

Stop half way through a sequence and the keys that can follow are listed.

## Views and the program

| Keys | |
| --- | --- |
| `<Tab>` `gt` | next view |
| `,m` `,d` `,p` | mixer, device panel, piano roll |
| `<C-w>c` `<C-w>o` | close this panel, close every panel |
| `ge` | the track's plugin window |
| `zi` `zo` `[g` `]g` | zoom in, out; finer, coarser grid |
| `<C-s>` `:w` | save |
| `ZZ` `ZQ` `:q` | save and quit, quit, quit |

## The tutor

| Keys | |
| --- | --- |
| `:tutor` `:tutor 5` | the course where you left off, lesson 5 |
| `,hh` `,hn` `,hr` | a hint, skip the step, restart the lesson |
| `,hl` `,hq` | the lessons, leave the tutor |

## The doctor

| Keys | |
| --- | --- |
| `:doctor` `:doctor all` `:doctor input` | open the hardware check, run every check, run one |
| `j` `k` `<CR>` `A` `u` | on its page: choose a check, run it, run all, run those that need nobody |
| `y` `n` `s` ... | answer the question it asks (the keys are listed under it); `s` skips |
| `<Esc>` `q` | stop the run, close the page |

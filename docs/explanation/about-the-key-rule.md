# About the key rule

<!-- tags: one-grammar -->

In Vim, `j` moves a line down in every buffer. You learn a key one time,
and it works everywhere. paw has many views: the arrange view, the piano
roll, the mixer, the device panel, the curve editor, and the views of
extensions. Before the rule, each view chose its own keys, and the same key
had different meanings. The [key rule](../reference/key-rule.md) gives
each key one meaning in every view.

## Motions only move

The motion keys (`h` `j` `k` `l` `w` `b` `e` and the others) only move.
So they work after an operator and in visual mode in every view. A view
that used a motion key for a different action broke operators there.

For this reason, `b` is only a motion: the bypass in the device panel went to
`gc`, as `gc` comments a line out in Vim. The "back to the timeline" of the
session view went to `B` (`gB` for every track). `e` is only a motion too.
The window of a plugin is `ge` in every view. The session view opens the
notes of a slot with `i`, as `i` enters notes in a clip.

## One key for the main value

`+` `-` and `Ctrl-a` `Ctrl-x` change the main value of what is under the
cursor, and `]` `[` the second value. So you do not have to remember a
key for each control. The notes of the piano roll already used `+` `-` and
`Ctrl-a` `Ctrl-x` for the pitch. The length of a note went to `Alt-h`
`Alt-l`, which already shortened and lengthened a clip.

## Where the views did not agree

Where views used one key for different actions, the rule chose one
meaning:

- `K` is the key of Vim that finds help for the word under the cursor. The side-chain of a device went to `gS` in the panel, because `gK` already shows the diagnostics in every view.
- An octave is `Ctrl-d` `Ctrl-u` (half a page in Vim), because `J` `K` are not motions: `K` describes, and `J` joins clips. In insert mode, `J` `K` still move the note an octave.
- The count-in went from `gC` to `gM`, next to `gm` of the metronome. So `gC` opens curves everywhere. `gc` does not open a curve any more.
- `gn` stays the next edited clip of the piano roll, as `gn` of Vim goes to the next match. The wave of the curve editor is `g~` (an operator, and `~` looks like a wave), its shapes are `~`, and its own window is `Ctrl-w f`. `gw` is only the warp marker.
- `s` is solo wherever there is a track. The session view stops the clip of a track with `S` (`gS` every clip). The presets of the device panel are `c` on a device (choose), `]p` `[p` (step), `,w` (save, as `:w` writes) and `,W` (the default).
- The system breaks of the score are `zs` (a system starts here) and `zj` (join the bar to the system before), next to `zg` and `zp`, which also set the layout of the page. `gS` keeps its meaning of the session view and the panel.
- `a` appends. It already added a device on a track and notes after a note. It does the same in the mixer and the panel.
- `A` already added a point of automation at the cursor in every view that had it.

## Escape never leaves

`Esc` cancels and stays. So keys typed after it go where you expect. The
piano roll, the drum grid, the virtual inputs, the vocal editor and the
doctor left or closed on `Esc` before. The mix report, the undo tree and
the lists of sections did the same in a window of their own. Now `Ctrl-w p`
returns, and `q` closes a page.

## A time to change

The old keys are still there for a time, with `paw.opt.keys = "classic"`.
See [The classic keys](../reference/key-rule.md#the-classic-keys).

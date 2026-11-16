<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 11: Looping, marks and finding your way

*About ten minutes. In the DAW, with the tutor loaded: `:tutor 11`.*

Working on a part means hearing it over and over: the loop. It can be switched on and off, set to any stretch with the `gl` operator, and shown on the ruler. And in a long song you need to get about quickly: search clips and tracks by name with `/`, leave marks with `m` and come back to them with `'`, and go back to where you were before a jump.

This song has an intro, a verse and a chorus.

## The idea

`gL` loop on and off, `gl` + motion or object sets the loop (`glic`, `gl2W`), `il` is the loop as a text object (`yil`, `dil`). `gm` is the metronome, `gs` the playhead to the start and `gp` to the cursor. `ma` marks a place, `'a` goes back to it, `''` back to before the last jump, `<C-o>` `<C-i>` back and forward through jumps. `/name` finds a clip or track, `n` `N` the next and previous match, `*` the next clip with the same name.

## If you know Vim

Marks, `''`, `<C-o>` `<C-i>`, `/` `n` `N` and `*` are Vim's. Marks belong to a view (the arrange view and the piano roll have their own) and follow their track when tracks move. `:marks` lists them.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. `gL` switches looping on and off; the status line's `loop` lights up and the ruler shows the loop. Press `gL`.
   - ✓ Looping is on, over the first two bars.
2. `/` finds a clip or track by name. Type `/chorus` and press `<CR>`.
   - ✓ On the chorus. `n` would go on to the next match (the chorus of Bass).
3. `gl` is the loop operator. Press `glic` to loop the clip under the cursor.
   - ✓ The chorus is the loop.
4. `gm` switches the metronome (click) on. Press `gm`, then `gp` (the playhead to the cursor) and `<Space>`; `<Space>` stops.
   - ✓ The chorus with a click.
5. Press `gm` to switch the click off again.
   - ✓ No click.
6. `ma` sets mark a at the cursor. Press `ma`.
   - ✓ Mark a is on the chorus. `:marks` lists marks.
7. Go somewhere else with `G` (the last track) and `0` (the start), then press `'a` to jump back to the mark.
   - *Hint:* `'` is the apostrophe key.
   - ✓ Back on the chorus of Drums.
8. `''` goes back to where you jumped from. Press `''`.
   - ✓ On Lead at the start, where you were before `'a`. `''` again would go back to the chorus; `<C-o>` goes further back.
9. `gl` takes motions too: press `3|` to go to bar 3, then `gl2W` to loop two bars from there.
   - ✓ The first two bars of the verse are the loop.
10. Listen: `gp` and `<Space>`; `<Space>` stops.
   - ✓ Two bars of the verse, round and round.

## What you did

`gL`, `glic` and `gl2W` for the loop, `gm` for the click, `/` to find, `ma` `'a` `''` to come and go.

Previous: [Mixing: faders, pan, buses, sends, automation](10-mixing.md) · [All lessons](README.md) · Next: [Recording audio and MIDI](12-recording.md)

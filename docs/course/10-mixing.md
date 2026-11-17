<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 10: Mixing: faders, pan, buses, sends, automation

*About ten minutes. In paw, load the tutor with `:ext.load tutor`, then `:tutor 10`.*

Mixing is setting how loud each track is (its fader, in dB), where it sits from left to right (pan), which tracks to silence (mute) or hear alone (solo), and where its sound goes: to the master, into a bus that groups tracks under one fader, or partly to an effect track through a send. Automation changes a fader (or any parameter) over time.

The mixer shows a strip per track; the same changes can be made from the arrange view.

## The idea

In the mixer tracks run across, so `h` `l` choose a strip and `j` `k` a row of it (its devices, sends, fader, pan, mute, solo, arm). `+` `-` change the row under the cursor, by 1 dB on the fader, `]` `[` pan, `M` `s` `r` mute, solo, arm. In the arrange view the same are `+` `-`, `]` `[`, `M` `s` `r`. Routing is done by command: `:track.output Bus` sends the track into the track called Bus, `:track.output` alone back to the master. `A` adds a volume automation point at the cursor, `,at` switches the automation off and on, `,ax` clears it.

## If you know Vim

The mixer turns the grid sideways: `h` `l` move between tracks because tracks are its columns, and `j` `k` only ever move, as everywhere. `6<C-x>` lowers the row by six, as `<C-x>` lowers a number in Vim. `<C-w>c` closes it.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. Press `,m` to open the mixer along the bottom: a strip per track, with its fader and meter.
   - ✓ The mixer has the keyboard. The master is on the right.
2. Here `h` and `l` choose a strip and the cursor starts on its fader; `-` and `+` move the row under the cursor down and up by 1 dB. Press `l` to go to Bass, then `-` three times.
   - ✓ Bass is at -7 dB, three quieter than it was. `3-` or `3<C-x>` does it in one go.
3. `]` and `[` pan the strip right and left, wherever the cursor is on it. Press `]` three times.
   - ✓ Bass leans to the right.
4. `s` solos a track: only soloed tracks are heard. Press `<Space>` to play, `s` to hear Bass alone, `s` again to hear everything, and `<Space>` to stop.
   - ✓ Solo is for listening closely; it changes nothing in the mix.
5. `M` mutes. Press `l` to go to Keys and `M` to mute it.
   - ✓ Keys is muted: its `M` is lit.
6. Press `M` again to unmute Keys, and `<C-w>c` to close the mixer.
   - ✓ Back in the arrange view, still on Keys. Here too `+` `-` are the fader and `]` `[` the pan.
7. A bus is a track that others play into. Type `:track.add Bus` and `<CR>` to add one.
   - ✓ A track called Bus, below Keys. The cursor is on it.
8. Route Keys into it: `/Keys` and `<CR>` find the track, then type `:track.output Bus` and `<CR>`.
   - ✓ Keys now plays through Bus: Bus's fader turns the chords up and down, with anything else you route there.
9. A send copies some of a track to another, here to Echo, which has a delay. There is no key for it yet: type `:lua daw.track("Lead"):send(daw.track("Echo"), -6)` and `<CR>`.
   - *Hint:* `:lua` runs Lua; Tab does not complete inside it, so type it as it is.
   - ✓ Lead sends to Echo 6 dB down: the melody now has an echo, and Echo's fader sets how much.
10. Automation: `A` adds a volume point at the cursor and asks its value. On Keys, press `0`, `A`, `<C-u>` to clear the value, type `-30` and `<CR>`.
   - *Hint:* The cursor must be on Keys: `/Keys` and `<CR>`.
   - ✓ A point: -30 dB at the start. An `A` appears in the track header.
11. Press `2W` to go two bars on, then `A`, `<C-u>`, `-10` and `<CR>`: the chords fade in over two bars.
   - ✓ The line between the points is drawn in the track's lane.
12. Listen from the start: `gs`, `<Space>`, and `<Space>` to stop.
   - ✓ Chords fading in through a bus, a melody with an echo, the bass to the right.

## What you did

The mixer's faders, pan, solo and mute; a bus with `:track.output`; a send; volume automation with `A`.

Previous: [Devices, parameters and plugins](09-devices.md) · [All lessons](README.md) · Next: [Looping, marks and finding your way](11-loops.md)

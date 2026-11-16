<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->

# Lesson 12: Recording audio and MIDI

*About ten minutes. In paw, with the tutor loaded: `:tutor 12`.*

A track records what comes in: audio from an input of your sound card (a microphone, a guitar), or notes from a MIDI keyboard. Arm the tracks that should record, press record, play, stop: each armed track gets a new clip where recording began.

A track with an audio input records audio; an armed track with no input records MIDI. You need a microphone or other input for the first part and a MIDI keyboard for the second; without them, read along, and `,hn` skips a step. Recordings of this practice project go in the tutor's own folder.

## The idea

In the arrange view: `I` lists what the track can take in (no audio input, each channel of the input device and each pair such as `UR22mkII · 1/2`, MIDI from every port or one, one MIDI channel) to choose from, `<A-i>` or the `I` in the header monitors the input (hear it without recording), `r` arms the track, `R` starts recording from the playhead and `R` again stops recording while playback goes on; `<Space>` then stops playing. `:midi.inputs` lists MIDI ports and `:midi.select` chooses some. `:audio` chooses the input and output devices. Each take is one undo step.

## If you know Vim

`r` here arms a track; it does not replace anything. `R` is record, not replace mode.

## Steps

The tutor opens a practice project made for this lesson and checks each step as you do it.

1. The cursor is on Voice, a track with no device. `I` lists what it can take in: press `I`, type a few letters of the input your microphone is on (`1/2` for the first pair of channels, `· 1` for the first channel alone) and press `<CR>`. The header then shows it, with the level arriving there.
   - *Hint:* If the list has no channels, no input device is open: `:audio` lists the devices and chooses one.
   - ✓ Voice takes its sound from that input. (`<A-i>` would let you hear it without recording.)
2. `r` arms the track for recording: its `R` lights up red. Press `r`.
   - ✓ Armed. An armed track also lets you hear its input.
3. `R` starts recording from the playhead. Press `R`, sing or play for a few seconds, then `R` again to stop recording and `<Space>` to stop playing.
   - *Hint:* Stop recording with `R` before `<Space>`: after `<Space>` alone, record mode stays on (`rec` is lit in the status line) and the next `<Space>` records again.
   - ✓ A new audio clip with your take, where recording began; its waveform is drawn in it.
4. Now MIDI. Press `r` to disarm Voice, `j` to go to Keys, and `r` to arm it.
   - *Hint:* `:midi.inputs` lists the MIDI ports paw sees.
   - ✓ Keys is armed and has no audio input, so it records MIDI. Play your keyboard: you hear the synth.
5. Press `gs` to go back to the start, `R` to record, play a few notes on your MIDI keyboard, then `R` and `<Space>` to stop.
   - ✓ A MIDI clip with what you played: `<CR>` on it opens it in the piano roll.
6. Disarm Keys with `r`, then listen: `gs`, `<Space>`, and `<Space>` to stop.
   - ✓ Your recordings, with the drums.

## What you did

`I` for the input, `r` to arm, `R` to record, `<Space>` to stop: an audio take and a MIDI take.

Previous: [Looping, marks and finding your way](11-loops.md) · [All lessons](README.md) · Next: [Saving and rendering](13-saving.md)

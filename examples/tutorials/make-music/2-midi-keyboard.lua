-- The practice project of "Make music with paw", lesson 2: the song of
-- lesson 1, where we add a lead that we play on a MIDI keyboard.
--
--   paw -e 'dofile(os.getenv("PAW_HOME") .. "/examples/tutorials/make-music/2-midi-keyboard.lua")'
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
dofile(here .. "1-first-song.lua")

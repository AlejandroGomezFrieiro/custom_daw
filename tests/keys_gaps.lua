-- Keys that the user guide found missing or slow: fades on the clip's local
-- leader, counts before Alt-j, Alt-k and &, `[` and `]` that act at once,
-- tap tempo, and searches over the whole description of a key.
local T = ...
local test, eq, near, fresh, keys = T.test, T.eq, T.near, T.fresh, T.keys
local api = paw.api

local function start()
  fresh()
  paw.keymap.feed("<Esc><Esc>")
  while paw.ui.float do paw.ui.close() end
  paw.ui.focus("arrange")
end

local function message() return paw.ui.message and paw.ui.message.text or "" end

test("\\fi and \\fo fade the audio clip up to the cursor and from it; a count gives the beats", function()
  start()
  local s = {}
  for i = 1, 48000 * 4 do s[i] = 0.25 end
  local file = T.write_wav(T.scratch .. "/fade-keys.wav", s)
  local t = paw.add_track({ name = "Guitar" })
  local clip = t:add_clip({ file = file, start = 0, length = 8 })
  paw.cursor.set_track(t)
  paw.cursor.set_beat(2)
  keys("<localleader>fi")
  eq(clip.fade_in, 2, "\\fi fades in from the start of the clip to the cursor")
  paw.cursor.set_beat(5)
  keys("<localleader>fo")
  eq(clip.fade_out, 3, "\\fo fades out from the cursor to the end")
  keys("1<localleader>fo")
  eq(clip.fade_out, 1, "a count is the beats")
  eq(message():find("fades out over 1 beat", 1, true) ~= nil, true, "it says what it did: " .. message())
  paw.undo()
  eq(clip.fade_out, 3, "one undo step")
  keys("<localleader>ff1 2<CR>")
  eq(clip.fade_in .. " " .. clip.fade_out, "1 2", "\\ff types both lengths")
end)

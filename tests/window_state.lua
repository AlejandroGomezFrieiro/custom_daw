-- Tests of a view's state for each window: two piano rolls on two clips,
-- one score twice, the notation beside the piano roll of its clip, and the
-- locators of each window. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = paw.api
local L = paw.layout

local W, H = 160, 48

local initial = L.capture()

local function reset()
  paw.keymap.feed("<Esc><Esc>")
  while paw.ui.float do paw.ui.close() end
  paw.ui.start_layout = nil
  L.restore(initial)
  paw.ui.focus("arrange")
end

local function start()
  fresh()
  reset()
  T.after(reset)
end

local function screen() return table.concat(api.ui_snapshot(W, H), "\n") end

--- The names of the windows on screen, in order, bars left out.
local function windows()
  local out = {}
  for _, r in ipairs(paw.ui.arrange(W, H)) do
    if r.win then out[#out + 1] = r.name end
  end
  return table.concat(out, " ")
end

local function rects()
  local out = {}
  for _, r in ipairs(paw.ui.arrange(W, H)) do out[r.name] = r end
  return out
end

local function keys(text)
  paw.keymap.feed(text)
  api.undo_checkpoint()
end

--- Run `fn` with the screen of the size the tests draw.
local function sized(fn)
  local size = api.ui_size
  api.ui_size = function() return W, H end
  local ok, err = xpcall(fn, debug.traceback)
  api.ui_size = size
  if not ok then error(err, 0) end
end

local function notation()
  if not package.loaded["notation.keys"] then paw.ext.load("extensions/notation") end
end

local function riff()
  local t = paw.add_track({ name = "Keys" })
  local clip = t:add_clip({ start = 0, length = 8, name = "riff", notes = { { pitch = 60, start = 0, length = 1 }, { pitch = 64, start = 1, length = 1 } } })
  local other = t:add_clip({ start = 8, length = 8, name = "hook", notes = { { pitch = 72, start = 0, length = 2 } } })
  paw.cursor.set_track(t)
  return t, clip, other
end

--- What `fn(view)` gives in each window of `name` in the tab, in order.
local function each(name, fn)
  local out = {}
  for _, win in ipairs(L.windows(paw.ui.layout)) do
    if win.view == name then out[#out + 1] = L.within(win, fn, paw.ui.views[name]) end
  end
  return out
end

test("window state: two piano rolls on two clips, each with its own cursor", function()
  start()
  local _, clip, other = riff()
  sized(function()
    keys(":e roll://riff<CR>")
    keys(":vs roll://hook<CR>")
  end)
  eq(windows(), "pianoroll pianoroll", "two windows of the roll")
  local clips = each("pianoroll", function(v) return v.clip_id end)
  eq(clips[1] == clip.id and clips[2] == other.id, true, "on two clips")
  local text = screen()
  eq(text:find("riff", 1, true) ~= nil and text:find("hook", 1, true) ~= nil, true, "each drawn with its clip")
  eq(text:find("traceback", 1, true), nil, "neither failed")
  local roll = paw.ui.views.pianoroll
  eq(roll.clip_id, other.id, "the keys act in the new window")
  local left = each("pianoroll", function(v) return v.pitch end)[1]
  keys("kkk")
  local pitches = each("pianoroll", function(v) return v.pitch end)
  eq(pitches[1], left, "the left roll's cursor stays")
  eq(pitches[2], 72 + 3, "the right roll's moved")
  keys("<C-w>h")
  eq(roll.clip_id, clip.id, "Ctrl-w h: the keys act on the left roll's clip")
  eq(paw.ui.location("pianoroll").uri:find("/clip/" .. clip.id, 1, true) ~= nil, true, "its locator")
  local right = L.windows(paw.ui.layout)[2]
  eq(paw.ui.location("pianoroll", right).uri:find("/clip/" .. other.id, 1, true) ~= nil, true, "and the other window's its own")
  keys("<C-w>c")
  eq(windows(), "pianoroll", "closing one leaves the other")
  eq(roll.clip_id, other.id, "on its clip")
end)

test("window state: one score twice, and the notation beside the piano roll of the same clip", function()
  start()
  notation()
  local _, clip = riff()
  sized(function()
    keys(":e notation://riff<CR>")
    keys("<C-w>v")
  end)
  eq(windows(), "notation notation", "Ctrl-w v shows the notation again")
  eq(table.concat(each("notation", function(v) return tostring(v.clip_id) end), " "), clip.id .. " " .. clip.id, "the same clip in both")
  local before = paw.ui.views.notation.beat
  keys("l")
  local beats = each("notation", function(v) return v.beat end)
  eq(beats[1], before, "the cursor of the first stays")
  eq(beats[2] ~= before, true, "the cursor of the second moved")
  sized(function() keys(":e roll://riff<CR>") end)
  eq(windows(), "notation pianoroll", "the notation and the roll of the clip side by side")
  local text = screen()
  eq(text:find("traceback", 1, true), nil, "both drawn")
  keys("x")
  paw.flush()
  eq(#clip:notes(), 1, "an edit in the roll")
  eq(screen():find("traceback", 1, true), nil, "and both drawn again")
end)

test("window state: :sp in the roll shows the roll again, on the clip of this window", function()
  start()
  local _, clip = riff()
  sized(function()
    keys(":e roll://riff<CR>")
    keys(":sp<CR>")
  end)
  eq(windows(), "pianoroll pianoroll", "two rolls")
  eq(table.concat(each("pianoroll", function(v) return tostring(v.clip_id) end), " "), clip.id .. " " .. clip.id, "on the same clip")
  sized(function() keys(":e arrange<CR>") keys(":vs<CR>") end)
  eq(windows():find("arrange arrange", 1, true) ~= nil, true, ":vs in the arrange view shows it twice")
end)

-- Taking marks and markers away: `:delmarks`, and removing the marker at the
-- cursor by key or by the pointer. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local daw = require("daw")

local function start()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
  daw.add_track({ name = "Bass" })
  daw.keymap.delmarks("a-zA-Z")
end

local function set(names)
  for name in names:gmatch(".") do daw.keymap.feed("m" .. name) end
end

local function held()
  local out = {}
  for name in pairs(daw.keymap.marks("arrange")) do out[#out + 1] = name end
  table.sort(out)
  return table.concat(out)
end

test("marks: :delmarks takes away letters, ranges and all lowercase ones", function()
  start()
  set("abcdeX")
  daw.keymap.feed(":delmarks b<CR>")
  eq(held(), "Xacde", "one letter")
  daw.keymap.feed(":delm c-d<CR>")
  eq(held(), "Xae", "a range, by the short name")
  daw.keymap.feed(":delmarks a e<CR>")
  eq(held(), "X", "several letters")
  set("pq")
  daw.keymap.feed(":delmarks!<CR>")
  eq(held(), "X", "the bang removes every lowercase mark and keeps the capital")
  daw.keymap.feed(":delmarks X<CR>")
  eq(held(), "", "a capital by name")
end)

test("marks: :delmarks says what is wrong and completes the marks that exist", function()
  start()
  set("mk")
  eq(daw.keymap.delmarks("9"), nil, "a digit is not a mark")
  eq(select(2, daw.keymap.delmarks("d-a")) ~= nil, true, "a backwards range is refused")
  eq(daw.keymap.delmarks("z"), 0, "an unset mark is nothing to remove")
  eq(held(), "km", "nothing was removed by those")
  local names = {}
  for _, c in ipairs(daw.commands.complete("delmarks ")) do names[#names + 1] = c.label end
  eq(table.concat(names, ","), "k,m", "completion lists the marks that are set")
end)

test("marks: gx removes the marker at the cursor", function()
  start()
  daw.markers.add(8, "Verse")
  daw.markers.add(24, "Chorus")
  daw.cursor.set_beat(8)
  daw.keymap.feed("gx")
  eq(#daw.markers.list() .. daw.markers.list()[1].name, "1Chorus", "gx took the marker under the cursor")
  daw.cursor.set_beat(0)
  daw.keymap.feed("gx")
  eq(#daw.markers.list(), 1, "and does nothing where there is none")
end)

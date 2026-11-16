-- Finding your way with the keys: named groups in the hints, a sequence that
-- matches nothing, the focused view in the status line, the changelist, and
-- the order of the `?` list.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local pick = daw.pick

local function start()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

local function hint_of(key)
  for _, hint in ipairs(daw.keymap.hints() or {}) do
    if hint.key == key then return hint.desc end
  end
end

test("a named group shows its name in the hints, and an unnamed one how many keys it holds", function()
  start()
  daw.opt.hint_delay = 0
  daw.keymap.set("<leader>yq1", "noop", { desc = "one" })
  daw.keymap.set("<leader>yq2", "noop", { desc = "two" })
  daw.keymap.feed("<leader>")
  eq(hint_of("y"), "+2 more", "counted until it has a name")
  daw.keymap.feed("<Esc>")
  daw.keymap.group("<leader>y", "test group")
  daw.keymap.feed("<leader>")
  eq(hint_of("y"), "+test group", "named")
  daw.keymap.feed("<Esc>")
  daw.keymap.feed("<leader>a")
  eq(hint_of("l"), "Choose what to automate, and show its lane", "the keys inside still say what they do")
  daw.keymap.feed("<Esc><leader>")
  eq(hint_of("a"), "+automation", "the built-in groups have names")
  daw.keymap.feed("<Esc>")
  daw.keymap.del("<leader>yq1")
  daw.keymap.del("<leader>yq2")
  daw.opt.hint_delay = 500
end)

test("a sequence that matches nothing says so and drops what follows it", function()
  start()
  local ran = {}
  daw.keymap.set("<leader>yz", function() ran.mapped = true end, { desc = "test" })
  daw.keymap.set("Q", function() ran.last = (ran.last or 0) + 1 end, { desc = "test" })
  daw.keymap.feed("<leader>yQ")
  eq(ran.last, nil, "the last key did not run alone")
  eq(ran.mapped, nil, "nor the mapping it was heading for")
  eq(daw.keymap.pending(), "", "nothing is left half typed")
  eq(daw.ui.message and daw.ui.message.text, ",yQ is not mapped", "the message says what was typed")
  -- A key that is a mapping by itself still runs, then the next key starts afresh.
  daw.keymap.set("wm", function() ran.wm = (ran.wm or 0) + 1 end, { desc = "test" })
  daw.keymap.set("wmm", function() ran.wmm = true end, { desc = "test" })
  daw.keymap.feed("wmQ")
  eq(ran.wm, 1, "a complete mapping that is also a prefix runs")
  eq(ran.last, 1, "and the key after it is a new command")
  eq(ran.wmm, nil, "not the longer one")
  daw.keymap.del("<leader>yz")
  daw.keymap.del("Q")
  daw.keymap.del("wm")
  daw.keymap.del("wmm")
end)

test("the status line names the focused view and shows its grid", function()
  start()
  local function segments()
    local out = {}
    for _, list in pairs(daw.ui.views.status.segments(140)) do
      for _, seg in ipairs(list) do
        for _, piece in ipairs(seg) do out[#out + 1] = piece[1] end
      end
    end
    return table.concat(out, "|")
  end
  local grid, note_grid = daw.opt.grid, daw.opt.note_grid
  daw.opt.grid, daw.opt.note_grid = 1, 0.5
  local text = segments()
  eq(text:find(" NORMAL·arrange ", 1, true) ~= nil, true, "the pill: " .. text)
  eq(text:find("grid 1/4", 1, true) ~= nil, true, "the arrange grid")
  daw.ui.focus("pianoroll")
  text = segments()
  eq(text:find(" NORMAL·pianoroll ", 1, true) ~= nil, true, "the pill follows focus: " .. text)
  eq(text:find("grid 1/8", 1, true) ~= nil, true, "the roll's own grid")
  daw.ui.focus("arrange")
  daw.opt.grid, daw.opt.note_grid = grid, note_grid
end)

test("g; and g, walk the places the project was edited, and `. goes to the last", function()
  start()
  daw.keymap.feed("ooo")
  daw.cursor.set_track(daw.tracks()[1])
  daw.cursor.set_beat(8)
  daw.keymap.feed("M")
  daw.cursor.set_track(daw.tracks()[3])
  daw.cursor.set_beat(16)
  daw.keymap.feed("M")
  daw.cursor.set_beat(0)
  daw.cursor.set_track(daw.tracks()[2])
  local function where() return daw.cursor.index() .. "@" .. daw.cursor.beat end
  daw.keymap.feed("g;")
  eq(where(), "3@16", "g; goes to the last edit")
  daw.keymap.feed("g;")
  eq(where(), "1@8", "and again to the one before")
  daw.keymap.feed("g,")
  eq(where(), "3@16", "g, goes forward")
  daw.cursor.set_beat(0)
  daw.keymap.feed("`.")
  eq(where(), "3@16", "`. goes to the last edit's track and beat")
  eq(#daw.keymap.changes("arrange") >= 3, true, "the list holds them")
  daw.cmd("changes")
  eq(daw.ui.float and daw.ui.float.name, "pager", ":changes lists them")
  daw.ui.close()
end)

test("the ? list puts the view's own keys first, folds aliases and has no repeats", function()
  start()
  daw.keymap.feed("?")
  local lines = pick.state().matches
  eq(lines[1]:find("arrange", 1, true) ~= nil, true, "the view's own keys come first: " .. lines[1])
  local seen, first_global = {}, nil
  for i, line in ipairs(lines) do
    eq(seen[line], nil, "repeated: " .. line)
    seen[line] = true
    if not first_global and line:find("global%s*$") then first_global = i end
  end
  for i = first_global, #lines do
    eq(lines[i]:find("arrange%s*%a*%s*$"), nil, "a view key after global ones: " .. lines[i])
  end
  local text = table.concat(lines, "\n")
  eq(text:find("Ctrl-z, u", 1, true) ~= nil, true, "aliases are on one line")
  daw.keymap.feed("<Esc>")
end)

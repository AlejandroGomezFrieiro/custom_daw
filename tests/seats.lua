-- Tests of seats: every terminal and window attached to an instance has a
-- cursor, mode, selection and keys of its own, while the project is one.
-- The kernel's part (whose turn it is) is played here by calling its entry
-- points the way it does. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local K = daw._kernel

local function start()
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

--- Do `fn` as the kernel does a turn for `seat`, and come back to the
--- instance's seat after, as it does.
local function as(seat, fn)
  K.seat(seat)
  local ok, err = xpcall(fn, debug.traceback)
  K.seat(0)
  if not ok then error(err, 0) end
end

--- Type keys in a seat, one turn each.
local function keys(seat, typed)
  for _, key in ipairs(daw.keymap.parse(typed)) do
    as(seat, function() K.key(key) end)
    daw.flush()
    api.undo_checkpoint()
  end
end

local function name_at_cursor(seat)
  local name
  as(seat, function() name = daw.cursor.track().name end)
  return name
end

test("two terminals each have a cursor, a mode and keys of their own, and edit one project", function()
  start()
  for _, name in ipairs({ "Drums", "Bass", "Keys" }) do daw.add_track({ name = name }) end
  daw.cursor.set_track(daw.tracks()[1])
  daw.cursor.set_beat(4)
  K.seat_open(7, "terminal")
  local ok, err = pcall(function()
    eq(daw.seats.has(7), true, "the terminal has a seat")
    eq(name_at_cursor(7), "Drums", "a new seat starts where the instance's cursor is")
    keys(7, "jj")
    eq(name_at_cursor(7), "Keys", "it moves its own cursor")
    eq(name_at_cursor(0), "Drums", "and not the instance's")
    eq(daw.cursor.beat, 4, "nor its beat")
    keys(7, "V")
    as(7, function() eq(daw.keymap.mode, "x", "a selection is open in the terminal") end)
    eq(daw.keymap.mode, "n", "and not in the instance's seat")
    keys(0, "g")
    eq(daw.keymap.pending(), "g", "keys half typed in one seat")
    as(7, function() eq(daw.keymap.pending(), "", "are not in another") end)
    keys(7, "<Esc>")
    keys(0, "<Esc>")
    -- One project: what one seat does, the other sees, and undoes.
    keys(7, ":track.add<CR>")
    eq(#daw.tracks(), 4, "a track added from the terminal")
    as(7, function() eq(daw.keymap.mode, "n", "its command line closed") end)
    keys(0, "u")
    eq(#daw.tracks(), 3, "undone from the instance's seat: one history")
    -- A prompt open in one seat takes that seat's keys only.
    keys(7, ":")
    as(7, function() eq(daw.ui.grabber ~= nil, true, "the terminal has a prompt open") end)
    eq(daw.ui.grabber, nil, "the instance's seat does not")
    keys(0, "j")
    eq(name_at_cursor(0), "Bass", "keys go on working there")
    keys(7, "<Esc>")
    -- Panels and focus are each seat's own.
    keys(7, ":view.toggle mixer<CR>")
    as(7, function()
      eq(daw.ui.visible("mixer"), true, "the mixer opened in the terminal")
      eq(daw.ui.focused, "mixer", "with the keyboard")
    end)
    eq(daw.ui.visible("mixer"), false, "not in the instance's seat")
    eq(daw.ui.focused, "arrange", "which keeps its focus")
  end)
  K.seat_close(7, "terminal")
  if not ok then error(err, 0) end
  eq(daw.seats.has(7), false, "the seat closed with its terminal")
  eq(daw.seats.current, 0, "the instance's seat is the current one")
end)

test("a seat that closes leaves nothing behind, and an unknown one is the instance's", function()
  start()
  daw.add_track({ name = "One" })
  daw.add_track({ name = "Two" })
  daw.cursor.set_track(daw.tracks()[1])
  K.seat_open(8, "terminal")
  keys(8, "j")
  keys(8, "g")
  as(8, function() eq(daw.keymap.pending(), "g", "a key waits in the terminal") end)
  K.seat_close(8, "terminal")
  eq(name_at_cursor(8), "One", "a closed seat's turn is the instance's")
  eq(daw.keymap.pending(), "", "and what waited there is gone")
  -- Opened again, it starts afresh.
  K.seat_open(8, "terminal")
  eq(name_at_cursor(8), "One", "from the instance's cursor")
  as(8, function() eq(daw.keymap.pending(), "", "with nothing half typed") end)
  K.seat_close(8, "terminal")
end)

test("a timer started in a seat runs in that seat", function()
  start()
  K.seat_open(9, "terminal")
  local seen
  as(9, function() daw.defer(function() seen = daw.seats.current end, 1) end)
  daw.wait(30)
  K.seat_close(9, "terminal")
  eq(seen, 9, "the deferred function ran in the terminal's seat")
end)

test("a window watching has a seat of its own unless it shares the instance's", function()
  start()
  daw.add_track({ name = "First" })
  daw.add_track({ name = "Second" })
  daw.cursor.set_track(daw.tracks()[1])
  daw.seats.open(11, "window")
  as(11, function() daw.cursor.set_track(daw.tracks()[2]) end)
  local state = daw.seats.within(11, daw.frontend.state, -1)
  eq(state.selected, daw.tracks()[2].id, "the window's state shows its own cursor")
  eq(daw.frontend.state(-1).selected, daw.tracks()[1].id, "the instance's shows its own")
  daw.seats.open(11, "terminal")
  daw.seats.close(11, "window")
  eq(daw.seats.has(11), true, "a seat stays while the connection still has a terminal")
  K.rpc_closed(11)
  eq(daw.seats.has(11), false, "and goes with the connection")
end)

test("with one seat, nothing is put away or brought back", function()
  start()
  local stowed = 0
  daw.seats.keep("test.counting", function() stowed = stowed + 1 end, function() end, function() end)
  for _ = 1, 5 do keys(0, "j") end
  eq(stowed, 0, "turns in the instance's seat move no state")
end)

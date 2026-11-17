-- One key rule in every view (docs/terminal.md, "Keys: one grammar"): the
-- motion keys only move, `<` `>` are the time operators, `+` `-` `Ctrl-a`
-- `Ctrl-x` change the main value and `[` `]` the second, `K` describes,
-- `ge` is the plugin window, `gc` mutes and `gC` opens a curve, and Escape
-- cancels and stays. The first tests walk every view's mappings; the others
-- drive the mixer, the device panel and the piano roll as grids. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local test, eq, near, fresh = T.test, T.eq, T.near, T.fresh
local api = daw.api
local keymap = daw.keymap

local function start()
  fresh()
  api.engine_restart({ backend = "null" })
  keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  for _, name in ipairs({ "pianoroll", "mixer", "devices", "session" }) do daw.ui.hide(name) end
  daw.ui.focus("arrange")
end

local function keys(text)
  keymap.feed(text)
  api.undo_checkpoint()
end

--- A key that also starts longer mappings (`]` and `]d`): it runs when the
--- wait for the rest is over, as it does at the keyboard.
local function waited(text)
  local before = daw.opt.timeoutlen
  daw.opt.timeoutlen = 20
  keymap.feed(text)
  daw.wait(150)
  daw.opt.timeoutlen = before
  api.undo_checkpoint()
end

local broken = daw.keyrule.broken

test("every view's keys keep to the one rule, the bundled extensions' too", function()
  start()
  eq(table.concat(broken(), "\n"), "", "the core's mappings that break the rule")
  -- Loading every extension here would change the suite's kernel for the
  -- tests after this one: a kernel of its own walks them.
  -- The shell's parent is this kernel: the same program runs the walk.
  local cmd = 'exec "$(readlink /proc/$PPID/exe)" --clean --no-plugins --no-listen --audio null -l tests/fixtures/keys_walk.lua 2>&1'
  local out = io.popen(cmd):read("*a")
  eq(out:match("done%s*$") ~= nil, true, "the walk ran to its end:\n" .. out)
  local wrong = {}
  for line in out:gmatch("[^\n]+") do
    if line:match("^wrong: ") then wrong[#wrong + 1] = line:sub(8) end
  end
  eq(table.concat(wrong, "\n"), "", "with every extension loaded")
end)

test("the rule holds for a mapping made later, and says what it broke", function()
  start()
  keymap.set("j", function() end, { view = "keyrule.test", desc = "test: a fader on j" })
  local found = table.concat(broken(), "\n")
  keymap.del("j", { view = "keyrule.test" })
  eq(found:find("keyrule.test n j: a motion key that does not move", 1, true) ~= nil, true, found)
  eq(table.concat(daw.keyrule.lost_groups(), ", "), "", "and every named group of keys leads to keys")
end)

test("Escape cancels and stays in every view", function()
  start()
  local t = daw.add_track({ name = "Keys" })
  t:add_device("synth")
  local clip = t:add_clip({ name = "c", start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  api.undo_checkpoint()
  local moved = {}
  local function stays(name, open)
    open()
    if daw.ui.focused ~= name then moved[#moved + 1] = name .. " did not open" return end
    keymap.feed("3d<Esc>")
    keymap.feed("<Esc><Esc>")
    if daw.ui.focused ~= name then moved[#moved + 1] = name .. " -> " .. tostring(daw.ui.focused) end
    eq(keymap.pending(), "", name .. ": the count and operator are cancelled")
    eq(keymap.mode, "n", name .. ": normal mode")
    daw.ui.focus("arrange")
  end
  stays("pianoroll", function() daw.ui.views.pianoroll:edit(clip) daw.ui.focus("pianoroll") end)
  stays("mixer", function() daw.ui.show("mixer") daw.ui.focus("mixer") end)
  stays("devices", function() daw.ui.show("devices") daw.ui.focus("devices") end)
  stays("session", function() daw.ui.show("session") daw.ui.focus("session") end)
  eq(table.concat(moved, ", "), "", "views Escape left")
  -- A second Escape soon after says how to leave.
  daw.ui.show("mixer")
  daw.ui.focus("mixer")
  keymap.feed("<Esc><Esc>")
  eq((daw.ui.message and daw.ui.message.text or ""):find("<C-w>p goes back", 1, true) ~= nil, true, "the hint")
  for _, name in ipairs({ "pianoroll", "mixer", "devices", "session" }) do daw.ui.hide(name) end
end)


-- The mixer as a grid -----------------------------------------------------------------------

local function mixer(tracks)
  start()
  local out = {}
  for i, name in ipairs(tracks) do out[i] = daw.add_track({ name = name }) end
  api.undo_checkpoint()
  daw.cursor.set_track(out[1])
  daw.ui.show("mixer")
  daw.ui.focus("mixer")
  daw.ui.views.mixer.row = "volume"
  return unpack(out)
end

test("in the mixer h l go between strips and j k along a strip's rows, which + - change", function()
  local a, b = mixer({ "A", "B" })
  b:add_device("gain")
  a:send(b, -12)
  api.undo_checkpoint()
  keys("6<C-x>")
  near(a.volume, -6, 1e-6, "6 Ctrl-x is -6 dB on the fader")
  keys("j3+")
  near(a.pan, 0.3, 1e-6, "j is the pan, 3+ three tenths right")
  waited("]")
  near(a.pan, 0.4, 1e-6, "] pans wherever the cursor is")
  keys("gg")
  eq(daw.mixer_rows.current().kind, "send", "gg is the strip's top row: its send")
  keys("2-")
  near(api.track_get(a.id).sends[1].level, -14, 1e-6, "- lowers the send")
  keys("x")
  eq(#api.track_get(a.id).sends, 0, "x clears the row: the send goes")
  keys("l")
  eq(daw.cursor.track_id(), b.id, "l is the next strip")
  eq(daw.mixer_rows.current().kind, "volume", "on the row of the same kind, else the fader: B has no send")
  keys("gg")
  eq(daw.mixer_rows.current().kind, "insert", "gg: the strip's top row, its first device")
  keys("-")
  eq(b:devices()[1].bypass, true, "- on an insert switches it off")
  keys("G")
  eq(daw.mixer_rows.current().field, "monitor", "G is the bottom row")
  keys("K")
  eq(daw.ui.float ~= nil, true, "K describes")
  while daw.ui.float do daw.ui.close() end
  daw.ui.hide("mixer")
end)

test("in the mixer operators and a selection work over strips and rows, and . repeats", function()
  local a, b, c = mixer({ "A", "B", "C" })
  keys("Vl-")
  near(a.volume, -1, 1e-6, "V over two strips: - lowers both faders")
  near(b.volume, -1, 1e-6, "the second too")
  near(c.volume, 0, 1e-6, "not the third")
  keys("2l.")
  near(c.volume, -1, 1e-6, ". does it again from the strip the cursor is on (the last: there is none after it)")
  near(b.volume, -1, 1e-6, "and not to the strips before")
  daw.cursor.set_track(a)
  keys("j5+")
  keys("kyj")
  eq(keymap.getreg().kind, "mixrows", "y over two rows yanks their settings")
  keys("lp")
  near(b.volume, a.volume, 1e-6, "p puts the fader")
  near(b.pan, 0.5, 1e-6, "and the pan on the next strip")
  keys("gcc")
  eq(api.track_get(b.id).mute, true, "gcc mutes the strip")
  keys("dj")
  near(b.volume, 0, 1e-6, "dj clears the fader")
  near(b.pan, 0, 1e-6, "and the pan")
  eq(#api.track_list(), 3, "rows are cleared, not tracks")
  keys("dd")
  eq(#api.track_list(), 2, "dd cuts the strip's track, as it cuts a line")
  daw.ui.hide("mixer")
end)

-- The device panel as a grid -------------------------------------------------------------------

local function panel()
  start()
  local t = daw.add_track({ name = "Lead" })
  local synth = t:add_device("synth")
  local delay = t:add_device("delay")
  api.undo_checkpoint()
  daw.cursor.set_track(t)
  daw.ui.show("devices")
  daw.ui.focus("devices")
  daw.ui.views.devices.row = 1
  return t, synth, delay
end

local function param_row(device, key)
  for i, row in ipairs(daw.ui.views.devices:rows()) do
    if row.param and row.device.id == device.id and row.param.key == key then return i end
  end
end

test("in the device panel w b go from device to device, + - change a parameter, gc bypasses", function()
  local _, synth, delay = panel()
  keys("w")
  local device, row = daw.ui.views.devices:selected()
  eq(device.id == delay.id and not row.param, true, "w is the next device's heading")
  keys("gcc")
  eq(api.device_get(delay.id).bypass, true, "gcc bypasses it")
  keys("b")
  eq(daw.ui.views.devices.row, 1, "b is the device before")
  daw.ui.views.devices.row = param_row(synth, "cutoff")
  local before = api.device_get(synth.id).params.cutoff
  keys("5<C-a>")
  local after = api.device_get(synth.id).params.cutoff
  eq(after > before, true, "5 Ctrl-a raises the parameter")
  keys(".")
  eq(api.device_get(synth.id).params.cutoff > after, true, ". does it again")
  keys("dd")
  near(api.device_get(synth.id).params.cutoff, synth:get().param_info[param_row(synth, "cutoff") - 1].default, 1e-3,
    "dd on a parameter puts it back at its default")
  daw.ui.views.devices.row = 1
  daw.ui.hide("devices")
end)

test("in the device panel y p copy a device's settings onto another", function()
  local t, synth = panel()
  local other = t:add_device("synth")
  api.undo_checkpoint()
  daw.ui.views.devices.row = param_row(synth, "cutoff")
  keys("10+")
  keys("yy")
  eq(keymap.getreg().kind, "params", "yy on a parameter yanks its setting")
  daw.ui.views.devices.row = param_row(other, "cutoff")
  keys("p")
  near(api.device_get(other.id).params.cutoff, api.device_get(synth.id).params.cutoff, 1e-6, "p puts it on the device under the cursor")
  eq(#t:devices(), 3, "no device was added")
  daw.ui.views.devices.row = 1
  daw.ui.hide("devices")
end)

-- The piano roll ---------------------------------------------------------------------------

test("in the piano roll + - are the pitch, Alt-l Alt-h the length, and a selection takes in the note under its end", function()
  start()
  local t = daw.add_track({ name = "Keys" })
  local clip = t:add_clip({ name = "c", start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 }, { pitch = 60, start = 2, length = 1 } } })
  api.undo_checkpoint()
  local roll = daw.ui.views.pianoroll
  roll:edit(clip)
  daw.ui.focus("pianoroll")
  roll:set(60, 0)
  keys("2+")
  eq(T.melody(clip), "62@0+1 60@2+1", "2+ raises the note two semitones")
  keys("<A-l>")
  eq(T.melody(clip), "62@0+1.25 60@2+1", "Alt-l lengthens it")
  keys("<C-d>")
  eq(roll.pitch, 50, "Ctrl-d is an octave down")
  roll:set(60, 2)
  keys("vd")
  eq(T.melody(clip), "62@0+1.25", "v d on a note takes the whole note")
  keymap.feed("<Esc>")
  eq(daw.ui.focused, "pianoroll", "Escape stays")
  daw.ui.hide("pianoroll")
end)

-- The old keys ---------------------------------------------------------------------------------

test("daw.opt.keys = classic puts the old keys back, and the default takes them away again", function()
  local a = mixer({ "A" })
  T.after(function() daw.opt.keys = "default" end)
  daw.opt.keys = "classic"
  keys("j")
  near(a.volume, -1, 1e-6, "classic: j is the fader")
  keys("<lt>")
  near(a.pan, -0.1, 1e-6, "classic: < pans")
  daw.opt.keys = "default"
  keys("j")
  near(a.volume, -1, 1e-6, "default: j moves")
  eq(daw.mixer_rows.current().kind, "pan", "to the pan row")
  eq(table.concat(broken(), "\n"), "", "and the rule holds again")
  daw.ui.hide("mixer")
end)

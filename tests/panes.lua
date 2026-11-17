-- Tests of the tabs and windows as a graphical frontend shows them: panes
-- docked in its main area (daw/panes.lua), laid out in pixels, painted, and
-- given the keyboard; and of views that pop out into windows of their own
-- and give the keyboard back. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local L = daw.layout
local P = daw.panes
local function ex(line) return daw.commands.exec(line) end

local W, H = 1200, 700
local initial = L.capture()

local function tidy()
  -- Arranged on the terminal's screen again, as the other tests expect.
  P.area(0, 0)
  L.restore(initial)
  for name in pairs(daw.canvas.open_views) do daw.canvas.close(name) end
  daw.ui.focus("arrange")
end

local function start()
  T.after(tidy)
  fresh()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  tidy()
  P.area(W, H)
end

--- The panes of the state by view, and the pane with the keyboard.
local function panes()
  local by, focused = {}, nil
  for _, p in ipairs(P.state().panes) do
    by[p.view] = p
    if p.focused then focused = p end
  end
  return by, focused
end

--- The text a pane drawn in cells shows, run after run.
local function painted(pane)
  local drawing = P.paint(pane.win, pane.w, pane.h, { fresh = true })
  local out = {}
  for _, op in ipairs(drawing and drawing.ops or {}) do
    if op[1] == "m" or op[1] == "t" then out[#out + 1] = op[1] == "m" and op[6] or op[4] end
  end
  return table.concat(out, " ")
end

test("panes: the window's area is laid out as the terminal lays out the tab, the device panel beside the arrange view", function()
  start()
  daw.ui.show("devices")
  local by, focused = panes()
  eq(by.arrange ~= nil and by.devices ~= nil, true, "the arrange view and the device panel")
  eq(by.arrange.kind .. " " .. by.devices.kind, "native native", "both drawn by the window itself")
  eq(by.devices.x + by.devices.w, W, "the panel along the right edge")
  eq(by.arrange.x + by.arrange.w, by.devices.x, "the arrange view beside it")
  eq(by.arrange.h, H, "the whole height")
  eq(focused and focused.view, "arrange", "the arrange view has the keyboard")
  eq(#P.state().borders, 1, "one border between them")
  eq(P.state().tabs[2], nil, "one tab")
end)

test("panes: :vs daw://lane/N is a pane drawn in cells beside the arrange view, and has the keyboard", function()
  start()
  local t = daw.add_track({ name = "Pad" })
  local lane = t:automate("volume")
  lane:set_points({ { 0, -12 }, { 4, 0 } })
  ex("vs " .. daw.address.lane(lane.id))
  local by, focused = panes()
  eq(by.curve and by.curve.kind, "cells", "the curve is drawn in cells")
  eq(focused and focused.view, "curve", "and has the keyboard")
  eq(by.curve.x, by.arrange.x + by.arrange.w, "beside the arrange view")
  eq(painted(by.curve):find("Volume", 1, true) ~= nil, true, "it shows the lane: " .. painted(by.curve))
  daw.keymap.feed("<C-w>h")
  local _, now = panes()
  eq(now.view, "arrange", "Ctrl-w h goes to the arrange view")
  ex("wincmd l")
  ex("q")
  by = panes()
  eq(by.curve, nil, ":q closes it")
end)

test("panes: Enter on a lane row opens its curve in a pane", function()
  start()
  local t = daw.add_track({ name = "Pad" })
  local lane = t:automate("volume")
  daw.lanes.open(t)
  daw.cursor.set_track(t.id, lane.id)
  daw.keymap.feed("<CR>")
  local by, focused = panes()
  eq(focused and focused.view, "curve", "the curve pane has the keyboard")
  eq(by.curve.w > 100 and by.curve.h > 100, true, "with room to draw in")
end)

test("panes: :copen docks the quickfix list along the bottom, the whole width", function()
  start()
  daw.qf.set({ { address = daw.address.project(), text = "too loud", level = "error" } }, { title = "Test" })
  ex("copen")
  local by, focused = panes()
  eq(focused and focused.view, "qflist", "the list has the keyboard")
  eq(by.qflist.x .. " " .. by.qflist.w, "0 " .. W, "the whole width")
  eq(by.qflist.y + by.qflist.h, H, "along the bottom")
  eq(painted(by.qflist):find("too loud", 1, true) ~= nil, true, "showing its entries")
  ex("cclose")
  eq(panes().qflist, nil, ":cclose closes it")
end)

test("panes: a press gives a pane the keyboard, and a border dragged gives it a size", function()
  start()
  ex("sp quickfix")
  local by = panes()
  P.pointer(by.arrange.win, { kind = "down", x = 10, y = 10, button = "left" })
  local _, focused = panes()
  eq(focused.view, "arrange", "a press in the arrange view's pane")
  P.focus(by.qflist.win)
  _, focused = panes()
  eq(focused.view, "qflist", "and in the list's")
  local index
  for i, b in ipairs(P.state().borders) do
    if b.dir == "v" then index = i end
  end
  P.border(index, 100, H - 10 * daw.canvas.cell.h)
  by = panes()
  eq(math.abs(by.qflist.h - 10 * daw.canvas.cell.h) <= daw.canvas.cell.h, true, "ten rows high: " .. by.qflist.h)
end)

test("panes: tabs are listed with the row of them along the top, and a click on one goes there", function()
  start()
  ex("tabnew mixer")
  local state = P.state()
  eq(#state.tabs, 2, "two tabs")
  eq(state.tab, 2, "the new one")
  eq(state.top, P.tabline, "the panes start under the row of tabs")
  eq(state.panes[1].view .. " " .. state.panes[1].y, "mixer " .. P.tabline, "the mixer fills the tab")
  P.tab(1)
  eq(P.state().tab, 1, "a click goes to tab 1")
  daw.keymap.feed("gt")
  eq(P.state().tab, 2, "gt to the next")
  ex("tabclose")
end)

test("panes: a view that paints is docked where it docks, and popped out it gives the keyboard back", function()
  start()
  local seen = {}
  daw.ui.view("panes_probe", {
    title = "Probe",
    render = function(_, buf) buf:text(0, 0, "probe") end,
    paint = function(_, g, ctx)
      seen.size = ctx.width .. "x" .. ctx.height
      g:text(4, 4, "painted probe")
    end,
    pointer = function(_, e) seen.pointer = e.kind end,
  })
  daw.ui.dock("panes_probe", { side = "bottom", hidden = true })
  daw.canvas.open("panes_probe", { title = "The probe", width = 600, height = 300 })
  eq(daw.canvas.open_views.panes_probe, nil, "no window of its own")
  local by, focused = panes()
  eq(focused and focused.view, "panes_probe", "docked, with the keyboard")
  eq(by.panes_probe.kind .. " " .. by.panes_probe.title, "paint The probe", "painted, under the title it was opened with")
  eq(painted(by.panes_probe), "painted probe", "painted at the pane's size")
  eq(seen.size, by.panes_probe.w .. "x" .. by.panes_probe.h, "the pane's size")
  P.pointer(by.panes_probe.win, { kind = "down", x = 3, y = 3, button = "left" })
  eq(seen.pointer, "down", "the pointer reaches it")
  -- Popped out: the pane goes, and Esc in its window brings the keyboard back.
  daw.ui.focus("arrange")
  daw.canvas.open("panes_probe", { window = true })
  eq(daw.canvas.open_views.panes_probe ~= nil, true, "a window of its own on request")
  eq(panes().panes_probe, nil, "and no pane")
  daw.canvas.key("panes_probe", "<Esc>")
  eq(daw.canvas.open_views.panes_probe, nil, "Esc closes the window")
  local _, now = panes()
  eq(now.view, "arrange", "the keyboard is back where it was")
  daw.ui.hide("panes_probe")
  daw.ui.views.panes_probe = nil
end)

test("panes: keys typed in the main window while a view is popped out go to the window before it", function()
  start()
  ex("sp quickfix")
  local before = L.current()
  ex("view.window qflist")
  eq(daw.ui.focused, "qflist", "the window of its own has the keyboard")
  daw.frontend.act.keys("<Esc>")
  eq(L.current() == before and daw.ui.focused == before.view, false, "the list's pane went with it")
  daw.canvas.close("qflist")
  eq(daw.ui.focused ~= "qflist", true, "closing the window gives the keyboard back")
end)

test("panes: :view.open docks a view where it docks, else in a window split from this one", function()
  start()
  ex("view.open mixer")
  local by, focused = panes()
  eq(focused.view .. " " .. tostring(by.mixer ~= nil), "mixer true", "the mixer in its place")
  daw.ui.focus("arrange")
  ex("view.open qflist")
  by, focused = panes()
  eq(focused.view, "qflist", "the list split from the arrange view")
  eq(by.qflist.y > by.arrange.y, true, "below it")
end)

test("panes: every kind of buffer paints in a pane without failing", function()
  start()
  local t = daw.add_track({ name = "Pad" })
  local lane = t:automate("volume")
  local clip = t:add_clip({ start = 0, length = 4, notes = { { pitch = 60, start = 0, length = 1 } } })
  daw.cursor.set_track(t)
  local names = {
    daw.address.lane(lane.id), "daw://tempo", "quickfix", "daw://tracks", "daw://sends", "daw://markers",
    "daw://track/" .. t.id .. "/devices",
  }
  -- The views of the runtime and of the extensions loaded, as far as these
  -- tests have loaded them.
  for _, name in ipairs({ "empty", "eventlist", "notation", "drums", "utau", "utau_lyrics", "vinput", "doctor",
    "undotree", "undotree_paint", "mixdiag", "mixdiag_paint", "sections", "tutor", "tracklist" }) do
    if daw.ui.views[name] then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    L.restore(initial)
    daw.ui.focus("arrange")
    if name == "eventlist" then daw.ui.views.pianoroll:edit(clip) end
    local view, buf = L.resolve(name)
    local made = view and L.split({ view = view, buf = buf and not buf.single and buf.id or nil })
    if made then
      for _, pane in ipairs(P.state().panes) do
        if pane.win == made.id then
          local text = painted(pane)
          eq(text:find("traceback", 1, true), nil, name .. " paints: " .. text:sub(1, 300))
        end
      end
      -- Closed, so that an empty window's buffer is forgotten with it.
      L.close(made)
    end
  end
end)

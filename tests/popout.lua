-- Tests of views popped out of the graphical frontend's main area into
-- windows of their own and docked back: closing such a window, its Dock
-- button and `Ctrl-w d` put the view back as a pane, with the keyboard.
-- Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local L = daw.layout
local P = daw.panes
local function ex(line) return daw.commands.exec(line) end

local initial = L.capture()

local function tidy()
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
  P.area(1200, 700)
end

--- The pane showing a view, and the view of the pane with the keyboard.
local function pane(name)
  local found, focused
  for _, p in ipairs(P.state().panes) do
    if p.view == name then found = p end
    if p.focused then focused = p.view end
  end
  return found, focused
end

test("popout: Ctrl-w d in a popped out view docks it back where it was, with the keyboard", function()
  start()
  daw.ui.view("popout_probe", {
    title = "Probe",
    render = function(_, buf) buf:text(0, 0, "probe") end,
    paint = function(_, g) g:text(4, 4, "painted probe") end,
  })
  daw.ui.dock("popout_probe", { side = "bottom", hidden = true })
  daw.canvas.open("popout_probe", { title = "The probe" })
  local was = pane("popout_probe")
  eq(was ~= nil, true, "docked first")
  daw.canvas.open("popout_probe", { window = true })
  eq(pane("popout_probe"), nil, "popped out, no pane")
  daw.canvas.key("popout_probe", "<C-w>d")
  eq(daw.canvas.open_views.popout_probe, nil, "no window of its own")
  local now, focused = pane("popout_probe")
  eq(now and (now.y .. " " .. now.h), was.y .. " " .. was.h, "a pane where it was")
  eq(focused, "popout_probe", "with the keyboard")
  daw.ui.hide("popout_probe")
  daw.ui.views.popout_probe = nil
end)

test("popout: closing the window of a view that was never docked splits a pane for it", function()
  start()
  ex("view.window qflist")
  eq(daw.canvas.open_views.qflist ~= nil, true, "in a window of its own")
  eq(pane("qflist"), nil, "and in no pane")
  -- What the frontend calls when the window's close button is pressed.
  daw.canvas.dock("qflist")
  local now, focused = pane("qflist")
  eq(daw.canvas.open_views.qflist, nil, "the window is gone")
  eq(now ~= nil and focused, "qflist", "the list is a pane, with the keyboard")
end)

test("popout: view.dock in a view that is not in a window of its own leaves it where it is", function()
  start()
  ex("view.dock")
  local _, focused = pane("arrange")
  eq(focused, "arrange", "nothing moves")
end)

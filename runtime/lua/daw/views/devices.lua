-- The device panel: the cursor track's device chain and every parameter.
local api = daw.api
local util = daw.util

local view = { row = 1, scroll = 0 }
daw.seats.fields("devices", view, { "row", "scroll" }, { row = 1, scroll = 0 })

-- Built-in effects that show what they do under their name: how many rows,
-- and the function that draws them (in `daw.views.device_pictures`).
local pictures = require("daw.views.device_pictures")

-- Reading a plugin with hundreds of parameters is not free, so the rows are
-- kept until the project changes.
local cache = { revision = -1, track = nil, rows = {} }

--- The panel as a flat list of rows: a device heading, then its parameters.
local function rows_for(track_id)
  if cache.revision == daw.frontend.revision and cache.track == track_id then return cache.rows end
  local rows = {}
  for _, id in ipairs(track_id and api.track_get(track_id).devices or {}) do
    local device = api.device_get(id)
    rows[#rows + 1] = { device = device }
    local picture = device.format == "builtin" and pictures[device.kind]
    if picture and not device.missing then
      for line = 1, picture.rows do
        rows[#rows + 1] = { device = device, picture = picture, line = line }
      end
    end
    -- The host's wet/dry mix and output gain come last, after the device's own.
    for _, param in ipairs(device.param_info) do
      rows[#rows + 1] = { device = device, param = param, value = device.params[param.key], host = daw.fx.host_params[param.key] }
    end
  end
  cache = { revision = daw.frontend.revision, track = track_id, rows = rows }
  return rows
end

function view:rows()
  return rows_for(daw.cursor.track_id())
end

function view:render(buf, ctx)
  local g = daw.draw.g
  local track = daw.cursor.track()
  local rows = self:rows()
  local devices = 0
  for _, row in ipairs(rows) do if not row.param and not row.picture then devices = devices + 1 end end
  local inner = daw.ui.titlebar(buf, {
    name = "Devices", context = track and track.name or nil, focused = ctx.focused,
    right = devices > 0 and tostring(devices) or nil,
  })
  local w, h = inner.width, inner.height
  if #rows == 0 then
    inner:text(2, 1, "No devices.", "Empty")
    inner:text(2, 3, "a", "EmptyKey")
    inner:text(5, 3, "add one", "Empty")
    return
  end
  self.row = util.clamp(self.row, 1, #rows)
  if self.row <= self.scroll then self.scroll = self.row - 1 end
  if self.row > self.scroll + h then self.scroll = self.row - h end
  local name_w = math.min(12, math.max(4, w - 24))
  local value_w = 9
  local bar_at = 2 + name_w + 1
  local bar = math.max(3, w - bar_at - value_w - 1)
  for y = 0, h - 1 do
    local index = y + 1 + self.scroll
    local row = rows[index]
    if not row then break end
    local chosen = index == self.row and ctx.focused
    if chosen then
      inner:fill(0, y, w, 1, " ", "Selected")
      inner:text(0, y, g.mark, "SelectedMark")
    end
    local d = row.device
    if row.picture then
      -- Drawn whole from its first row, or from the top when scrolled into it.
      if row.line == 1 or y == 0 then
        local box = inner:sub(2, y - (row.line - 1), math.max(1, w - 3), row.picture.rows)
        row.picture.draw(box, d, chosen)
      end
    elseif not row.param then
      local name = util.fit(d.name, math.max(1, w - 16)):gsub("%s+$", "")
      inner:text(1, y, g.open .. " " .. name, d.bypass and "DeviceOff" or "DeviceName")
      -- The preset it holds, if one was loaded or saved.
      local preset = type(d.meta) == "table" and d.meta.preset
      local room = w - 16 - api.str_width(name) - 6
      if preset and room > 3 then inner:text(4 + api.str_width(name), y, util.fit(preset, room):gsub("%s+$", ""), "Param") end
      -- What modules mark on the device (`daw.ui.layer("devices", "device", ...)`):
      -- from `x`, `width` columns up to its on/off chip.
      local after = 4 + api.str_width(name)
      daw.ui.paint("devices", "device", { buf = inner, x = after, y = y, width = math.max(0, w - 6 - after), device = d.id })
      -- A device that is not running says so, and what brings it back.
      local status = d.status
      local mark = status == "loading" and { "loading", "Warn" }
        or status == "offline" and { "offline: o", "Dim" }
        or status == "missing" and { "not installed", "Error" }
        or (d.stopped or d.missing) and { "stopped: R restarts", "Error" }
      if mark then
        inner:text(math.max(2, w - #mark[1] - 1), y, mark[1], mark[2])
      else
        local chip = d.bypass and " off " or " on "
        local at = w - #chip - 1
        inner:text(at, y, chip, d.bypass and "Mute" or "FlagOff")
        if d.format ~= "builtin" then
          at = at - #d.format - 1
          inner:text(at, y, d.format, "DeviceFormat")
        end
        -- How much of it is heard, when not all of it: `h` `l` here change it.
        local wet = d.params.fx_wet
        if wet and wet < 100 then
          local text = string.format("wet %d%%", math.floor(wet + 0.5))
          at = at - #text - 1
          inner:text(at, y, text, "ParamValue")
        end
        -- The track it listens to as its side-chain (`K` chooses it), and
        -- how many of its further output pairs play somewhere (`O`).
        local further = #(d.ports and d.ports.outputs or {}) - 1
        local routed = 0
        for _ in pairs(d.outputs or {}) do routed = routed + 1 end
        for _, text in ipairs({
          further > 0 and string.format("outs %d/%d", routed, further) or false,
          daw.routes.sidechain_text(d) and "key " .. daw.routes.sidechain_text(d) or false,
        }) do
          local width = text and api.str_width(text) or 0
          if text and at - width - 1 > 4 + api.str_width(name) then
            at = at - width - 1
            inner:text(at, y, text, "ParamValue")
          end
        end
      end
    else
      local p = row.param
      inner:text(2, y, util.fit(p.name, name_w), chosen and "Bright" or row.host and "DeviceFormat" or "Param")
      daw.ui.paint("devices", "param", { buf = inner, x = 1, y = y, width = w, device = d.id, param = p.key })
      local range = p.max - p.min
      daw.draw.slider(inner, bar_at, y, bar, range ~= 0 and daw.params.fraction(p, row.value) or 0,
        chosen and "ParamBar" or "ParamBarDim", "ParamBarOff")
      local value = daw.frontend.format_value(p, row.value)
      if api.str_width(value) > value_w then value = util.fit(value, value_w) end
      inner:text(w - 1 - api.str_width(value), y, value, chosen and "Bright" or "ParamValue")
    end
  end
end

--- Move the selected parameter by `steps` out of 100 across its range.
function view:adjust(steps)
  local row = self:rows()[self.row]
  if not row then return end
  if row.picture then return end
  -- On the device's own line: its wet/dry mix.
  if not row.param then
    local wet = row.device.params.fx_wet
    if wet then api.device_set_param(row.device.id, "fx_wet", util.clamp(wet + steps, 0, 100)) end
    return
  end
  local p = row.param
  api.device_set_param(row.device.id, p.key, daw.params.step(p, row.value, steps))
end

function view:selected()
  local row = self:rows()[self.row]
  return row and daw.device(row.device.id), row
end

function view:on_mouse(event)
  if event.kind == "scroll_down" then self.row = self.row + 1 end
  if event.kind == "scroll_up" then self.row = self.row - 1 end
  if event.kind == "down" then self.row = event.y + self.scroll end
  api.ui_redraw()
end

daw.ui.view("devices", view)
return view

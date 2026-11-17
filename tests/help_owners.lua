-- `:help` on an extension's commands and keys lands in that extension's
-- pages, wherever else the manual names them, on the place it is described.
local T = ...
local test, eq = T.test, T.eq
local paw = require("paw")

local function load_all()
  for _, name in ipairs(paw.ext.bundled()) do paw.ext.load_bundled(name) end
end

test("help: every extension command and key finds where its own extension's pages describe it", function()
  T.fresh()
  load_all()
  local wrong, walked, unnamed = {}, 0, {}
  local function check(topic, owners)
    walked = walked + 1
    local tag = paw.help.lookup(topic)
    local ext = tag and tag.source.ext
    local ok = false
    for _, o in ipairs(owners) do ok = ok or ext == o end
    if not ok then
      wrong[#wrong + 1] = topic .. " (" .. table.concat(owners, "/") .. ") -> " .. (tag and (tag.source.name .. "#" .. tag.name) or "nothing")
    elseif tag.name == ext then
      -- Only the page: its README does not name it.
      unnamed[#unnamed + 1] = topic .. " (" .. ext .. ")"
    end
  end
  for _, spec in ipairs(paw.commands.list()) do
    if spec.ext and paw.ext.loaded[spec.ext] and paw.ext.loaded[spec.ext].ok then check(":" .. spec.name, { spec.ext }) end
  end
  local seen = {}
  for _, map in ipairs(paw.keymap.every()) do
    local topic = paw.keymap.human(map.lhs)
    if map.ext and not seen[topic] then
      seen[topic] = true
      local owners = paw.help.owners(topic)
      if #owners > 0 then check(topic, owners) end
    end
  end
  eq(walked > 200, true, "commands and keys walked: " .. walked)
  eq(table.concat(wrong, "\n"), "", "each lands in its extension's pages")
  eq(table.concat(unnamed, " "), "", "each is named in its extension's pages")
  -- The ones the review found.
  for topic, ext in pairs({ [":drums.track"] = "drums", [":art.measure"] = "articulations", [":Pdiff"] = "projdiff" }) do
    eq(paw.help.lookup(topic).source.ext, ext, topic)
  end
  -- A key the core maps stays the core's.
  eq(paw.help.lookup("gU").source.ext, nil, "gU is the core's")
end)

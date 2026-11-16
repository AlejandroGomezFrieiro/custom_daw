-- UTAU singing for daw: vocal tracks sung by OpenUtau's engines through
-- ReaUtau's reautau-engine. See README.md beside this file.
local api = daw.api

daw.option.define("utau_engine", "")         -- path to reautau-engine; found by itself when empty
daw.option.define("utau_openutau_dir", "")   -- OpenUtau's data folder (Singers, Resamplers); read only
daw.option.define("utau_data_dir", "")       -- the engine's own data folder; its default when empty
daw.option.define("utau_cache_dir", "")      -- the engine's render cache; its default when empty
daw.option.define("utau_log_level", "info")
daw.option.define("utau_default_lyric", "a") -- sung by notes that have no lyric
daw.option.define("utau_drafts", true)       -- quick drafts of DiffSinger phrases before final quality
daw.option.define("utau_final_delay", 1500)  -- ms of quiet after an edit before rendering final quality
daw.option.define("utau_render_timeout", 600) -- seconds an offline render waits for the singing
daw.option.define("utau_openutau", "")       -- command that opens a .ustx in OpenUtau; `OpenUtau` when empty

local utau = require("utau")
package.loaded["daw.utau"] = utau

utau.engine.reset_stale()

-- Any edit may change what is sung; the sync works out what did.
for _, pattern in ipairs({ "clip.*", "track.*", "device.*", "lane.*", "project.changed", "project.loaded" }) do
  daw.on(pattern, function() utau.schedule() end)
end
daw.on("project.loaded", function() utau.clear_voices() end)
-- The curves under a vocal clip go where the clip goes, in the same undo step.
require("utau.follow").attach()
daw.on("device.added", function() utau.assign_voices() end)
for _, name in ipairs({ "transport.play", "transport.stop", "transport.seek" }) do
  daw.on(name, function() utau.send_transport() end)
end

-- An offline render is only deterministic once every phrase is final.
daw.on("render.before", function()
  local ok, why = utau.finish(daw.opt.utau_render_timeout)
  if not ok then daw.notify("utau: rendering without finished singing: " .. tostring(why), "warn") end
end)

daw.every(25, function()
  if utau.engine.pump() then api.ui_redraw() end
end)

require("utau.editor")
require("utau.gui")
require("utau.commands")
require("utau.editor_keys")

utau.schedule()

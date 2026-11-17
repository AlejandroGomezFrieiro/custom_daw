-- The REAPER bridge: read and write REAPER projects (.rpp).
--
--   local rpp = require("rpp")
--   local doc = rpp.read("song.rpp")            -- the file as a tree
--   doc.project:set("TEMPO", 96, 4, 4, 0)
--   rpp.save(doc, "song.rpp")                   -- unchanged lines are written as read
--   local result = rpp.import("song.rpp")       -- into paw; result.report lists what stayed behind
--   rpp.export("out.rpp")                       -- paw's project as a REAPER project
local format = require("rpp.format")

local M = {
  format = format,
  parse = format.parse,
  write = format.write,
  read = format.read,
  save = format.save,
  line = format.line,
  block = format.block,
  document = format.document,
}

--- Import a .rpp file. Options: `merge` (add to the current project),
--- `instrument` (a device kind for MIDI tracks left without one).
function M.import(path, opts) return require("rpp.import").file(path, opts) end

--- Write the current project to a .rpp file.
function M.export(path, opts) return require("rpp.export").file(path, opts) end

--- Show a report in a page, and a one-line summary.
function M.show(report, summary)
  paw.notify(summary .. (report:empty() and "" or "; see the list of what was not carried over"),
    report:empty() and "info" or "warn")
  if not report:empty() then pcall(paw.ui.page, "REAPER bridge", report:lines(30)) end
end

return M

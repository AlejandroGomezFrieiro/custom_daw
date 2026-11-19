-- Changes made outside paw to the files of the open project: a `git
-- checkout`, another editor, a second program. The kernel watches the
-- folders and reports a burst of changes as one `files.changed`. paw acts
-- on them when you come back to it (at the next key), as
-- `paw.opt.on_external_change` says:
--
--   "ask"     (the default) ask on the command line: reload them, or keep
--             paw's version, which the next save writes over them
--   "reload"  read them again, as one undo step, when the project has no
--             change that is not saved; else ask
--   "keep"    keep paw's version, and say so once
local api = paw.api
local M = {}

require("paw.options").define("on_external_change", "ask", { type = "string", values = { "ask", "reload", "keep" } }) -- when a file of the project changes outside paw: "ask", "reload" or "keep"

--- The changed files as a short list for a message.
local function names(paths)
  local out = {}
  for i, p in ipairs(paths) do
    if i > 3 then
      out[#out + 1] = string.format("%d more", #paths - 3)
      break
    end
    out[#out + 1] = tostring(p)
  end
  return table.concat(out, ", ")
end

local function count(paths)
  return string.format("%d file%s", #paths, #paths == 1 and "" or "s")
end

--- Read the changed files again, as one undo step.
function M.reload()
  local paths = api.project_changed_files()
  local ok, err = pcall(api.project_reload)
  if not ok then return paw.notify("could not read the project again: " .. tostring(err):gsub("^[^:]*:%d+: ", ""), "error") end
  api.undo_label("read again from the disk")
  paw.notify(string.format("read again: %s changed outside paw (%s); `u` goes back", count(paths), names(paths)))
end

--- Keep paw's version of the project.
function M.keep()
  local paths = api.project_changed_files()
  api.project_keep_changes()
  paw.notify(string.format("kept paw's version: %s changed outside paw (%s); the next save writes over them, `:e!` reads them",
    count(paths), names(paths)))
end

local asking = false

--- Act on the changes as the option says: called at the next key after them.
function M.act()
  local paths = api.project_changed_files()
  if #paths == 0 or asking then return end
  local how = paw.opt.on_external_change
  if how == "keep" then return M.keep() end
  if how == "reload" and not api.project_get().modified then return M.reload() end
  asking = true
  require("paw.views.cmdline").ask_key(
    string.format("%s changed outside paw (%s): read again? y/n ", count(paths), names(paths)),
    function(key)
      asking = false
      if key == "y" or key == "Y" then M.reload() else M.keep() end
    end)
end

paw.on("files.changed", function()
  paw.keymap.on_next_key(M.act)
end)

return M

-- Clip owners: an extension that keeps a clip's notes as the rendering of
-- something of its own (a written score, say) is asked before anyone else
-- changes those notes, and says what the change means.
--
--   daw.clips.owner("notation", {
--     claims = function(clip) return clip.meta and clip.meta.score ~= nil end,
--     on_edit = function(clip, change) return { kind = "written", apply = fn, message = "..." } end,
--   })
--
-- `clip` is the clip as `daw.api.clip_get` gives it. `change` says what the
-- caller was about to do, as plain data: `set` (`{ { index, ... fields } }`),
-- `remove` (places), `add` (notes), or `replace` (every note, as
-- `clip:set_notes` gives them); places are among the notes as they are now.
-- The answer's `kind`:
--   "written", "feel"  the owner makes the change its own way: `apply()` is
--                      called instead of the write, and what it returns is
--                      returned to the caller (a note's place, for `set_note`)
--   "refuse"           nothing is written; `message` says why
--   nil, or no answer  the write goes ahead as asked
-- The owner's own writes go through `daw.api` (`clip_notes_edit`,
-- `clip_set_notes`), which is not asked. Every note write of `daw.Clip`,
-- and so of the piano roll, the window's gestures, `daw.edit` and edits
-- from language servers, asks.
local api = daw.api

local M = { owners = {} }

--- Name an owner of clips, or with `spec` nil forget it.
function M.owner(name, spec)
  M.owners[name] = spec
end

--- Ask the owner of a clip, if it has one, about a change of its notes.
--- Returns whether the owner took the change (and then what to return),
--- or false for the caller to write it as asked.
function M.write(id, change)
  if next(M.owners) == nil then return false end
  local ok, clip = pcall(api.clip_get, id)
  if not ok or clip.kind ~= "midi" then return false end
  for name, spec in pairs(M.owners) do
    if spec.claims(clip) then
      local answer = spec.on_edit(clip, change)
      if type(answer) ~= "table" or answer.kind == nil then return false end
      if answer.kind == "refuse" then
        daw.notify(answer.message or ("these notes are written by " .. name), "warn")
        return true
      end
      local result = answer.apply and answer.apply()
      if answer.message then daw.notify(answer.message) end
      return true, result
    end
  end
  return false
end

--- The name of a clip's owner, or nil.
function M.owner_of(id)
  local ok, clip = pcall(api.clip_get, id)
  if not ok then return nil end
  for name, spec in pairs(M.owners) do
    if spec.claims(clip) then return name end
  end
end

return M

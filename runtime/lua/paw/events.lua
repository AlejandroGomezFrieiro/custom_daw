-- Publish/subscribe. The kernel reports project changes here, and extensions
-- can emit and listen for events of their own.
--
-- A handler name is an exact event (`track.added`), a family (`track.*`), or
-- `*` for everything. Handlers receive `(payload, event_name)`.
local M = {}

local handlers = {} -- pattern -> list of { id, fn, once }
local next_id = 0

--- Listen for an event. Returns a handle for `daw.off`.
function M.on(pattern, fn, opts)
  assert(type(pattern) == "string" and type(fn) == "function", "usage: daw.on(event, function)")
  next_id = next_id + 1
  handlers[pattern] = handlers[pattern] or {}
  table.insert(handlers[pattern], { id = next_id, fn = fn, once = opts and opts.once })
  return next_id
end

function M.once(pattern, fn)
  return M.on(pattern, fn, { once = true })
end

function M.off(id)
  for _, list in pairs(handlers) do
    for i = #list, 1, -1 do
      if list[i].id == id then table.remove(list, i) end
    end
  end
end

local function run(list, name, payload)
  if not list then return end
  -- Copy, so handlers may add or remove handlers while running.
  for _, h in ipairs({ unpack(list) }) do
    if h.once then M.off(h.id) end
    daw.try(daw.limit.named, "a handler of `" .. name .. "`", h.fn, payload, name)
  end
end

--- Call every handler for `name`. A failing handler is reported and skipped.
function M.emit(name, payload)
  payload = payload or {}
  run(handlers[name], name, payload)
  local family = name:match("^(.-)%.[^.]*$")
  if family then run(handlers[family .. ".*"], name, payload) end
  run(handlers["*"], name, payload)
end

return M

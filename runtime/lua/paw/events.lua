-- Publish/subscribe. The kernel reports project changes here, and extensions
-- can emit and listen for events of their own.
--
-- A handler name is an exact event (`track.added`), a family (`track.*`), or
-- `*` for everything. Handlers receive `(payload, event_name)`.
local M = {}

local handlers = {} -- pattern -> list of { id, fn, once }
local next_id = 0

--- Listen for an event. Returns a handle for `paw.off`.
function M.on(pattern, fn, opts)
  assert(type(pattern) == "string" and type(fn) == "function", "usage: paw.on(event, function)")
  next_id = next_id + 1
  handlers[pattern] = handlers[pattern] or {}
  table.insert(handlers[pattern], { id = next_id, fn = fn, once = opts and opts.once, pattern = pattern })
  return next_id
end

--- Listen for an event once: the handler is removed after its first call.
function M.once(pattern, fn)
  return M.on(pattern, fn, { once = true })
end

--- Stop a listener: `id` is the value that `paw.on` or `paw.once` returned.
function M.off(id)
  for _, list in pairs(handlers) do
    for i = #list, 1, -1 do
      if list[i].id == id then table.remove(list, i) end
    end
  end
end

--- Every handler, by its handle: `{ pattern, fn }`.
function M.handlers()
  local out = {}
  for _, list in pairs(handlers) do
    for _, h in ipairs(list) do out[h.id] = h end
  end
  return out
end

--- True if a handler listens for `name` by its name or its family (not
--- `*`). Use it for events that are expensive to make.
function M.listened(name)
  local family = name:match("^(.-)%.[^.]*$")
  return (handlers[name] and #handlers[name] > 0) or (family and handlers[family .. ".*"] and #handlers[family .. ".*"] > 0) or false
end

-- The first refusal: a handler that returned false, and why.
local refused, reason

local function run(list, name, payload)
  if not list then return end
  -- Copy, so handlers may add or remove handlers while running.
  for _, h in ipairs({ unpack(list) }) do
    if h.once then M.off(h.id) end
    local ok, answer, why = paw.try(paw.limit.named, "a handler of `" .. name .. "`", h.fn, payload, name)
    if ok and answer == false and not refused then refused, reason = true, why end
  end
end

--- Call each handler for `name`. paw reports a handler that fails, and goes
--- to the next. Returns true, or false and the reason when a handler
--- returned `false, reason`. So a handler refuses the request of an event
--- (`edit.before`, `project.saving`, `key.pre`).
function M.emit(name, payload)
  payload = payload or {}
  local outer, outer_reason = refused, reason
  refused, reason = nil, nil
  run(handlers[name], name, payload)
  local family = name:match("^(.-)%.[^.]*$")
  if family then run(handlers[family .. ".*"], name, payload) end
  run(handlers["*"], name, payload)
  local no, why = refused, reason
  refused, reason = outer, outer_reason
  if no then return false, why end
  return true
end

return M

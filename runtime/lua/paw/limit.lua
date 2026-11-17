-- A time limit on Lua that runs away. A key handler, a command, an event
-- handler, a timer or a view that runs for more than `daw.opt.lua_limit`
-- milliseconds (2000) without returning is stopped with an error naming it,
-- instead of freezing the program.
--
-- How: while the kernel is in Lua for a key, a timer, events or drawing, it
-- knows when that call must have returned. Nothing looks at the clock while
-- the call runs. A thread in the kernel does, and only when the time is up
-- does it set a hook from outside, which the kernel's LuaJIT is built to
-- notice inside compiled loops as well (`crates/daw-core/src/watchdog.rs`).
-- So everything is compiled, extensions included, and the limit costs
-- nothing until it is needed.
--
-- A kernel built against a LuaJIT without that (`daw.api.limit_async` is
-- false) does it the old way: a count hook looks at the clock every few
-- thousand instructions, and since LuaJIT does not call hooks from compiled
-- code, code that is not the runtime's own (extensions, the user's
-- `init.lua` and modules, `:lua`) is kept out of the compiler.
--
-- `-l` scripts and `daw.wait` run outside any limit; `:lua` gets a minute.
local api = daw.api
local M = {}

local CHECK_EVERY = 100000  -- instructions between looks at the clock

local deadline     -- when the running callback must have returned, or nil
local what = {}    -- a stack of what is running, for the error

daw.option.define("lua_limit", 2000)

local async = api.limit_async == true

--- Set when the running call must have returned (nil: it has).
local function set(to)
  deadline = to
  if async then api.limit_watch(to) end
end

local function hook()
  if not deadline then return end
  if api.now() > deadline then
    local name = what[#what] or "a callback"
    -- Another full stretch for whatever runs after the error, such as the
    -- handler that reports it.
    set(api.now() + (daw.opt.lua_limit or 2000))
    error(string.format("%s ran for more than %g s without returning, and was stopped", name,
      (daw.opt.lua_limit or 2000) / 1000), 2)
  end
  -- Called early (the limit moved after the kernel's thread looked): the
  -- thread is told again.
  set(deadline)
end
if async then api.limit_hook(hook) end

--- Call `fn(...)` as `daw.try` does (an error becomes a message), with the
--- time limit. The kernel's ways into Lua go through here. Inside a call
--- that is limited already, it is `daw.try`.
function M.guard(name, fn, ...)
  if deadline or (daw.opt.lua_limit or 0) <= 0 then return daw.try(fn, ...) end
  set(api.now() + daw.opt.lua_limit)
  what = { name }
  if not async then debug.sethook(hook, "", CHECK_EVERY) end
  local result = { daw.try(fn, ...) }
  if not async then debug.sethook() end
  set(nil)
  what = {}
  return unpack(result)
end

--- Name what runs inside the limited call, for the error should it run away:
--- `daw.limit.named("command `x`", fn, ...)`.
function M.named(name, fn, ...)
  if not deadline then return fn(...) end
  local depth = #what
  what[depth + 1] = name
  local result = { fn(...) }
  for i = #what, depth + 1, -1 do what[i] = nil end
  return unpack(result)
end

--- Give the running call more time, as `:lua` does: `ms` from now.
function M.extend(ms)
  if deadline then set(math.max(deadline, api.now() + ms)) end
end

--- Mark a function that is not the runtime's own. Where the limit reaches
--- into compiled code this does nothing. Where it does not, the function
--- and every function made inside it are kept out of the JIT compiler, so
--- that the limit can stop their loops (unless the limit is turned off with
--- `daw.opt.lua_limit = 0` before the code is loaded).
function M.untrusted(fn)
  if not async and type(fn) == "function" and jit and jit.off and (daw.opt.lua_limit or 0) > 0 then
    jit.off(fn, true)
  end
  return fn
end

--- Run `fn(...)` with its time not counted, for work that is known to be
--- long and to end: `daw.limit.unhurried(synthesise, phrase)`. Callbacks
--- the kernel makes meanwhile (timers during a wait) get a limit of their
--- own.
function M.unhurried(fn, ...)
  if not deadline then return fn(...) end
  local was, names, before = deadline, what, api.now()
  set(nil)
  what = {}
  local result = { pcall(fn, ...) }
  what = names
  set(was + (api.now() - before))
  if not async then debug.sethook(hook, "", CHECK_EVERY) end
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, table.maxn(result))
end

-- Waiting in the kernel is not Lua running away: a render, a project being
-- read, a plugin being made, a wait.
for _, name in ipairs({ "wait", "render", "project_load", "project_save", "device_add", "device_restart",
  "device_editor", "engine_restart", "import_audio", "clip_import" }) do
  local inner = api[name]
  if type(inner) == "function" then
    api[name] = function(...) return M.unhurried(inner, ...) end
  end
end

-- Modules found on disk (extensions' `lua/` directories, the user's own)
-- are untrusted, unless they are the runtime's files.
do
  local loaders = package.loaders
  local disk = loaders[2]
  if disk and not M.wrapped then
    M.wrapped = true
    loaders[2] = function(name)
      local chunk = disk(name)
      if type(chunk) == "function" then
        local source = debug.getinfo(chunk, "S").source or ""
        if not source:find("runtime/lua/daw/", 1, true) then M.untrusted(chunk) end
      end
      return chunk
    end
  end
end

return M

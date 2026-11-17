-- Versions of a project to compare: a file, a revision in git, a state of
-- the undo tree or a snapshot, as decoded project files; and what to do with
-- the difference (the view, quickfix).
local data = require("projdiff.data")
local diff = require("projdiff.diff")
local merge = require("projdiff.merge")
local text = require("projdiff.text")

local M = { data = data, diff = diff, merge = merge, text = text }

-- Snapshots of a project that has no file yet, by name: as checkpoints are,
-- but kept in this session.
local memory = {}

local function quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function read(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local content = file:read("*a")
  file:close()
  return content
end
M.read = read

--- A project file's text as a decoded file, or nil and why.
function M.decode(content, what)
  local doc, err = daw.api.json_decode(content or "")
  if type(doc) ~= "table" or type(doc.project) ~= "table" then
    return nil, (what or "the text") .. " is not a project file" .. (err and (": " .. tostring(err)) or "")
  end
  return doc
end

--- A project file on disk, decoded.
function M.file(path)
  local content, err = read(path)
  if not content then return nil, tostring(err) end
  return M.decode(content, path)
end

--- What a revision of git holds as `path`, decoded.
function M.git(rev, path)
  local dir = path:match("^(.*)/[^/]*$") or "."
  local name = path:match("[^/]*$")
  local top = io.popen("git -C " .. quote(dir) .. " rev-parse --show-prefix 2>/dev/null")
  local prefix = top and top:read("*l") or ""
  if top then top:close() end
  local show = io.popen("git -C " .. quote(dir) .. " show " .. quote(rev .. ":" .. prefix .. name) .. " 2>/dev/null")
  local content = show and show:read("*a") or ""
  if show then show:close() end
  if content == "" then return nil, "git has no " .. name .. " at " .. rev end
  return M.decode(content, name .. " at " .. rev)
end

--- The project as it is in an undo state (the current one by default).
function M.state(id)
  local ok, project = pcall(daw.api.undo_project, id)
  if not ok then return nil, tostring(project):match("[^\n]*") end
  return { version = 1, project = project }
end

--- The snapshots there are: `{ name, file?, time? }`, the oldest first.
function M.snapshots()
  local out = {}
  for _, c in ipairs(daw.api.checkpoint_list()) do out[#out + 1] = { name = c.name, file = c.file, time = c.time } end
  for _, name in ipairs(data.sorted_keys(memory)) do out[#out + 1] = { name = name } end
  return out
end

--- Keep the project as it is now under a name: beside the project when it
--- has a file, in this session when it has not.
function M.snapshot(name)
  name = name and name:match("^%s*(.-)%s*$") or ""
  if name == "" then name = os.date("snapshot %H:%M:%S") end
  if daw.api.checkpoint_dir() then
    local made = daw.api.checkpoint_write(name)
    return name, made.file
  end
  memory[name] = daw.api.undo_project(nil)
  return name
end

local function snapshot_doc(name)
  local found
  for _, s in ipairs(M.snapshots()) do
    if s.name == name then found = s end
  end
  if not found then return nil, "no snapshot named " .. name .. " (`:Psnapshot " .. name .. "` makes one)" end
  if found.file then return M.file(found.file) end
  return { version = 1, project = memory[name] }
end

--- A version of the project named in the words `:Pdiff` takes: a file, `#12`
--- (a state of the undo tree), `snap:name`, `now` (the project as it is), or
--- a revision of git (`HEAD`, `main~3`) for the project's own file.
--- Returns the decoded file and a label for titles.
function M.version(spec)
  local project = daw.api.project_get()
  if spec == "now" then
    local doc, err = M.state(nil)
    return doc, "now", err
  end
  local n = spec:match("^#(%d+)$")
  if n then
    local doc, err = M.state(tonumber(n))
    return doc, "#" .. n, err
  end
  local name = spec:match("^snap:(.+)$")
  if name then
    local doc, err = snapshot_doc(name)
    return doc, name, err
  end
  local file = io.open(spec, "rb")
  if file then
    file:close()
    local doc, err = M.file(spec)
    return doc, spec:match("[^/]*$"), err
  end
  if not project.path then return nil, spec, "the project has no file yet, so there is no revision of it: " .. spec .. " is not a file either" end
  local doc, err = M.git(spec, project.path)
  return doc, spec, err
end

--- What `:Pdiff` compares for the words given: nothing is the project's
--- file against the project now, one version is it against now, two are
--- from the first to the second. Returns `{ from, to, from_label, to_label }`.
function M.compare(args)
  local project = daw.api.project_get()
  local first, second = args[1], args[2]
  if not first then
    if not project.path then return nil, "the project has no file to compare with: `:Pdiff #3` or `:Pdiff snap:name`" end
    first = project.path
  end
  local a, label_a, err_a = M.version(first)
  if not a then return nil, err_a end
  local b, label_b, err_b = M.version(second or "now")
  if not b then return nil, err_b end
  if not second and first == project.path then label_a = "saved" end
  return { from = a, to = b, from_label = label_a, to_label = label_b }
end

--- Send the changes to the quickfix list, one entry each.
function M.to_quickfix(tree, title)
  local entries = {}
  for i, e in ipairs(diff.entries(tree)) do
    entries[i] = { address = e.address, text = e.text, level = e.sign == "-" and "warning" or "info" }
  end
  daw.qf.set(entries, { title = title })
  return #entries
end

return M

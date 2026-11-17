-- More pickers: what the project holds (markers, notes, media, its text),
-- its history, and what the program knows (help, extensions, the Lua API).
-- Each has a location where it can, so that `Ctrl-v`, `Ctrl-x`, `Ctrl-t`
-- and `Ctrl-q` work in it (see daw/pick.lua, "Keys every picker has").
return function(pick, S)
  local api = daw.api
  local A = daw.address
  local preview = require("daw.pick.preview")

  local function plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

  -- Help ---------------------------------------------------------------------------

  S.help = {
    desc = "Go to a help tag",
    title = "Help",
    items = function() return daw.help.index().list end,
    format = function(tag) return string.format("%-34s %s", tag.name, tag.source.name) end,
    primary = function(tag) return tag.name end,
    on_choose = function(tag) daw.help.jump(tag) end,
    location = function(tag) return { uri = "daw://help/" .. tag.source.name, selector = { line = tag.row, col = tag.col } } end,
    -- A page shown in a window split off this one, or in a tab of its own.
    open = function(tag, how)
      local L = daw.layout
      local buf = L.buf_create("textbuf", "help://" .. tag.source.name)
      if how == "tab" then
        L.tab_new(nil, "empty")
        L.show_in(L.current(), "textbuf", buf.id)
      else
        local made, why = L.split({ vertical = how == "vsplit", view = "textbuf", buf = buf.id })
        if not made then daw.notify(why, "warn") end
      end
      daw.help.show(tag.source, tag.row, tag.col)
    end,
    preview = function(tag, _, height)
      local lines = {}
      local doc = tag.source.doc and tag.source.doc.lines or {}
      for row = tag.row, math.min(#doc, tag.row + (height or 20)) do
        local line = doc[row]
        lines[#lines + 1] = { text = line.text, style = row == tag.row and "Title" or nil }
      end
      return lines
    end,
  }

  -- Markers and regions ----------------------------------------------------------

  S.markers = {
    desc = "Go to a marker or region",
    title = "Markers and regions",
    empty = "No markers. `g'` puts one at the cursor, `:region` makes a region.",
    items = function() return daw.markers.list() end,
    format = function(m)
      local where = daw.time.format(m.beat)
      if m.length then where = where .. " – " .. daw.time.format(m.beat + m.length) end
      return string.format("%-7s %-24s %s", m.length and "region" or "marker", daw.markers.label(m), where)
    end,
    primary = function(m) return daw.markers.label(m) end,
    location = function(m) return { uri = A.marker(m.id), selector = { time = { m.beat, m.beat } } } end,
    on_choose = function(m)
      daw.keymap.push_jump()
      daw.ui.focus("arrange")
      daw.cursor.set_beat(m.beat)
      if daw.ui.views.arrange.center then daw.ui.views.arrange:center() end
    end,
    delete = function(list)
      api.undo_label("Remove markers")
      for _, m in ipairs(list) do daw.markers.remove(m.id) end
    end,
    preview = function(m)
      local lines = { { text = daw.markers.label(m), style = "Title" }, "", (m.length and "region from " or "marker at ") .. daw.time.format(m.beat) }
      if m.length then lines[#lines + 1] = string.format("to %s, %g beats", daw.time.format(m.beat + m.length), m.length) end
      -- What plays there: the clips that start within a bar of it.
      lines[#lines + 1] = ""
      for _, id in ipairs(api.track_list()) do
        for _, c in ipairs(api.clip_list(id)) do
          if c.start <= m.beat + (m.length or 0) and c.start + c.length > m.beat then
            lines[#lines + 1] = string.format("  %-16s %s", api.track_get(id).name, c.name)
          end
        end
      end
      return lines
    end,
  }

  -- Notes ------------------------------------------------------------------------

  -- A note's line: pitch, velocity, lyric and articulations, where it is.
  local function note_line(node)
    local n = node.data
    local m = type(n.meta) == "table" and n.meta or {}
    local words = {}
    if type(m.lyric) == "string" and m.lyric ~= "" then words[#words + 1] = "“" .. m.lyric .. "”" end
    for _, art in ipairs(daw.query.articulations(node)) do words[#words + 1] = art end
    local clip = node.parent.data
    return string.format("%-4s %3d %-18s %-14s %s", daw.music.name(n.pitch), n.velocity, table.concat(words, " "),
      daw.util.fit(clip.name, 14), daw.time.format(clip.start + n.start))
  end

  S.notes = {
    desc = "Find a note by pitch, lyric or articulation",
    title = "Notes",
    empty = "No notes in the project.",
    items = function() return daw.query.run("note") end,
    format = note_line,
    location = function(node) return node.location end,
    on_choose = function(node)
      daw.keymap.push_jump()
      daw.qf.go({ location = node.location })
    end,
    delete = function(nodes)
      local by_clip, order = {}, {}
      for _, node in ipairs(nodes) do
        if not by_clip[node.clip] then
          by_clip[node.clip] = {}
          order[#order + 1] = node.clip
        end
        local list = by_clip[node.clip]
        list[#list + 1] = node.place
      end
      api.undo_label("Remove notes")
      for _, id in ipairs(order) do daw.clip(id):edit_notes({ remove = by_clip[id] }) end
      daw.notify("removed " .. plural(#nodes, "note"))
    end,
    preview = function(node, width, height)
      local n = node.data
      local lines = { { text = note_line(node), style = "Title" }, "" }
      for _, line in ipairs(preview.roll(node.clip, width or preview.width(), math.max(4, (height or 20) - 4), n.id)) do lines[#lines + 1] = line end
      return lines
    end,
    -- Heard through its track: the note, with the others that start with it.
    audition_key = "notes",
    audition = function(node)
      local n = node.data
      local notes = {}
      for _, other in ipairs(api.clip_notes(node.clip)) do
        if math.abs(other.start - n.start) < 1e-9 then
          notes[#notes + 1] = { pitch = other.pitch, start = 0, length = math.min(other.length, 2), velocity = other.velocity }
        end
      end
      daw.audition.phrase(node.track, notes, { length = math.min(n.length, 2) + 0.5, loop = false, label = daw.music.name(n.pitch), key = "note" .. node.clip .. ":" .. tostring(n.id) })
      return daw.music.name(n.pitch) .. " · " .. daw.audition.through(node.track)
    end,
  }

  -- Media ----------------------------------------------------------------------------

  S.media = {
    desc = "Sound files the project uses",
    title = "Media",
    empty = "The project uses no sound files.",
    items = function()
      local out, users = {}, {}
      for _, id in ipairs(api.track_list()) do
        for _, c in ipairs(api.clip_list(id)) do
          if c.file then
            local key = tostring(c.file)
            users[key] = users[key] or {}
            table.insert(users[key], c)
          end
        end
      end
      local seen = {}
      for _, entry in ipairs(api.media_list()) do
        local path = tostring(type(entry) == "table" and (entry.path or entry.file) or entry)
        if not seen[path] then
          seen[path] = true
          out[#out + 1] = { path = path, clips = users[path] or {} }
        end
      end
      for path, clips in pairs(users) do
        if not seen[path] then out[#out + 1] = { path = path, clips = clips } end
      end
      table.sort(out, function(a, b) return a.path < b.path end)
      return out
    end,
    format = function(f) return string.format("%-40s %s", f.path:match("[^/]*$"), plural(#f.clips, "clip")) end,
    location = function(f) return f.clips[1] and { uri = A.clip(f.clips[1].id) } or nil end,
    on_choose = function(f)
      local track = daw.cursor.track()
      if not track then return daw.notify("no track selected", "warn") end
      track:add_clip({ start = daw.cursor.beat, file = f.path })
    end,
    choose = "add at the cursor",
    audition_key = "files",
    audition = function(f) return pick.hear_file(f.path) end,
    preview = function(f)
      local lines = { { text = f.path:match("[^/]*$"), style = "Title" }, f.path, "" }
      for _, c in ipairs(f.clips) do lines[#lines + 1] = string.format("  %-16s %s", c.name, daw.time.format(c.start)) end
      lines[#lines + 1] = ""
      lines[#lines + 1] = { text = "Enter adds it at the cursor; Ctrl-v shows the first clip that plays it", style = "Dim" }
      return lines
    end,
  }

  -- Text: a live grep -----------------------------------------------------------------

  S.grep = {
    desc = "Find any text in the project: names, lyrics, articulations, comments",
    title = "Text in the project",
    empty = "The project has no text in it yet.",
    mode = "exact",
    items = function() return daw.grep.records() end,
    format = function(r) return string.format("%-8s %-28s %s", r.field, daw.util.fit(r.where or "", 28), r.text) end,
    primary = function(r) return r.text end,
    location = function(r) return r.location end,
    on_choose = function(r)
      daw.keymap.push_jump()
      daw.qf.go({ location = r.location })
    end,
    preview = function(r, width, height)
      local lines = { { text = r.text, style = "Title" }, "", r.field .. " · " .. tostring(r.where or ""), "" }
      local parsed = r.location and A.parse(r.location.uri)
      if parsed and parsed.clip then
        local focus = parsed.kind == "note" and parsed.note or nil
        for _, line in ipairs(preview.clip(parsed.clip, width or preview.width(), math.max(4, (height or 20) - 5), focus)) do lines[#lines + 1] = line end
      end
      return lines
    end,
  }

  -- The quickfix list ------------------------------------------------------------------

  S.quickfix = {
    desc = "The entries of the quickfix list",
    title = "Quickfix",
    empty = "The quickfix list is empty.",
    items = function()
      local list = daw.qf.current()
      local out = {}
      for i, e in ipairs(list and list.entries or {}) do out[i] = { index = i, entry = e } end
      return out
    end,
    format = function(x)
      local e = x.entry
      return string.format("%-24s %s%s", daw.util.fit(daw.qf.where(e), 24), e.level and e.level .. ": " or "", e.text)
    end,
    location = function(x) return x.entry.location end,
    on_choose = function(x) daw.qf.jump(x.index) end,
  }

  -- Undo states ---------------------------------------------------------------------

  local function ago(t)
    local s = math.max(0, os.time() - (tonumber(t) or os.time()))
    if s < 60 then return s .. " s ago" end
    if s < 3600 then return math.floor(s / 60) .. " min ago" end
    return os.date("%H:%M", t)
  end

  S.undo = {
    desc = "Go to a state of the undo history",
    title = "Undo history",
    items = function()
      local tree = api.undo_tree()
      local out = {}
      for _, s in ipairs(tree.states) do out[#out + 1] = s end
      table.sort(out, function(a, b) return a.id > b.id end)
      return out
    end,
    format = function(s)
      local mark = s.current and "●" or s.saved and "S" or " "
      local label = s.name or s.label or (s.parent and "edit" or "the project as opened")
      return string.format("%s #%-4d %-34s %s", mark, s.id, daw.util.fit(tostring(label), 34), ago(s.time))
    end,
    choose = "go there",
    on_choose = function(s)
      api.undo_goto(s.id)
      daw.notify("at state #" .. s.id)
    end,
    preview = function(s)
      local current = api.undo_current()
      local lines = { { text = string.format("#%d  %s", s.id, tostring(s.name or s.label or "")), style = "Title" } }
      if s.keys and s.keys ~= "" then lines[#lines + 1] = "keys    " .. s.keys end
      lines[#lines + 1] = ""
      if s.id == current then
        lines[#lines + 1] = { text = "the state the project is in", style = "Dim" }
        return lines
      end
      local ok, diff = pcall(api.undo_diff, current, s.id)
      if ok and diff then
        lines[#lines + 1] = { text = "going there changes:", style = "HelpSection" }
        for _, item in ipairs(diff.items or {}) do lines[#lines + 1] = { text = item, style = item:sub(1, 1) == "+" and "Info" or item:sub(1, 1) == "-" and "Warn" or nil } end
      end
      return lines
    end,
  }

  -- Extensions ----------------------------------------------------------------------

  local function readme(path, rows)
    local file = path and io.open(path .. "/README.md", "rb")
    if not file then return {} end
    local out = {}
    for line in file:lines() do
      if #out >= rows then break end
      out[#out + 1] = line
    end
    file:close()
    return out
  end

  S.extensions = {
    desc = "Extensions: loaded, and those that come with the program",
    title = "Extensions",
    items = function()
      local out, seen = {}, {}
      for _, e in ipairs(daw.ext.list()) do
        seen[e.name] = true
        out[#out + 1] = { name = e.name, path = e.path, loaded = true, ok = e.ok, error = e.error }
      end
      local dir = daw.ext.bundled_dir()
      for _, name in ipairs(daw.ext.bundled()) do
        if not seen[name] then out[#out + 1] = { name = name, path = dir and dir .. "/" .. name, loaded = false } end
      end
      return out
    end,
    format = function(e)
      return string.format("%-14s %s", e.name, not e.loaded and "not loaded" or e.ok and "loaded" or "failed")
    end,
    primary = function(e) return e.name end,
    choose = "help, or load",
    on_choose = function(e)
      if e.loaded then return daw.help.open(e.name) end
      local entry, why = daw.ext.load_bundled(e.name)
      if not entry then return daw.notify(why, "warn") end
      daw.notify(entry.ok and "loaded " .. e.name or e.name .. " failed to load", entry.ok and "info" or "error")
    end,
    preview = function(e, _, height)
      local lines = { { text = e.name, style = "Title" }, tostring(e.path or ""), "" }
      if e.error then lines[#lines + 1] = { text = tostring(e.error):match("^[^\n]*"), style = "Error" } end
      for _, line in ipairs(readme(e.path, (height or 20) - #lines)) do lines[#lines + 1] = line end
      return lines
    end,
  }

  -- The Lua API -------------------------------------------------------------------------

  local files = {}

  --- The comment right above a function's definition, from its source file.
  local function doc_of(fn)
    local info = debug.getinfo(fn, "S")
    local path = info and info.source and info.source:match("^@(.+)$")
    if not path or info.linedefined < 1 then return nil end
    local lines = files[path]
    if not lines then
      lines = {}
      local file = io.open(path, "rb")
      if file then
        for line in file:lines() do lines[#lines + 1] = line end
        file:close()
      end
      files[path] = lines
    end
    local out = {}
    local row = info.linedefined - 1
    while row >= 1 and lines[row] and lines[row]:match("^%s*%-%-") do
      table.insert(out, 1, (lines[row]:gsub("^%s*%-%-%-?%s?", "")))
      row = row - 1
    end
    return out, path:match("runtime/lua/(.*)$") or path, info.linedefined
  end

  --- `name(a, b)`: a function with the names of its parameters.
  local function signature(name, fn)
    local params = {}
    for i = 1, 16 do
      local ok, p = pcall(debug.getlocal, fn, i)
      if not ok or not p then break end
      params[#params + 1] = p
    end
    local info = debug.getinfo(fn, "u")
    if info and info.isvararg then params[#params + 1] = "..." end
    return name .. "(" .. table.concat(params, ", ") .. ")"
  end

  local SKIP = { _kernel = true, state = true, opt = true }

  S.symbols = {
    desc = "The Lua API: every function of `daw`",
    title = "Lua API",
    items = function()
      local out = {}
      local function add(name, fn)
        out[#out + 1] = { name = name, fn = fn, text = signature(name, fn) }
      end
      local names = {}
      for k in pairs(daw) do
        if type(k) == "string" and not SKIP[k] then names[#names + 1] = k end
      end
      table.sort(names)
      for _, k in ipairs(names) do
        local v = rawget(daw, k)
        if type(v) == "function" then
          add("daw." .. k, v)
        elseif type(v) == "table" then
          local inner = {}
          for k2, v2 in pairs(v) do
            if type(k2) == "string" and type(v2) == "function" and k2:sub(1, 1) ~= "_" then inner[#inner + 1] = k2 end
          end
          table.sort(inner)
          for _, k2 in ipairs(inner) do add("daw." .. k .. "." .. k2, v[k2]) end
        end
      end
      return out
    end,
    format = function(s) return s.text end,
    primary = function(s) return s.name end,
    choose = "help",
    on_choose = function(s)
      local tag = daw.help.lookup(s.name)
      if tag and tag.name:find(s.name, 1, true) then return daw.help.jump(tag) end
      local doc, where, line = doc_of(s.fn)
      local lines = { { text = s.text, style = "Title" }, "" }
      for _, l in ipairs(doc or { "(no comment above it)" }) do lines[#lines + 1] = l end
      if where then
        lines[#lines + 1] = ""
        lines[#lines + 1] = { text = where .. ":" .. line, style = "Dim" }
      end
      daw.ui.page(s.name, lines)
    end,
    insert = function(s)
      daw.ui.input({ prompt = ":", history = "cmdline", text = "lua " .. s.name .. "(" }, function(line)
        if line:match("%S") then daw.commands.exec(line) end
      end)
    end,
    preview = function(s)
      local lines = { { text = s.text, style = "Title" }, "" }
      local doc, where, line = doc_of(s.fn)
      if not doc then
        lines[#lines + 1] = { text = "a function of the kernel (docs/scripting.md)", style = "Dim" }
        return lines
      end
      for _, l in ipairs(#doc > 0 and doc or { "(no comment above it)" }) do lines[#lines + 1] = l end
      lines[#lines + 1] = ""
      lines[#lines + 1] = { text = where .. ":" .. line, style = "Dim" }
      return lines
    end,
  }

  -- Presets ---------------------------------------------------------------------------

  -- The presets of the device under the cursor, as `:preset` opens them.
  S.presets = function()
    daw.fx.pick()
    return nil
  end
end

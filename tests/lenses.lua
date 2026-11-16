-- Language servers over things other than notes: a server for the mix
-- (tests/fixtures/mix_lint.py, LSP's own shapes), a one-shot check of
-- renders (tests/fixtures/peak_check.py), a Lua server in this process on
-- an address kind and a subject an extension adds, and diagnostics drawn
-- where they belong in every view of the terminal. Loaded by
-- tests/suite.lua with its helpers.
local T = ...
local eq, fresh = T.eq, T.fresh
local api = daw.api
local A = daw.address

local function test(name, fn)
  T.test(name, function()
    local result = { xpcall(fn, debug.traceback) }
    daw.lsp.stop()
    daw.diagnostic.reset()
    daw.annotation.reset()
    while daw.ui.float do daw.ui.close() end
    daw.ui.views.pianoroll.clip_id = nil
    for _, v in ipairs({ "pianoroll", "mixer", "devices" }) do daw.ui.hide(v) end
    daw.ui.focus("arrange")
    if not result[1] then error(result[2], 0) end
    return result[2]
  end)
end

local function python()
  local found = io.popen("command -v python3 2>/dev/null"):read("*l")
  return found and found ~= "" and found or nil
end

local function until_(fn, what, ms)
  local deadline = api.now() + (ms or 20000)
  while not fn() do
    if api.now() > deadline then error("waited in vain for " .. what, 2) end
    daw.wait(10)
  end
end

local function screen(w, h) return table.concat(api.ui_snapshot(w or 140, h or 50), "\n") end

local function has(text, part, what)
  if not text:find(part, 1, true) then error(string.format("%s: %q is not in\n%s", what, part, text), 2) end
end

local function start()
  fresh()
  daw.lsp.stop()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  daw.ui.focus("arrange")
end

test("lenses: a server for the mix marks a hot fader in every view, says what it is, and fixes it", function()
  if not python() then return "no python3" end
  start()
  local bass = daw.add_track({ name = "Bass", volume = 3 })
  local pad = daw.add_track({ name = "Pad", volume = -6 })
  daw.flush()
  daw.lsp.config("mix", { cmd = { python(), "tests/fixtures/mix_lint.py" } })
  daw.lsp.enable("mix")
  until_(function() return #daw.diagnostic.get(A.track(bass.id)) == 1 end, "the hot fader")
  local d = daw.diagnostic.get(A.track(bass.id))[1]
  eq(daw.diagnostic.kind(d), "track", "about a track")
  eq(d.message, "Bass's fader is at +3.0 dB: it may clip", "what it says")
  eq(#daw.diagnostic.get(A.track(pad.id)), 0, "a quiet track is left alone")
  eq(daw.lsp.clients()[1].subjects[1], "mix", "attached to the mix, as it asked")
  eq(daw.lsp.clients()[1].documents[1], "daw://project#mix", "holding the mix")

  -- The terminal: the header, the status line, the mixer's strip and its label.
  local text = screen()
  has(text, "1!Bass", "the header of the hot track is marked")
  has(text, "W1", "the status line counts it")
  daw.ui.show("mixer")
  text = screen()
  has(text, "+3.0 dB", "the mixer shows the server's label on the strip")

  -- In the mixer, ]d goes to the strip.
  daw.ui.focus("mixer")
  daw.cursor.set_track(pad.id)
  daw.keymap.feed("]d")
  eq(daw.cursor.track_id(), bass.id, "]d goes to the hot track")

  -- In the arrange view, gK says what is known about the track under the cursor.
  daw.ui.focus("arrange")
  daw.keymap.feed("gK")
  until_(function() return daw.ui.float and daw.ui.float.name == "pager" end, "the hover float")
  text = screen()
  has(text, "it may clip", "the diagnostic, in the float")
  has(text, "Bass: fader +3.0 dB, pan +0.00", "and the server's hover")
  daw.ui.close()

  -- ,ca offers the diagnostic's fix and the server's own action; each is one undo step.
  api.undo_checkpoint()
  daw.keymap.feed(",ca")
  until_(function() return daw.pick.state() end, "the actions, once the server has answered")
  local matches = daw.pick.state().matches
  eq(#matches, 2, "a fix and an action")
  has(matches[1], "Bring Bass to 0 dB", "the fix")
  has(matches[2], "Lower Bass by 6 dB", "the action")
  daw.keymap.feed("<CR>")
  api.undo_checkpoint()
  eq(api.track_get(bass.id).volume, 0, "fixed")
  until_(function() return #daw.diagnostic.get(A.track(bass.id)) == 0 end, "the warning to go once the server is told")
  daw.undo()
  eq(api.track_get(bass.id).volume, 3, "one undo takes it back")
  until_(function() return #daw.diagnostic.get(A.track(bass.id)) == 1 end, "the warning back")
  daw.cmd("diagnostics")
  until_(function() return daw.pick.state() end, "the list")
  eq(daw.pick.state().matches[1], "── Tracks", "listed under what they are about")
end)

test("lenses: a one-shot server checks each render, and says when it fails", function()
  if not python() then return "no python3" end
  start()
  local t = daw.add_track({ name = "Tone" })
  t:add_device("synth")
  t:add_clip({ start = 0, length = 2, notes = { { pitch = 69, start = 0, length = 2, velocity = 120 } } })
  daw.lsp.config("peaks", { kind = "oneshot", cmd = { python(), "tests/fixtures/peak_check.py", "--over", "{over}", "{input}" },
    attach = { subjects = { "render" } }, settings = { over = -40 }, timeout_ms = 20000 })
  daw.lsp.enable("peaks")
  eq(daw.lsp.clients()[1].status, "ready", "a one-shot server is ready, with nothing running")
  local path = T.scratch .. "/lenses.wav"
  daw.render(path, { tail = 0 })
  until_(function() return #daw.diagnostic.get(A.render(path)) == 1 end, "the check of the render")
  local d = daw.diagnostic.get(A.render(path))[1]
  eq(daw.diagnostic.kind(d), "render", "about the render")
  has(d.message, "lenses.wav peaks at", "what the command printed")
  eq(d.location.selector.seconds[1], 0.5, "at the time it gave")
  eq(#daw.diagnostic.get(A.render(path), { namespace = "peaks" }), 1, "a finding of severity off is left out")
  has(daw.diagnostic.where(d), "lenses.wav", "named by its file")
  eq(daw.lsp.clients()[1].status, "ready", "ready again")
  -- A command that prints what is not JSON fails, and says so.
  daw.lsp.config("peaks", { cmd = { python(), "tests/fixtures/peak_check.py", "--garbage", "{input}" } })
  daw.render(path, { tail = 0 })
  until_(function() return daw.lsp.clients()[1].status == "failed" end, "the failure")
  has(daw.lsp.clients()[1].error, "not JSON", "why")
  local info = {}
  for _, l in ipairs(daw.lsp.info_lines()) do info[#info + 1] = type(l) == "table" and l.text or l end
  has(table.concat(info, "\n"), "one-shot command", ":lsp info says how it runs")
end)

test("lenses: an extension's addresses and subject, and a Lua server in this process that speaks of them", function()
  start()
  local words = { "la", "lu", "lo" }
  A.scheme("lyric", {
    resolve = function(_, p)
      local i = tonumber(p.segments[2])
      if not i then return { words = words } end
      return words[i] and { text = words[i] } or nil
    end,
    edit = function(change, p) words[tonumber(p.segments[2])] = change.set.text end,
  })
  daw.lsp.subject("lyrics", {
    targets = function() return { "daw://lyric" } end,
    build = function() return { words = words } end,
    depends = { "daw://lyric/**" },
  })
  local seen
  local server = {
    initialize = function() return { capabilities = { hoverProvider = true, daw = { subjects = { "lyrics" } } } } end,
    ["textDocument/didOpen"] = function(params, ctx)
      seen = params.textDocument
      local list = {}
      for i, w in ipairs(params.textDocument.data.words) do
        if w == "lu" then
          list[#list + 1] = { severity = 3, message = "say it longer", code = "vowel",
            data = { location = { uri = "daw://lyric/" .. i }, fixes = { { title = "Make it loo", edit = { { uri = "daw://lyric/" .. i, set = { text = "loo" } } } } } } }
        end
      end
      ctx.notify("textDocument/publishDiagnostics", { uri = params.textDocument.uri, diagnostics = list })
    end,
    ["textDocument/hover"] = function(params) return { contents = "a word: " .. params.daw.location.uri } end,
    -- It asks for an edit of its own.
    ["workspace/executeCommand"] = function(params, ctx)
      return ctx.request("workspace/applyEdit", { edit = { daw = { { uri = "daw://lyric/3", set = { text = params.arguments[1] } } } } })
    end,
  }
  daw.lsp.config("lyrics", { server = server })
  daw.lsp.enable("lyrics")
  eq(seen.languageId, "daw-lyrics", "sent the subject, as a table")
  eq(seen.uri, "daw://lyric#lyrics", "named by its address and subject")
  local d = daw.diagnostic.get("daw://lyric/2")[1]
  eq(d and d.message, "say it longer", "about a word")
  eq(daw.diagnostic.kind(d), "lyric", "of the extension's kind")
  eq(daw.diagnostic.apply(d), true, "its fix")
  eq(words[2], "loo", "made by the extension")
  local hover
  daw.lsp.hover_at({ uri = "daw://lyric/1" }, function(s) hover = s end)
  eq(hover[1].lines[1], "a word: daw://lyric/1", "asked about a word")
  local answer
  daw.lsp.request("lyrics", "workspace/executeCommand", { command = "set", arguments = { "li" } }, function(_, r) answer = r end)
  eq(answer.applied, true, "a server's edit is made")
  eq(words[3], "li", "as it asked")
  local info = {}
  for _, l in ipairs(daw.lsp.info_lines()) do info[#info + 1] = type(l) == "table" and l.text or l end
  has(table.concat(info, "\n"), "in-process Lua", ":lsp info says how it runs")
  A.schemes.lyric = nil
  daw.lsp.subjects.lyrics = nil
end)

test("lenses: diagnostics on devices, parameters and stretches of time are drawn where they belong", function()
  start()
  local t = daw.add_track({ name = "Keys" })
  local synth = t:add_device("synth")
  daw.flush()
  daw.diagnostic.set("lint", "lint", {
    { location = { uri = A.param(synth.id, "cutoff") }, severity = "warning", message = "cutoff is very low",
      fixes = { { title = "Open the cutoff", edit = { { uri = A.param(synth.id, "cutoff"), set = { value = 4000 } } } } } },
    { location = { uri = A.device(synth.id) }, severity = "info", message = "no preset" },
    { location = { uri = A.project(), selector = { time = { 8, 12 } } }, severity = "error", message = "too busy here" },
  })
  daw.cursor.set_track(t.id)
  daw.ui.show("devices")
  local text = screen()
  has(text, "no preset", "the device says what is said of it")
  -- The ruler marks the stretch, on the left edge of its first cell.
  local ruler
  for _, line in ipairs(api.ui_snapshot(140, 50)) do
    if line:find("cur", 1, true) then ruler = line break end
  end
  has(ruler or "", daw.draw.g.mark, "the ruler marks the stretch of time")
  -- ]d in the device panel goes to the parameter.
  daw.ui.focus("devices")
  daw.keymap.feed("]d")
  local row = daw.ui.views.devices:rows()[daw.ui.views.devices.row]
  eq(row.param and row.param.key, "cutoff", "]d goes to the parameter")
  api.undo_checkpoint()
  daw.keymap.feed(",ca")
  has(daw.pick.state().matches[1], "Open the cutoff", "its fix is offered there")
  daw.keymap.feed("<CR>")
  eq(api.device_get(synth.id).params.cutoff, 4000, "and made")
  -- In the arrange view, ]d goes to the stretch.
  daw.ui.focus("arrange")
  daw.cursor.set_beat(2)
  local found
  for _ = 1, 3 do
    daw.keymap.feed("]d")
    if daw.cursor.beat == 8 then found = true break end
  end
  eq(found, true, "the cursor goes to where the stretch starts")
end)

-- Tests of help (daw/help.lua and daw/markdown.lua): the Markdown made into
-- text, tags, `:help` and its completion, following links and coming back,
-- `K`, `:helpgrep`, pages of extensions that are not loaded, and help in a
-- window of the graphical frontend. Loaded by tests/suite.lua with its helpers.
local T = ...
local test, eq, fresh = T.test, T.eq, T.fresh
local api = daw.api
local L = daw.layout
local H = daw.help
local md = daw.markdown

local initial = L.capture()

local function clean()
  daw.keymap.feed("<Esc><Esc>")
  while daw.ui.float do daw.ui.close() end
  for _, buf in ipairs(L.buffers_list()) do
    if buf.type == "textbuf" then L.buf_delete(buf) end
  end
  L.restore(initial)
  daw.ui.focus("arrange")
end

local function start()
  fresh()
  clean()
  -- The help windows a test opened go with it, whatever happens.
  T.after(clean)
end

--- The help window the keyboard is in: its buffer's name, the line under
--- its cursor and the cursor.
local function here()
  local win, buf, t, s = daw.textbuf.here()
  if not win then return nil end
  return buf.name, t:line(s.row), s
end

--- Put the cursor on the first line that holds `text`, on its first character.
local function cursor_on(text)
  local win, _, t, s = daw.textbuf.here()
  for row = 1, t:count() do
    local at = t:line(row):find(text, 1, true)
    if at then
      s.row, s.col = row, md.width(t:line(row):sub(1, at - 1))
      return row
    end
  end
  error("no line holds " .. text, 2)
end

local function message() return daw.ui.message and daw.ui.message.text or "" end

-- Markdown --------------------------------------------------------------------------

test("Markdown is made into text: headings with their tag, bullets, aligned tables, code apart, links", function()
  local doc = md.render(md.parse(table.concat({
    "# Title",
    "",
    "## A section",
    "",
    "Some **bold** and *italic* words with `gU` and a [link](other.md#there).",
    "",
    "- one item that is long enough to wrap onto the next line of the page, so that the hanging indent shows",
    "  - a nested item",
    "1. first",
    "",
    "| Key | What |",
    "| --- | --- |",
    "| `dd` | delete a track |",
    "| `yy` | yank it |",
    "",
    "```lua",
    "daw.opt.keys = \"classic\"",
    "```",
  }, "\n")), { width = 60, heading_tag = function(b) return b.level == 1 and "title" or "a-section" end })
  local text = {}
  for i, line in ipairs(doc.lines) do text[i] = line.text end
  local shown = table.concat(text, "\n")
  eq(text[1]:match("^Title %s+%*title%*$") ~= nil, true, "the title with its tag at the right: " .. text[1])
  eq(md.width(text[1]), 60, "the tag ends at the page's edge")
  eq(text[3], string.rep("─", 60), "a rule above a section")
  eq(shown:find("Some bold and italic words with gU and a link.", 1, true) ~= nil, true, "marks taken out: " .. shown)
  eq(shown:find("  • one item that is long enough", 1, true) ~= nil, true, "a bullet")
  eq(shown:find("\n    so that the hanging indent shows", 1, true) ~= nil or shown:find("\n    [^ ]", 1) ~= nil, true, "the item goes on under its text")
  eq(shown:find("      • a nested item", 1, true) ~= nil, true, "a nested item deeper")
  eq(shown:find("\n 1. first", 1, true) ~= nil, true, "a number")
  eq(shown:find("Key  What\n───  ──────────────\ndd   delete a track\nyy   yank it", 1, true) ~= nil, true, "the table's columns aligned: " .. shown)
  eq(shown:find("\n    daw.opt.keys = \"classic\"", 1, true) ~= nil, true, "code indented")
  -- What each piece is drawn as, and the link's target.
  local para
  for _, line in ipairs(doc.lines) do
    if line.text:find("^Some") then para = line end
  end
  local styles = {}
  for _, span in ipairs(para.spans) do styles[#styles + 1] = span[3] end
  eq(table.concat(styles, " "), "HelpBold HelpItalic HelpCode HelpLink", "bold, italic, code, link")
  eq(para.links[1][3], "other.md#there", "the link's target")
  eq(para.codes[1][3], "gU", "the code, for tags")
end)

test("a table too wide for the page wraps its widest column", function()
  local long = string.rep("word ", 30)
  local doc = md.render(md.parse("| A | B |\n| --- | --- |\n| `x` | " .. long .. " |\n| `y` | short |"), { width = 40 })
  for _, line in ipairs(doc.lines) do eq(md.width(line.text) <= 40, true, "within the page: " .. line.text) end
  eq(doc.lines[3].text:match("^x  word") ~= nil, true, "the first column keeps its width")
  eq(doc.lines[4].text:match("^   word") ~= nil, true, "the cell goes on under itself")
end)

-- Tags -------------------------------------------------------------------------------

test("tags are found for keys, commands, options, Lua modules, sections and pages", function()
  start()
  local function where(topic)
    local tag = H.lookup(topic)
    return tag and tag.source.name .. " " .. tag.name or "none"
  end
  eq(where("gU"), "terminal.md gU", "a key")
  eq(where(":s"), "terminal.md :s", "a command")
  eq(where("'timebind'"), "terminal.md 'timebind'", "an option")
  eq(where("daw.qf"), "scripting.md daw.qf", "a Lua module")
  eq(where("key-rule"), "terminal.md key-rule", "a section named in the page")
  eq(where("quickfix-list"), "terminal.md quickfix-list", "a heading")
  eq(where("terminal"), "terminal.md terminal", "a page")
  eq(where("course-5"), "course/05-grammar.md course-5", "a lesson")
  eq(where("notation"), "notation/README.md notation", "an extension")
  eq(where("notation-keys"), "notation/README.md notation-keys", "an extension's heading")
  eq(where("notation-popovers"), "notation/README.md notation-popovers", "another")
  eq(where("ic"), "terminal.md ic", "a text object")
  eq(where("<C-w>o"), where("Ctrl-w o"), "a key written either way")
  -- Each lands on the line that names it.
  local tag = H.lookup("gU")
  eq(tag.source.doc.lines[tag.row].text:find("gU", 1, true) ~= nil, true, "the tag's line names it")
end)

test("a topic finds the tag itself first, then those that start with it, then those that hold its letters", function()
  start()
  local found = H.find("key-r", 3)
  eq(found[1].name, "key-rule", "the start of a tag")
  found = H.find("qflst", 5)
  eq(found[1] ~= nil and found[1].name:find("q") ~= nil, true, "letters in order")
  eq(H.find("gU", 1)[1].name, "gU", "the tag itself")
  local completion = daw.commands.complete("help key-r")
  eq(completion[1] and completion[1].text, "help key-rule", "Tab completes the tag")
  completion = daw.commands.complete("help quickfx")
  local any = false
  for _, c in ipairs(completion) do any = any or c.label == "quickfix-list" end
  eq(any, true, "a fuzzy match is offered too")
end)

-- The help window -------------------------------------------------------------------

test(":help opens the contents in a window split off, which cannot be changed", function()
  start()
  local before = #L.windows()
  daw.cmd("help")
  local name, line = here()
  eq(name, "help://index", "the contents")
  eq(#L.windows(), before + 1, "in a window of its own")
  eq(line:find("paw help", 1, true) ~= nil, true, "at the top")
  local count = daw.textbuf.buf().state.text:count()
  daw.keymap.feed("dd")
  daw.keymap.feed("x")
  eq(daw.textbuf.buf().state.text:count(), count, "dd removed nothing")
  eq(message():find("cannot be changed", 1, true) ~= nil, true, "and says why: " .. message())
  daw.keymap.feed("i")
  eq(daw.keymap.mode, "n", "no insert mode")
  -- Text in it can be chosen and yanked as any text.
  daw.keymap.feed("ggVy")
  eq(daw.keymap.getreg('"').kind, "lines", "yanked")
  -- A second :help reuses the window.
  daw.cmd("help", { "gU" })
  eq(#L.windows(), before + 1, "the same window")
  local _, at = here()
  eq(at:find("gU", 1, true) ~= nil, true, "on the key: " .. at)
end)

test(":help with a topic puts the cursor on its line, and says when there is none", function()
  start()
  daw.cmd("help", { "key-rule" })
  local name, line = here()
  eq(name, "help://terminal.md", "the page")
  eq(line:find("Every view keeps to one rule", 1, true) ~= nil, true, "the paragraph: " .. line)
  daw.cmd("help", { "zzzzqqqqxxxx" })
  eq(message():find("no help for zzzzqqqqxxxx", 1, true) ~= nil, true, message())
end)

test("Ctrl-] follows a link, Ctrl-t and Ctrl-o come back", function()
  start()
  daw.cmd("help")
  local row = cursor_on("The terminal interface")
  daw.keymap.feed("<C-]>")
  local name = here()
  eq(name, "help://terminal.md", "followed")
  daw.keymap.feed("<C-t>")
  local back, _, s = here()
  eq(back, "help://index", "Ctrl-t comes back")
  eq(s.row, row, "to the line")
  daw.keymap.feed("<C-]>")
  eq((here()), "help://terminal.md", "followed again")
  daw.keymap.feed("<C-o>")
  eq((here()), "help://index", "Ctrl-o comes back too")
  -- On code, Ctrl-] goes to its tag; Enter does what Ctrl-] does.
  daw.cmd("help", { "Ctrl-w o" })
  cursor_on(":only")
  daw.keymap.feed("<CR>")
  local _, line = here()
  eq(line:find(":only", 1, true) ~= nil, true, "Enter followed the code: " .. line)
end)

test("K looks up the word under the cursor", function()
  start()
  daw.cmd("help", { "terminal" })
  cursor_on("quickfix")
  daw.keymap.feed("K")
  local name, line = here()
  eq(name ~= nil, true, "a page")
  eq(line:lower():find("quickfix", 1, true) ~= nil, true, "where quickfix is: " .. line)
end)

test(":helpgrep puts every line that holds the words in the quickfix list and goes to the first", function()
  start()
  daw.cmd("helpgrep", { "timebind" })
  local list = daw.qf.current()
  eq(list.title, "helpgrep timebind", "the list")
  eq(#list.entries > 1, true, "with entries")
  for _, e in ipairs(list.entries) do eq(e.text:lower():find("timebind", 1, true) ~= nil, true, "each holds it") end
  eq(daw.qf.where(list.entries[1]):match("^.+:%d+$") ~= nil, true, "named by page and line: " .. daw.qf.where(list.entries[1]))
  local _, line = here()
  eq(line and line:lower():find("timebind", 1, true) ~= nil, true, "the cursor on the first")
  daw.cmd("cnext")
  local _, second = here()
  eq(second:lower():find("timebind", 1, true) ~= nil, true, "]q goes on to the next")
end)

test("the page of an extension that is not loaded says how to load it", function()
  start()
  local dir = T.scratch .. "/helpdemo"
  os.execute("mkdir -p '" .. dir .. "'")
  T.write_file(dir .. "/README.md", "# helpdemo\n\nAn extension for the help tests.\n\n## Popovers\n\nThey pop.\n")
  H.add(dir .. "/README.md", { tag = "helpdemo", ext = "helpdemo", dir = dir })
  daw.cmd("help", { "helpdemo-popovers" })
  local name = here()
  eq(name, "help://helpdemo.md", "its page")
  eq(message():find("helpdemo is not loaded", 1, true) ~= nil, true, "said: " .. message())
  local text = table.concat(daw.textbuf.buf().state.text.lines[3] and { daw.textbuf.buf().state.text.lines[3].text } or {}, "")
  local all = {}
  for _, l in ipairs(daw.textbuf.buf().state.text.lines) do all[#all + 1] = l.text end
  all = table.concat(all, " ")
  eq(all:find("This extension is not loaded", 1, true) ~= nil, true, "the page says so: " .. text)
  eq(all:find("daw.ext.load(\"" .. H.normalize(dir) .. "\")", 1, true) ~= nil, true, "and how to load it")
  table.remove(H.extra)
  H.dirty = true
  -- A bundled one is loaded by its name.
  local name
  for _, ext in ipairs(daw.ext.bundled()) do
    if not daw.ext.loaded[ext] and io.open("extensions/" .. ext .. "/README.md") then name = name or ext end
  end
  if name then
    daw.cmd("help", { name })
    local text = {}
    for _, l in ipairs(daw.textbuf.buf().state.text.lines) do text[#text + 1] = l.text end
    eq(table.concat(text, "\n"):find(":ext.load " .. name, 1, true) ~= nil, true, name .. "'s page names :ext.load")
  end
end)

test("Ctrl-] in the keys picker opens the help of the key chosen", function()
  start()
  daw.pick("keys", { query = "Ctrl-w o" })
  daw.keymap.feed("<C-]>")
  local name, line = here()
  eq(name, "help://terminal.md", "the manual: " .. message())
  eq(line:find("Ctrl-w o", 1, true) ~= nil, true, "at the key: " .. tostring(line))
  -- And in the commands picker, the command's.
  daw.pick("commands", { query = "helpgrep" })
  daw.keymap.feed("<C-]>")
  local _, at = here()
  eq(at:find(":helpgrep", 1, true) ~= nil, true, "at the command: " .. tostring(at))
end)

test("the key line names the view's topic of help, and every such topic is a tag", function()
  start()
  eq(H.topic_of("arrange"), "terminal", "the arrange view's")
  for view, topic in pairs(H.view_topics) do
    eq(H.index().tags[topic] ~= nil, true, view .. "'s topic " .. topic .. " is a tag")
  end
  daw.ui.message = nil
  local W = 200
  local bottom = api.ui_snapshot(W, 40)[40]
  eq(bottom:find(":help terminal", 1, true) ~= nil, true, "on the bottom line: " .. bottom)
end)

test("in the graphical frontend help opens as a docked pane, and pops out on request", function()
  start()
  local listeners = daw.remote.listeners
  daw.remote.listeners = function() return { { client = 9, watching = true } } end
  local ok, err = pcall(daw.cmd, "help", { "gU" })
  daw.remote.listeners = listeners
  assert(ok, err)
  eq(daw.canvas.open_views.textbuf, nil, "no window of its own")
  eq(daw.ui.focused, "textbuf", "the pane has the keyboard")
  local name, line = here()
  eq(name:match("^help://") ~= nil, true, "a help pane in the layout")
  eq(line:find("gU", 1, true) ~= nil, true, "at the key")
  daw.cmd("textbuf.window")
  eq(daw.canvas.open_views.textbuf ~= nil, true, "popped out to a window of its own")
  daw.canvas.close("textbuf")
end)

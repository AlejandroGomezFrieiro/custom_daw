-- The course as Markdown, made from the same lesson tables the tutor runs,
-- so the text in `docs/course/` cannot say something the tutor does not.
--
--   daw --clean --no-plugins -l extensions/tutor/make-docs.lua    writes docs/course/
--
-- The tests compare these with the files on disk.
local M = {}

local GENERATED = "<!-- Made by extensions/tutor/make-docs.lua from the tutor's lessons. Do not edit: change the lesson and run it again. -->"

--- A file name for a lesson: "05-grammar.md".
function M.file(n, lesson)
  return string.format("%02d-%s.md", n, lesson.id)
end

local function paragraphs(text)
  -- Lines within a paragraph are joined, so that Markdown flows them.
  local out = {}
  for para in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
    para = para:gsub("%s*\n%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if para ~= "" then out[#out + 1] = para end
  end
  return table.concat(out, "\n\n")
end

function M.lesson(n, lesson, lessons)
  local out = { GENERATED, "", string.format("# Lesson %d: %s", n, lesson.title), "" }
  local function add(line) out[#out + 1] = line end
  add(string.format("*About ten minutes. In the DAW, with the tutor loaded: `:tutor %d`.*", n))
  add("")
  if lesson.intro then add(paragraphs(lesson.intro)) add("") end
  if lesson.idea then add("## The idea") add("") add(paragraphs(lesson.idea)) add("") end
  if lesson.vim then add("## If you know Vim") add("") add(paragraphs(lesson.vim)) add("") end
  add("## Steps")
  add("")
  add("The tutor opens a practice project made for this lesson and checks each step as you do it.")
  add("")
  for i, step in ipairs(lesson.steps) do
    add(string.format("%d. %s", i, step.say))
    if step.hint then add("   - *Hint:* " .. step.hint) end
    if step.unchecked then
      add("   - *The tutor cannot check this step* (" .. step.unchecked:gsub("%.$", "") .. "); `,hn` goes on.")
    elseif step.done then
      add("   - ✓ " .. step.done)
    end
  end
  add("")
  if lesson.outro then add("## What you did") add("") add(lesson.outro) add("") end
  local nav = {}
  if lessons[n - 1] then nav[#nav + 1] = string.format("Previous: [%s](%s)", lessons[n - 1].title, M.file(n - 1, lessons[n - 1])) end
  nav[#nav + 1] = "[All lessons](README.md)"
  if lessons[n + 1] then nav[#nav + 1] = string.format("Next: [%s](%s)", lessons[n + 1].title, M.file(n + 1, lessons[n + 1])) end
  add(table.concat(nav, " · "))
  return table.concat(out, "\n") .. "\n"
end

function M.index(lessons)
  local out = { GENERATED, "", "# The course", "" }
  local function add(line) out[#out + 1] = line end
  add(paragraphs([[
A course for the first days with the DAW, by doing. Each lesson takes about ten
minutes, opens a small practice project of its own, and ends with something you
made or changed and can hear. The same lessons run inside the DAW, where the
tutor says what to do next and notices when you have done it:]]))
  add("")
  add("```lua")
  add('daw.ext.load("extensions/tutor")   -- in ~/.config/daw/init.lua, or link the directory into ~/.config/daw/extensions')
  add("```")
  add("")
  add(paragraphs([[
then `:tutor` in the DAW. These pages are made from the tutor's own lessons, so
the two say the same. [keys.md](keys.md) is a page of keys to keep beside the
keyboard.]]))
  add("")
  add("| | Lesson | What it teaches |")
  add("| --- | --- | --- |")
  for n, lesson in ipairs(lessons) do
    local first = (lesson.outro or ""):gsub("|", "\\|")
    add(string.format("| %d | [%s](%s) | %s |", n, lesson.title, M.file(n, lesson), first))
  end
  add("")
  add(paragraphs([[
Lessons 1 to 4 are the ground: the screen, moving, making tracks and notes. 5
to 8 are the grammar that the rest of the DAW is made of. 9 to 13 are the
studio: devices, mixing, looping, recording, saving and rendering. 14 to 16 are
about finding your own way: finding any key, making the DAW yours, and the
extensions.]]))
  return table.concat(out, "\n") .. "\n"
end

--- Every file of the course: { [name] = text }.
function M.files(lessons)
  local files = { ["README.md"] = M.index(lessons) }
  for n, lesson in ipairs(lessons) do files[M.file(n, lesson)] = M.lesson(n, lesson, lessons) end
  return files
end

return M

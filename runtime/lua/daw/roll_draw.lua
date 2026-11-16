-- `daw.roll_draw`: the piano roll's insert mode, drawing notes with the
-- cursor. `i` starts a note at the cursor, nothing long yet; `l` and `h`
-- make it a grid step longer and shorter, `j` and `k` move its pitch, and
-- the cursor stays at its end, so what shows is what will be written.
-- `<CR>` keeps it and starts the next where it ends, `<Space>` after a
-- step's rest, `o` at the same place and as long, for a chord. `<Esc>`
-- writes them all and leaves.
--
-- Nothing reaches the project until insert mode ends: then every note drawn
-- is written at once, which makes the whole of it one undo step and lets
-- `.` draw the same shape again at the cursor, as Vim repeats an insert.
--
-- The other way in, `daw.opt.roll_insert = "keys"` or `I`, turns the
-- keyboard into a piano instead (`view:enter`); this module then stays out
-- of the way.
local api = daw.api
local util = daw.util
local music = daw.music
local clips = daw.roll_clips
local M = {}

-- How insert mode in the piano roll enters notes: "draw" with the cursor,
-- or "keys", the keyboard as a piano.
daw.option.define("roll_insert", "draw")

-- Beats here are the project's, so that what is drawn stays put when the
-- active clip changes: `notes` kept so far, as `{ pitch, start, length,
-- velocity }`; the note being drawn, from `start` at `pitch`, `length` long;
-- `count`, digits typed for the next key.
local session
local keys_once   -- `I` asked for the piano keys this time
daw.seats.keep("roll_draw", function() return session, keys_once end,
  function(s, k) session, keys_once = s, k end,
  function() return nil, nil end)

local function roll() return daw.ui.views.pianoroll end

local function changed()
  if daw.frontend then daw.frontend.refresh() else api.ui_redraw() end
end

--- Where the active clip starts in the project, or nil with none open.
local function origin()
  local clip = roll():clip()
  return clip and clip.start
end

--- Whether a note is being drawn: insert mode in the piano roll, the
--- drawing kind.
function M.active()
  return session ~= nil and daw.keymap.mode == "i"
end

--- Bring the note being drawn to the cursor, if something else moved it
--- (a click, a suggestion accepted): it starts afresh there.
local function sync()
  local at = origin()
  if not session or not at then return end
  local r = roll()
  local beat = r.beat + at
  if r.pitch ~= session.pitch or math.abs(beat - (session.start + session.length)) > 1e-9 then
    session.pitch, session.start, session.length = r.pitch, beat, 0
  end
end

--- The cursor goes to the end of the note being drawn. It may go past the
--- end of the clip, which grows when the note is written.
local function place()
  local r, at = roll(), origin()
  if not at then return end
  r.pitch = session.pitch
  r.beat = session.start + session.length - at
  changed()
end

--- Start drawing at the cursor, `after` steps on.
function M.start(after)
  local at = origin()
  if not at then return end
  local r = roll()
  session = { notes = {}, pitch = r.pitch, start = r.beat + at + (after or 0) * daw.opt.note_grid, length = 0 }
  place()
end

--- The count typed so far, taken: 1 when there is none.
local function take_count()
  local n = session.count or 1
  session.count = nil
  return n
end

--- A digit of the count for the next key.
function M.digit(d)
  if not session then return end
  sync()
  if d == 0 and not session.count then return end
  session.count = (session.count or 0) * 10 + d
  api.ui_redraw()
end

--- Make the note `steps` grid steps longer, or shorter with a negative count.
function M.grow(steps)
  if not session then return end
  sync()
  local n = take_count()
  session.length = math.max(0, session.length + steps * n * daw.opt.note_grid)
  place()
end

--- Move the note by `semitones` (times the count), and hear its new pitch.
--- `step(pitch, n)`, if given, says where `n` such moves go instead: by
--- steps of a scale, say.
function M.pitch(semitones, step)
  if not session then return end
  sync()
  local n = take_count()
  local to = step and step(session.pitch, n) or session.pitch + semitones * n
  session.pitch = util.clamp(to, 0, 127)
  place()
  local at = origin()
  local part = at and clips.target(session.start - at)
  if part then part.clip:track():play_note(session.pitch, daw.opt.velocity, 180) end
end

--- Keep the note being drawn among those to write, replacing one drawn
--- before at the same pitch and start. One of no length is not kept.
local function put()
  if session.length <= 1e-9 then return end
  for i = #session.notes, 1, -1 do
    local n = session.notes[i]
    if n.pitch == session.pitch and math.abs(n.start - session.start) < 1e-9 then table.remove(session.notes, i) end
  end
  session.notes[#session.notes + 1] = {
    pitch = session.pitch, start = session.start, length = session.length, velocity = daw.opt.velocity,
  }
end

--- Keep the note and go on to the next: "legato" where it ends, "rest" a
--- step (or the count's steps) after that, "chord" at the same start and as
--- long.
function M.next(how)
  if not session then return end
  sync()
  local n = take_count()
  put()
  if how == "chord" then return place() end
  session.start = session.start + session.length + (how == "rest" and n * daw.opt.note_grid or 0)
  session.length = 0
  place()
end

--- Take back the last note kept: it is the one being drawn again.
function M.back()
  if not session then return end
  sync()
  session.count = nil
  local last = table.remove(session.notes)
  if not last then return end
  session.pitch, session.start, session.length = last.pitch, last.start, last.length
  place()
end

--- The notes to write in the clips they go into: `{ part, notes }` in the
--- part's own beats, by clip id. The note being drawn is among them.
local function by_clip(list)
  local at = origin()
  local parts = clips.parts()
  local out = {}
  for _, n in ipairs(list) do
    local part = clips.target(n.start - at, parts)
    local start = n.start - at - part.offset
    if part and start > -1e-9 then
      local entry = out[part.id] or { part = part, notes = {} }
      out[part.id] = entry
      entry.notes[#entry.notes + 1] = {
        pitch = n.pitch, start = math.max(0, start), length = n.length, velocity = n.velocity, pending = n.pending,
      }
    end
  end
  return out
end

--- Every note drawn, the one being drawn last, if it has a length.
local function drawn()
  local list = {}
  local drawing = session.length > 1e-9
  for _, n in ipairs(session.notes) do
    -- The one being drawn takes the place of one kept at its pitch and start.
    if not (drawing and n.pitch == session.pitch and math.abs(n.start - session.start) < 1e-9) then list[#list + 1] = n end
  end
  if drawing then
    list[#list + 1] = { pitch = session.pitch, start = session.start, length = session.length, velocity = daw.opt.velocity, pending = true }
  end
  return list
end

--- Write what was drawn into the clips, all at once: one undo step. A note
--- of the same pitch that starts where one is drawn is replaced, and a clip
--- grows by whole bars to hold what runs past its end.
local function write()
  if not origin() then return end
  local list = drawn()
  if #list == 0 then return end
  api.undo_label("Draw notes")
  for _, entry in pairs(by_clip(list)) do
    local part, clip = entry.part, entry.part.clip
    local finish, add, remove, seen = 0, {}, {}, {}
    for _, n in ipairs(entry.notes) do
      add[#add + 1] = { pitch = n.pitch, start = n.start, length = n.length, velocity = n.velocity }
      finish = math.max(finish, n.start + n.length)
      local found, places = clip:notes({ from = n.start - 1e-9, to = n.start + 2e-9, low = n.pitch, high = n.pitch })
      for i, old in ipairs(found) do
        if math.abs(old.start - n.start) < 1e-9 and not seen[places[i]] then
          seen[places[i]] = true
          remove[#remove + 1] = places[i]
        end
      end
    end
    if finish > part.length + 1e-9 then
      clip.length = daw.time.bar_ceil(part.start + finish - 1e-9) - part.start
    end
    clip:edit_notes({ remove = remove, add = add })
  end
  daw.ui.poke()
end

--- End the drawing: write it, and forget it.
function M.finish()
  if not session then return end
  sync()
  write()
  session = nil
  changed()
end

--- Insert mode the piano keys way this once, whatever `roll_insert` says.
function M.keys_once()
  keys_once = true
end

-- Entering insert mode in the piano roll starts a note at the cursor, unless
-- the keys are a piano this time; leaving it writes what was drawn.
daw.on("mode.changed", function(e)
  if e.old == "i" then
    keys_once = nil
    return M.finish()
  end
  if e.mode == "i" and daw.ui.focused == "pianoroll" and roll():clip() then
    if keys_once or daw.opt.roll_insert == "keys" then return end
    M.start()
  end
end)

-- What shows ------------------------------------------------------------------

--- A length in grid steps and in beats: "2 steps · 0.5 beats".
local function length_text(length)
  local steps = length / daw.opt.note_grid
  return string.format("%g step%s · %g beat%s", steps, steps == 1 and "" or "s", length, length == 1 and "" or "s")
end

--- The note being drawn, in words: "C4 · 2 steps · 0.5 beats", or nil.
function M.describe()
  if not M.active() then return nil end
  sync()
  return music.name(session.pitch) .. " · " .. length_text(session.length)
end

--- What the piano roll's title says in insert mode.
function M.label()
  if not M.active() then
    local r = roll()
    return string.format("INS C%d  step %g  vel %d", daw.opt.octave, r:step_length(), daw.opt.velocity)
  end
  sync()
  return string.format("DRAW %s%s  %s  vel %d", session.count and session.count .. " " or "", music.name(session.pitch),
    length_text(session.length), daw.opt.velocity)
end

--- What the window says while in insert mode.
function M.status()
  if not M.active() then
    return string.format("entering notes · a is C%d · step %g · Esc to stop", daw.opt.octave, roll():step_length())
  end
  return "drawing " .. M.describe() .. " · l h longer, shorter · Enter next · Esc writes"
end

--- The notes drawn and kept so far, as "60@1+0.5 64@1+0.5" in the roll's
--- beats; and the one being drawn, "67@1.5+0".
function M.text()
  if not session then return "", nil end
  sync()
  local at = origin() or 0
  local out = {}
  for _, n in ipairs(session.notes) do out[#out + 1] = string.format("%d@%g+%g", n.pitch, n.start - at, n.length) end
  return table.concat(out, " "), string.format("%d@%g+%g", session.pitch, session.start - at, session.length)
end

local styles = {}

--- The terminal's look for the note being drawn: the insert mode's colour,
--- faint behind and bright in front, unlike any clip's notes.
local function pending_style()
  local palette = require("daw.theme").palette
  local key = palette.bg .. palette.insert
  if not styles[key] then
    daw.ui.hl("NoteDrawing", { fg = palette.insert, bg = daw.draw.mix(palette.bg, palette.insert, 0.3), bold = true })
    styles[key] = "NoteDrawing"
  end
  return styles[key]
end

-- Above the clips' notes and below a snippet's marks and suggestions: the notes kept, as they
-- will look once written, and the one being drawn in the insert colour.
roll().layer("draw", 35, function(L)
  if not M.active() then return end
  sync()
  local g = daw.draw.g
  local at = L.data.start
  for _, n in ipairs(drawn()) do
    local row = L.row(n.pitch)
    local x0, x1 = L.x(n.start - at), L.x(n.start + n.length - at)
    if row and x1 > 0 and x0 < L.width then
      local w = math.max(1, x1 - x0)
      L.roll:fill(x0, row, w, 1, " ", n.pending and pending_style() or daw.draw.note_style(L.hue, n.velocity))
      L.roll:text(x0, row, g.clip_start)
      if w >= 4 then L.roll:text(x0 + 1, row, music.name(n.pitch):sub(1, w - 1)) end
    end
  end
end, function(clip_id)
  if not M.active() then return {} end
  sync()
  local palette = require("daw.theme").palette
  local entry = by_clip(drawn())[clip_id]
  local out = {}
  -- The one being drawn is fainter than those kept, with the same edge.
  for _, n in ipairs(entry and entry.notes or {}) do
    out[#out + 1] = {
      pitch = n.pitch, start = n.start, length = n.length, fill = palette.insert, alpha = n.pending and 0.25 or 0.55,
      edge = palette.insert, label = music.name(n.pitch),
    }
  end
  return out
end)

return M

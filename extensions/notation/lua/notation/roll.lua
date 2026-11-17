-- What the piano roll shows of a score clip, as a layer of the roll
-- (`daw.ui.views.pianoroll.layer`): that the notes are written in notation
-- and which keys write and which only change the playing; a thin tick
-- where a note with feel is written (and where its written end is, when
-- the length differs); the dynamic's velocity as a line in the velocity
-- lane, so that the note's own is seen against it; notes the score makes
-- up from a mark hatched; and, with the roll and the notation view
-- beside each other and both `timebind`, the note under one's cursor
-- outlined in the other, found by the note's id (`meta.score.n`).
local api = daw.api
local view = require("notation")
local render = require("notation.render")

local M = {}
local EPS = 1e-6
local roll = daw.ui.views.pianoroll

-- What the roll needs to know of each clip's notes, kept until an edit.
local memo = {}

--- The clip's notes against what is written: `{ list, by }`, `list` of
--- `{ n, place, note, plain, generated, late, longer, dvel }` (the note's
--- id, its place among the clip's notes, the note, the note as written, what
--- it is made from if made up, and how far its start, its length and its
--- velocity are from what is written); `by` the same by id. Nil for a
--- clip that is not a score clip.
function M.notes(id)
  local ok, c = pcall(api.clip_get, id)
  if not ok or not view.has_score(c) then return nil end
  local key = tostring(c.meta.score.rev) .. ":" .. api.project_get().edits
  local kept = memo[id]
  if kept and kept.key == key then return kept end
  local plain = {}
  for _, r in ipairs(render.render(view.score_of(c), { feel = false, written = true, unsorted = true })) do
    plain[r.meta.score.n] = r
  end
  kept = { key = key, list = {}, by = {} }
  for place, note in ipairs(api.clip_notes(id)) do
    local n = render.note_id(note)
    local was = n and plain[n]
    if was then
      local entry = {
        n = n, place = place, note = note, plain = was, generated = was.written.grace and "grace" or nil,
        late = note.start - was.start, longer = note.length - was.length,
        dvel = note.velocity - was.velocity,
      }
      kept.list[#kept.list + 1] = entry
      kept.by[n] = entry
    end
  end
  memo[id] = kept
  return kept
end

--- A note's velocity against the dynamic's: "96 = mf 80 +16".
function M.velocity_text(entry)
  local base = entry.plain.velocity
  local name
  for dyn, v in pairs(render.DYNAMICS) do
    if v == base then name = dyn end
  end
  return string.format("%d = %s%+d", entry.note.velocity, name and (name .. " " .. base) or tostring(base), entry.dvel)
end

--- Whether the roll and the notation view are on screen, each with
--- `timebind`, both on this clip.
function M.bound(id)
  local have = {}
  for _, win in ipairs(daw.layout.windows(daw.ui.layout)) do
    if win.opts and win.opts.timebind then have[win.view] = true end
  end
  return have.pianoroll and have.notation and view.clip_id == id and roll.clip_id == id or false
end

--- The id of the note under the cursor of the other window, to outline in
--- the window `of` ("pianoroll" or "notation").
function M.partner(of)
  local clip = view:clip()
  if not (clip and M.bound(clip.id)) then return nil end
  local note
  if of == "pianoroll" then note = view:note() else note = roll:note_at(roll.pitch, roll.beat) end
  return note and render.note_id(note)
end

--- Where, among its clip's notes, the note under the roll's cursor is.
function M.partner_place()
  local id = M.partner("notation")
  local info = id and M.notes(view.clip_id)
  local e = info and info.by[id]
  return e and e.place
end

local function glyphs()
  local ascii = daw.opt.ascii
  return { hatch = ascii and "/" or "╱", tick = ascii and "!" or "▎", line = ascii and "-" or "─",
    open = ascii and "[" or "⟦", close = ascii and "]" or "⟧", one = ascii and "*" or "◆" }
end

-- On the roll's notes: hatching, ticks at the written places, the outline.
local function paint(L)
  local info = M.notes(L.clip.id)
  if not info then return end
  local g = glyphs()
  local outline = M.partner("pianoroll")
  for _, e in ipairs(info.list) do
    local n = e.note
    local row = L.row(n.pitch)
    if row and n.start < L.to and n.start + n.length > L.from then
      local x0, x1 = L.x(n.start), L.x(n.start + n.length)
      local nw = math.max(1, x1 - x0)
      if e.generated then L.roll:text(x0, row, string.rep(g.hatch, nw), daw.draw.note_style(L.hue, n.velocity)) end
      -- Where it is written, when it plays elsewhere.
      if math.abs(e.late) > EPS then
        local x = L.x(e.plain.start)
        -- A nudge of less than a column still marks the note's own.
        if x >= 0 and x < L.width then L.roll:text(x, row, g.tick, "Bright") end
      end
      if math.abs(e.longer) > EPS then
        local x = L.x(e.plain.start + e.plain.length)
        if x >= 0 and x < L.width and x > x0 then L.roll:text(x, row, g.tick, "Bright") end
      end
      if outline == e.n then
        if nw == 1 then
          L.roll:text(x0, row, g.one, "Bright")
        else
          L.roll:text(x0, row, g.open, "Bright")
          L.roll:text(x0 + nw - 1, row, g.close, "Bright")
        end
      end
    end
  end
end

--- What the window is handed: ticks, the veil of generated notes and the
--- outline, as marks of the roll in the clip's beats.
local function marks(id)
  local info = M.notes(id)
  if not info then return {} end
  local out = {}
  local outline = M.partner("pianoroll")
  for _, e in ipairs(info.list) do
    local n = e.note
    if math.abs(e.late) > EPS then
      out[#out + 1] = { pitch = n.pitch, start = e.plain.start, length = 1 / 64, fill = "#ffffff", alpha = 0.95,
        tip = string.format("written here; it plays %.3g beats %s", math.abs(e.late), e.late > 0 and "late" or "early") }
    end
    if math.abs(e.longer) > EPS then
      out[#out + 1] = { pitch = n.pitch, start = e.plain.start + e.plain.length - 1 / 64, length = 1 / 64, fill = "#ffffff", alpha = 0.95,
        tip = "written to end here" }
    end
    if e.generated then
      out[#out + 1] = { pitch = n.pitch, start = n.start, length = n.length, fill = "#ffffff", alpha = 0.3, edge = "#ffffff",
        tip = "made from a written " .. e.generated .. " mark: editing it asks whether to write the mark or only this pass" }
    end
    if outline == e.n then
      out[#out + 1] = { pitch = n.pitch, start = n.start, length = n.length, fill = "#ffffff", alpha = 0, edge = "#ffd34d",
        tip = "the note under the cursor of the notation window" }
    end
  end
  return out
end

-- The velocity lane: a line at the dynamic's level over each note whose
-- velocity is not it, and the note under the cursor said in words.
local function lane(L)
  local info = M.notes(L.clip.id)
  if not info then return end
  local g = glyphs()
  for _, e in ipairs(info.list) do
    local n = e.note
    if n.start < L.to and n.start + n.length > L.from then
      local x0 = L.x(n.start)
      local x1 = math.max(x0 + 2, L.x(n.start + n.length))
      if e.dvel ~= 0 then
        local up = math.min(L.vel - 1, math.floor(e.plain.velocity / 127 * L.vel))
        for x = x0 + 1, x1 - 1 do L.lane:text(x, L.vel - 1 - up, g.line, "Faint") end
      end
      if L.under_part and L.under_part.id == L.clip.id and L.under_place == e.place then
        L.lane:text(x0 + 1, 0, M.velocity_text(e), "Bright")
      end
    end
  end
end

local KEYS = "written: ] [ x i H L A-h A-l   feel: velocity, off-grid drags"

roll.layer("score", 36, paint, marks, {
  lane = lane,
  title = function(c) return view.has_score(c) and "written in notation (:vs notation)" or nil end,
  keys = function(c) return view.has_score(c) and KEYS or nil end,
})

roll:tool("score", function()
  local clip = roll:clip()
  if not (clip and view.has_score(clip:get())) then return nil end
  return { label = "Notation", on = view.clip_id == clip.id, act = "open_notation",
    tip = "written in notation: opens the score of this clip · the roll's pitch, add, delete and grid moves are written; a velocity and an off-grid nudge are feel" }
end)

--- The toolbar chip: the notation view on the roll's clip.
function daw.frontend.act.open_notation(clip)
  view:edit(daw.clip(clip))
end

return M

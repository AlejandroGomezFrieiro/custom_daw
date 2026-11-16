-- Keys and commands of the vocal editor for working on several notes, the
-- curves, the phonemes, note properties and hearing; the first keys are in
-- utau.commands. They mean the same in the terminal and in the window.
local api = daw.api
local util = daw.util
local keymap, edit = daw.keymap, daw.edit
local notes = require("utau.notes")
local shapes = require("utau.shapes")
local audition = require("utau.audition")
local editor = require("utau.editor").editor
local map, command = keymap.set, daw.command

local function emap(lhs, rhs, desc, opts) map(lhs, rhs, util.merge({ view = "utau", desc = desc }, opts)) end

-- Several notes --------------------------------------------------------------------

--- The selected notes (or the one under the cursor) as a register value
--- that keeps their pitches, counted from the first one's start.
function editor:copy()
  local indices, list = self:targets()
  if #indices == 0 then return nil end
  local from, to = math.huge, 0
  for _, i in ipairs(indices) do
    from = math.min(from, list[i].start)
    to = math.max(to, list[i].start + list[i].length)
  end
  local out = {}
  for k, i in ipairs(indices) do out[k] = util.merge(list[i], { start = list[i].start - from }) end
  return { kind = "notes", shape = "char", top = 0, length = to - from, notes = out }
end

emap("<C-c>", function(ctx)
  local value = editor:copy()
  if not value then return daw.notify("nothing to copy: select notes first", "warn") end
  keymap.setreg(value, ctx.register, true)
  daw.notify(#value.notes == 1 and "copied 1 note" or "copied " .. #value.notes .. " notes")
end, "Copy the selected notes")
emap("<C-x>", function(ctx)
  local value = editor:copy()
  if not value then return end
  keymap.setreg(value, ctx.register)
  local indices = editor:targets()
  editor:clear_selection()
  daw.clip(editor.clip_id):edit_notes({ remove = indices })
end, "Cut the selected notes")
--- Paste at the cursor; the pasted notes are selected.
local function paste_here(ctx)
  local clip = editor:clip()
  if not clip then return end
  local value = keymap.getreg(ctx.register)
  if not value or value.kind ~= "notes" then return daw.notify("nothing to paste yet", "warn") end
  edit.roll.paste(daw.clip(clip.id), value, editor.pitch, editor.beat)
  local sel = {}
  for _, n in ipairs(value.notes) do
    local note = util.merge(n, {})
    if value.shape ~= "line" then note.start = editor.beat + n.start end
    if value.shape ~= "char" then note.pitch = n.pitch + editor.pitch - value.top end
    sel[editor.key_of(note)] = true
  end
  editor.sel = sel
end
-- Ctrl+V pastes in the window; in the terminal it selects a block, as it does everywhere.
emap("<C-v>", function(ctx)
  if daw.canvas.open_views.utau then return paste_here(ctx) end
  keymap.visual_start("b")
end, "Paste at the cursor (window), select a block (terminal)")
emap("<C-a>", function()
  local list = notes.list(editor.clip_id)
  local all = {}
  for i in ipairs(list) do all[i] = i end
  editor:select(all)
  daw.notify(#all .. " notes selected")
end, "Select every note")
emap("gA", function()
  local phrase = editor:phrase_at(editor.beat)
  if not phrase then return end
  local indices = {}
  for i = phrase.first, phrase.last do indices[#indices + 1] = i end
  editor:select(indices)
end, "Select the phrase at the cursor")
for _, lhs in ipairs({ "ip", "ap" }) do
  keymap.textobject(lhs, function()
    local clip = editor:clip()
    local list = clip and notes.list(clip.id)
    local phrase = list and editor:phrase_at(editor.beat, list)
    if not phrase then return end
    local a, b = list[phrase.first], list[phrase.last]
    return { view = "utau", kind = "char", r0 = 0, r1 = 127, c0 = a.start, c1 = b.start + b.length - 1e-6 }
  end, { view = "utau", desc = "The phrase at the cursor" })
end
emap("<Space>", function() editor:play_from_cursor() end, "Play from the cursor, or stop")

-- Curves -----------------------------------------------------------------------------

emap("gc", function(ctx) for _ = 1, ctx.count or 1 do editor:next_curve(1) end end, "Show the next curve under the notes")
emap("gC", function(ctx) for _ = 1, ctx.count or 1 do editor:next_curve(-1) end end, "Show the previous curve under the notes")

-- Phonemes ---------------------------------------------------------------------------

emap(")", function(ctx) for _ = 1, ctx.count or 1 do editor:step_phoneme(1) end end, "Next phoneme")
emap("(", function(ctx) for _ = 1, ctx.count or 1 do editor:step_phoneme(-1) end end, "Previous phoneme")
emap("]", function(ctx) editor:shift_phoneme(5 * (ctx.count or 1)) end, "The phoneme starts 5 ticks later")
emap("[", function(ctx) editor:shift_phoneme(-5 * (ctx.count or 1)) end, "The phoneme starts 5 ticks earlier")
emap("gr", function() editor:replace_phoneme() end, "Type the phoneme to sing instead")
emap("gR", function() editor:reset_phoneme() end, "Put the phoneme back as the voicebank has it")

-- Note properties ----------------------------------------------------------------------

local VB_KEYS = {}
for _, f in ipairs(shapes.VB_FIELDS) do VB_KEYS[f.key] = f end

--- Give the selected notes (or the one under the cursor) properties:
--- `tuning=20 vibrato=on depth=40 period=150 po=default vel=120`.
command("utau.note", function(ctx)
  local which = {}
  for _, i in ipairs(editor:targets()) do which[i] = true end
  if not next(which) then return daw.notify("no note under the editor's cursor", "warn") end
  local count = notes.change_props(editor.clip_id, function(p, note)
    for key, value in pairs(ctx.args) do
      if type(key) == "string" then
        local number = tonumber(value)
        if key == "tuning" or key == "tu" then
          p.tu = (number and number ~= 0) and math.floor(number + 0.5) or nil
        elseif key == "vibrato" or key == "vb" then
          local on = value == "on" or value == "1" or value == "true"
          p.vb = on and (shapes.vb(note) or shapes.copy(shapes.DEFAULT_VB)) or nil
        elseif VB_KEYS[key] then
          local vb = p.vb and shapes.copy(p.vb) or shapes.copy(shapes.DEFAULT_VB)
          local f = VB_KEYS[key]
          vb[f.i] = util.clamp(number or 0, f.min, f.max)
          p.vb = vb
        elseif key == "po" or key == "phonemizer" then
          p.po = (value ~= "default" and value ~= "") and value or nil
        elseif key == "transition" and value == "default" then
          p.pp = nil
        elseif number then
          shapes.set_expression(p, key, number)
        end
      end
    end
    return true
  end, which)
  daw.notify(string.format("%d notes changed", count))
end, { desc = "Set properties of the selected notes: `utau.note tuning=20 vibrato=on depth=40 vel=120`" })

-- Hearing ------------------------------------------------------------------------------

emap("gh", function()
  local _, index = editor:note()
  if index then audition.note(editor.clip_id, index) end
end, "Hear the note under the cursor")

command("utau.inspector", function()
  local gui = require("utau.gui")
  gui.inspector = not gui.inspector
  api.ui_redraw()
end, { desc = "Show or hide the note inspector in the vocal editor's window" })

return {}

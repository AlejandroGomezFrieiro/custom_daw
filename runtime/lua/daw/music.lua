-- Note names and a few scales, for scripts that would rather say "C4" than 60.
local M = {}

local names = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local offsets = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

--- MIDI note number for a name such as "C4", "f#3" or "Bb2". Numbers pass through.
function M.pitch(note)
  if type(note) == "number" then return note end
  local letter, accidental, octave = tostring(note):match("^([A-Ga-g])([#b]?)(-?%d+)$")
  if not letter then error("not a note name: " .. tostring(note), 2) end
  local semitone = offsets[letter:upper()] + (accidental == "#" and 1 or accidental == "b" and -1 or 0)
  return (tonumber(octave) + 1) * 12 + semitone
end

--- Name of a MIDI note number: 60 -> "C4".
function M.name(pitch)
  return names[pitch % 12 + 1] .. (math.floor(pitch / 12) - 1)
end

function M.is_black(pitch)
  return #names[pitch % 12 + 1] == 2
end

M.scales = {
  major = { 0, 2, 4, 5, 7, 9, 11 },
  minor = { 0, 2, 3, 5, 7, 8, 10 },
  dorian = { 0, 2, 3, 5, 7, 9, 10 },
  pentatonic = { 0, 2, 4, 7, 9 },
  minor_pentatonic = { 0, 3, 5, 7, 10 },
  blues = { 0, 3, 5, 6, 7, 10 },
  chromatic = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
}

--- Pitch of scale degree `degree` (1 is the root, 8 the octave above).
function M.degree(root, scale, degree)
  local steps = type(scale) == "table" and scale or M.scales[scale] or error("unknown scale " .. tostring(scale), 2)
  local index = degree - 1
  return M.pitch(root) + steps[index % #steps + 1] + 12 * math.floor(index / #steps)
end

return M

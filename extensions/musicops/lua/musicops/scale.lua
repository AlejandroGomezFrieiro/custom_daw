-- Keys and scales: which pitches belong, how to move by scale degrees, and
-- the project's own key, kept in `project.meta.musicops` so that it is saved
-- with the project and undone like any edit.
--
-- A key is a table { root = 0..11, scale = "minor", steps = { 0, 2, 3, ... } }.
-- Everything that takes a key also takes its name: "D minor", "F# dorian",
-- "Bb" (major when no scale is named).
local M = {}

local NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local LETTERS = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }

--- Every scale known by name, as semitones above the root. The runtime's
--- `daw.music.scales` plus the church modes and the other minors.
M.scales = {
  major = { 0, 2, 4, 5, 7, 9, 11 },
  minor = { 0, 2, 3, 5, 7, 8, 10 },
  harmonic_minor = { 0, 2, 3, 5, 7, 8, 11 },
  melodic_minor = { 0, 2, 3, 5, 7, 9, 11 },
  dorian = { 0, 2, 3, 5, 7, 9, 10 },
  phrygian = { 0, 1, 3, 5, 7, 8, 10 },
  lydian = { 0, 2, 4, 6, 7, 9, 11 },
  mixolydian = { 0, 2, 4, 5, 7, 9, 10 },
  locrian = { 0, 1, 3, 5, 6, 8, 10 },
  pentatonic = { 0, 2, 4, 7, 9 },
  minor_pentatonic = { 0, 3, 5, 7, 10 },
  blues = { 0, 3, 5, 6, 7, 10 },
  whole_tone = { 0, 2, 4, 6, 8, 10 },
  chromatic = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
}
for name, steps in pairs(daw.music.scales or {}) do
  if not M.scales[name] then M.scales[name] = steps end
end
local ALIASES = { ionian = "major", aeolian = "minor", maj = "major", min = "minor", m = "minor" }

--- Names of the known scales, sorted.
function M.names()
  local out = {}
  for name in pairs(M.scales) do out[#out + 1] = name end
  table.sort(out)
  return out
end

--- A pitch class (0..11) from a name such as "C", "f#", "Bb", or a number.
function M.pitch_class(name)
  if type(name) == "number" then return name % 12 end
  local letter, accidental = tostring(name):match("^([A-Ga-g])([#b]?)$")
  if not letter then error("not a key root: " .. tostring(name), 2) end
  return (LETTERS[letter:upper()] + (accidental == "#" and 1 or accidental == "b" and -1 or 0)) % 12
end

--- A key from a name ("D minor", "F# dorian", "Bb") or a table
--- ({ root = "D", scale = "minor" } or an existing key).
function M.parse(spec)
  if type(spec) == "table" then
    if spec.steps then return spec end
    return M.parse((spec.root and NAMES[M.pitch_class(spec.root) + 1] or "C") .. " " .. (spec.scale or "major"))
  end
  local root, scale = tostring(spec):match("^%s*(%S+)%s*(.-)%s*$")
  if not root then error("not a key: " .. tostring(spec), 2) end
  scale = scale:lower():gsub("[%s%-]+", "_")
  if scale == "" then scale = "major" end
  scale = ALIASES[scale] or scale
  local steps = M.scales[scale]
  if not steps then error("unknown scale `" .. scale .. "`; known: " .. table.concat(M.names(), " "), 2) end
  return { root = M.pitch_class(root), scale = scale, steps = steps }
end

--- "D minor".
function M.name(key)
  key = M.parse(key)
  return NAMES[key.root + 1] .. " " .. key.scale
end

local function contains(key, pitch)
  local rel = (pitch - key.root) % 12
  for i, s in ipairs(key.steps) do
    if s == rel then return i end
  end
end

--- Whether a pitch belongs to a key.
function M.contains(key, pitch)
  return contains(M.parse(key), pitch) ~= nil
end

--- The pitch of the key nearest to `pitch`: `dir` "nearest" (the default;
--- halfway between two goes up), "up" or "down". Stays within 0..127.
function M.snap(key, pitch, dir)
  key = M.parse(key)
  dir = dir or "nearest"
  if contains(key, pitch) then return pitch end
  for d = 1, 12 do
    local up, down = pitch + d, pitch - d
    if dir ~= "down" and up <= 127 and contains(key, up) then return up end
    if dir ~= "up" and down >= 0 and contains(key, down) then return down end
  end
  return pitch
end

--- A pitch as an absolute scale degree (0 is the root in octave -1) and
--- the semitones it lies above that degree (non-zero for notes outside it).
function M.degree(key, pitch)
  key = M.parse(key)
  local below = pitch
  while not contains(key, below) do below = below - 1 end
  local rel = below - key.root
  local octave = math.floor(rel / 12)
  local index = contains(key, below)
  return octave * #key.steps + index - 1, pitch - below
end

--- The pitch of an absolute scale degree.
function M.pitch(key, degree)
  key = M.parse(key)
  local n = #key.steps
  return key.root + key.steps[degree % n + 1] + 12 * math.floor(degree / n)
end

--- Move a pitch by `n` scale degrees. A pitch outside the key keeps its
--- distance from the scale note below it.
function M.step(key, pitch, n)
  local degree, offset = M.degree(key, pitch)
  return M.pitch(key, degree + n) + offset
end

-- The project's key -----------------------------------------------------------

M.default = "C major"

--- The project's key, or nil when none is set.
function M.project()
  local meta = daw.api.project_get().meta or {}
  local stored = meta.musicops
  if type(stored) == "table" and stored.root and stored.scale then
    local ok, key = pcall(M.parse, { root = stored.root, scale = stored.scale })
    if ok then return key end
  end
end

--- The key to work in: the project's, or C major.
function M.current()
  return M.project() or M.parse(M.default)
end

--- Set the project's key (one edit), or clear it with nil.
function M.set(spec)
  local meta = daw.api.project_get().meta or {}
  local stored = type(meta.musicops) == "table" and meta.musicops or {}
  if spec == nil then
    stored.root, stored.scale = nil, nil
  else
    local key = M.parse(spec)
    stored.root, stored.scale = NAMES[key.root + 1], key.scale
  end
  meta.musicops = next(stored) and stored or nil
  daw.api.project_set("meta", meta)
  daw.emit("musicops.key", { key = spec and M.name(spec) or nil })
  return spec and M.parse(spec) or nil
end

return M

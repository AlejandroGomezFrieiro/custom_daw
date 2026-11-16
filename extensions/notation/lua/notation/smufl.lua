-- The music font: what the engraver reads of it, behind one function.
--
-- `smufl.font(name)` gives the font's SMuFL metadata in a form the engraver
-- uses: `defaults` (the engraving defaults, in staff spaces: line, stem and
-- beam thicknesses and so on), and `glyphs[name]` with each glyph's code
-- point `cp`, bounding box `bbox` ({ sw x, sw y, ne x, ne y }) and `anchors`
-- (`stemUpSE` and the like), in staff spaces with y up as SMuFL gives them.
--
-- The kernel's `daw.api.smufl(font)` is read when it has one (the fonts it
-- embeds for its rasterizer); else the data kept beside this file
-- (`notation/fonts/leland.lua`, Leland's metadata and outlines). The kept
-- data also has each glyph's outline, which `daw.canvas` draws as a path
-- for a frontend that cannot draw the font (the glyph op degrades).
local M = { fonts = {} }

M.DEFAULT = "Leland"

local kept = { Leland = "notation.fonts.leland" }

--- Glyphs by code point, for the outlines.
local outlines = {}

local function from_kept(name)
  local module = kept[name]
  if not module then return nil end
  local data = require(module)
  local by_cp = {}
  for _, g in pairs(data.glyphs) do by_cp[g.cp] = g.path end
  outlines[name] = by_cp
  return { name = data.name, defaults = data.defaults, glyphs = data.glyphs }
end

--- The kernel's metadata as SMuFL writes it (`engravingDefaults`,
--- `glyphBBoxes`, `glyphsWithAnchors`), over the code points kept here.
local function from_api(name, base)
  local api = daw.api
  if not api.smufl then return nil end
  local ok, meta = pcall(api.smufl, name)
  if not ok or type(meta) ~= "table" or type(meta.engravingDefaults) ~= "table" then return nil end
  local glyphs = {}
  for gname, g in pairs(base and base.glyphs or {}) do
    local bb = meta.glyphBBoxes and meta.glyphBBoxes[gname]
    local anchors = meta.glyphsWithAnchors and meta.glyphsWithAnchors[gname]
    local own = { cp = g.cp, bbox = g.bbox, anchors = g.anchors }
    if bb then own.bbox = { bb.bBoxSW[1], bb.bBoxSW[2], bb.bBoxNE[1], bb.bBoxNE[2] } end
    if anchors then
      own.anchors = {}
      for k, v in pairs(anchors) do own.anchors[k] = { v[1], v[2] } end
    end
    glyphs[gname] = own
  end
  return { name = name, defaults = meta.engravingDefaults, glyphs = glyphs }
end

--- The font `name` (Leland when nil), read once.
function M.font(name)
  name = name or M.DEFAULT
  if M.fonts[name] then return M.fonts[name] end
  local base = from_kept(name) or from_kept(M.DEFAULT)
  local font = from_api(name, base) or base
  font.name = name
  M.fonts[name] = font
  return font
end

--- A glyph's outline in staff spaces from its origin, y down, or nil.
function M.outline(name, cp)
  if not outlines[name] then M.font(name) end
  local list = outlines[name] or outlines[M.DEFAULT]
  return list and list[cp]
end

if daw.canvas then daw.canvas.glyph_outline = M.outline end

return M

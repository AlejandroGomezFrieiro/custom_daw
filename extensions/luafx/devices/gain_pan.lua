-- Gain and pan: a level in decibels and a balance, glided so that moving
-- them does not click. The smallest useful device, to start a new one from.
local dsp = require("paw.dsp")

local dev = dsp.device {
  name = "Gain and pan (Lua)",
  params = {
    { key = "gain", name = "Gain", min = -60, max = 24, default = 0, unit = "dB" },
    { key = "pan", name = "Pan", min = -1, max = 1, default = 0 },
    { key = "mode", name = "Mode", choices = { "Stereo", "Mono", "Swap" }, default = "Stereo" },
  },
}

local left_gain, right_gain

function dev.init(sample_rate)
  left_gain = dsp.smoother(10, sample_rate)
  right_gain = dsp.smoother(10, sample_rate)
end

function dev.process(b)
  local p = b.params
  local g = dsp.gain(p.gain)
  -- A balance: the middle leaves both sides as they are.
  local gl = g * math.min(1, 1 - p.pan)
  local gr = g * math.min(1, 1 + p.pan)
  local mode = p.mode
  local left, right = b.left, b.right
  for i = 0, b.frames - 1 do
    local l, r = left[i], right[i]
    if mode == 1 then
      l = (l + r) * 0.5
      r = l
    elseif mode == 2 then
      l, r = r, l
    end
    left[i] = l * left_gain:next(gl)
    right[i] = r * right_gain:next(gr)
  end
end

return dev

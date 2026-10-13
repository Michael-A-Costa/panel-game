local class = require("common.lib.class")

-- Pokémon Puzzle League's AnimationRandom (animation.c), the only random source of its CPU (AI-SPEC §4).
-- Each CPU owns one, so the CPU never touches Panel Attack's panel generator and plays the same for the same seed.

local TWO_16 = 65536
local TWO_24 = 16777216
local TWO_31 = 2147483648
local TWO_32 = 4294967296
local STEP_ADD = 0x87C125
local STEP_MULTIPLY = 0x7B6E72

-- Rounds a non-negative number to the nearest single precision float (24 bit mantissa, ties to even):
-- PPL computes the draw in f32, which is what lets the top 64 states return max itself.
---@param x number
---@return number
local function toSingle(x)
  if x == 0 then
    return 0
  end
  local mantissa, exponent = math.frexp(x)
  local scaled = mantissa * TWO_24
  local whole = math.floor(scaled)
  local rest = scaled - whole
  if rest > 0.5 or (rest == 0.5 and whole % 2 == 1) then
    whole = whole + 1
  end
  return math.ldexp(whole, exponent - 24)
end

---@class PplRandom
---@field state integer the 32 bit seed PPL keeps in gTheGame (unsigned here)
---@overload fun(seed: integer): PplRandom
local PplRandom = class(
---@param self PplRandom
---@param seed integer
function(self, seed)
  self.state = math.floor(seed) % TWO_32
end)

-- AnimationRandom(max): seed = seed + 0x87C125 + seed * 0x7B6E72 (32 bit wrap),
-- then (s32)((f32)(seed & 0x7FFFFFFF) / (f32)0x7FFFFFFF * (f32)max).
-- Returns 0..max-1, and max itself when the low 31 bits are 2^31 - 64 or more.
---@param max integer
---@return integer
function PplRandom:next(max)
  local seed = self.state
  -- seed * STEP_MULTIPLY needs up to 55 bits; split it so doubles stay exact
  local low = seed % TWO_16
  local high = (seed - low) / TWO_16
  local product = (low * STEP_MULTIPLY + ((high * STEP_MULTIPLY) % TWO_16) * TWO_16) % TWO_32
  seed = (seed + STEP_ADD + product) % TWO_32
  self.state = seed
  -- (f32)0x7FFFFFFF is exactly 2^31, so the quotient needs no extra rounding
  local fraction = toSingle(seed % TWO_31) / TWO_31
  return math.floor(toSingle(fraction * max))
end

return PplRandom

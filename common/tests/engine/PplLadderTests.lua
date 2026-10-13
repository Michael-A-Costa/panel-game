local CpuVersusTestUtils = require("common.tests.engine.CpuVersusTestUtils")

-- The clearest relationships of the CPU-vs-CPU ladder check (docs/cpu-ai/BALANCE.md), on fixed seeds so they stay
-- cheap. Each pairing won all 30 seeds when measured; the thresholds leave room for small CPU changes, not for a
-- ladder that turns around.

local SEEDS = 6

---@param labelA string
---@param labelB string
---@param stackLevel integer
---@param cylinder boolean
---@return integer winsA
---@return integer winsB
local function playSeries(labelA, labelB, stackLevel, cylinder)
  local sideA = CpuVersusTestUtils.parseSide(labelA)
  local sideB = CpuVersusTestUtils.parseSide(labelB)
  local wins = {0, 0}
  for seed = 1, SEEDS do
    local result = CpuVersusTestUtils.playMatch(sideA, sideB, seed, stackLevel, cylinder)
    assert(not result.timedOut, labelA .. " vs " .. labelB .. " seed " .. seed .. " should end within 5 minutes")
    if result.winner then
      wins[result.winner] = wins[result.winner] + 1
    end
  end
  return wins[1], wins[2]
end

---@param labelA string the stronger preset
---@param labelB string
---@param stackLevel integer
---@param cylinder boolean
---@param minimumWins integer
local function expectStronger(labelA, labelB, stackLevel, cylinder, minimumWins)
  local winsA, winsB = playSeries(labelA, labelB, stackLevel, cylinder)
  local what = string.format("%s beats %s %s on level %d", labelA, labelB, cylinder and "3D" or "2D", stackLevel)
  print(string.format("PPL ladder: %s: %d-%d", what, winsA, winsB))
  assert(winsA >= minimumWins, what .. " in at least " .. minimumWins .. " of " .. SEEDS .. ", won " .. winsA)
end

-- the ends of the vs-CPU scale and of a difficulty, and the difficulties at one stage
expectStronger("L10", "L1", 4, false, 5)
expectStronger("H15", "H1", 4, false, 5)
expectStronger("S5", "H5", 4, false, 5)
-- on the tower too; L8 vs L3 is the pairing a 1P vs CPU 3D screenshot once saw turn around
expectStronger("L10", "L1", 4, true, 5)
expectStronger("L8", "L3", 4, true, 5)

-- Without garbage a fast CPU keeps the tower down. Before the raise logic looked at the whole tower it raised all 18
-- columns whenever its 6-column view was low and topped out on these seeds after 35 and 37 seconds.
local function fastCpuKeepsTheTowerDown()
  local side = CpuVersusTestUtils.parseSide("L10")
  for _, seed in ipairs({6, 8}) do
    local result = CpuVersusTestUtils.playSolo(side, seed, 4, true, 60 * 60)
    assert(result.timedOut, "L10 alone on the tower, seed " .. seed .. ", should last a minute, topped out after "
           .. result.frames .. " frames")
  end
end

fastCpuKeepsTheTowerDown()

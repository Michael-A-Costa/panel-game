---@diagnostic disable: duplicate-set-field
-- CPU-vs-CPU ladder check for the PPL CPU (docs/cpu-ai/BALANCE.md): plays seeded VERSUS matches between two CPU
-- presets on two engine stacks and prints wins, match length and chains/combos per side. No window content, no input
-- devices, no client setup; like testLauncher.lua it relies on love 12 running the lua file passed as first argument
-- in place of main.lua. Run it headless:
--   run.sh <repo> ./balanceLauncher.lua [options] A:B[@level] ...
-- A and B are presets: H8 = Hard stage 8 (E, N, H, V, S for Easy to Super Hard), L5 = vs-CPU level 5.
-- @level sets the Panel Attack level of both stacks; without it the level PPL plays the harder side's difficulty on
-- (Easy 1, Normal 2, Hard and up 4) or 4 for vs-CPU levels.
-- Options:
--   --seeds=N   matches per pairing (default 10), seeds seed .. seed + N - 1
--   --seed=S    first match seed (default 1)
--   --cap=F     frames before a match counts as a timeout (default 18000, 5 minutes)
--   --3d        play on the tower
--   --solo      each argument is one preset, alone on an endless board: how long it survives without garbage
-- Every match is deterministic for its seed; the output ends with "balance done".

require("common.lib.mathExtensions")
local util = require("common.lib.util")
util.addToCPath("./common/lib/??")
local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.WARN)

local CpuVersusTestUtils = require("common.tests.engine.CpuVersusTestUtils")
-- the level vs-CPU pairings play on unless told otherwise
local VS_CPU_LEVEL = 4
-- PPL plays both stacks of a difficulty on one VS level, Panel Attack's levels 1, 2 and 4 (STADIUM-SPEC §6)
local STACK_LEVEL_BY_DIFFICULTY = {1, 2, 4, 4, 4}

---@class BalanceSettings
---@field seeds integer
---@field seed integer
---@field cap integer
---@field cylinder boolean
---@field solo boolean
---@field jobs string[]

---@param args string[]
---@return BalanceSettings
local function parseArguments(args)
  local settings = {seeds = 10, seed = 1, cap = CpuVersusTestUtils.DEFAULT_FRAME_CAP, cylinder = false, solo = false,
                    jobs = {}}
  for i = 2, #args do
    local argument = args[i]
    local key, value = string.match(argument, "^%-%-(%w+)=?(.*)$")
    if key == "seeds" or key == "seed" or key == "cap" then
      settings[key] = assert(tonumber(value), "--" .. key .. " needs a number")
    elseif key == "3d" then
      settings.cylinder = true
    elseif key == "solo" then
      settings.solo = true
    elseif key then
      error("unknown option " .. argument)
    else
      settings.jobs[#settings.jobs + 1] = argument
    end
  end
  return settings
end

---@param side CpuVersusSide
---@return integer
local function stackLevel(side)
  if side.options.level then
    return VS_CPU_LEVEL
  end
  return STACK_LEVEL_BY_DIFFICULTY[side.options.difficulty]
end

---@param total number
---@param count integer
---@return string
local function mean(total, count)
  if count == 0 then
    return "-"
  end
  return string.format("%.1f", total / count)
end

---@class BalanceTotals
---@field chains integer
---@field chainLinks integer
---@field longestChain integer
---@field combos integer
---@field matches integer
---@field panelsCleared integer

---@return BalanceTotals
local function newTotals()
  return {chains = 0, chainLinks = 0, longestChain = 0, combos = 0, matches = 0, panelsCleared = 0}
end

---@param totals BalanceTotals
---@param stats CpuVersusSideStats
local function addStats(totals, stats)
  totals.chains = totals.chains + stats.chains
  totals.chainLinks = totals.chainLinks + stats.chainLinks
  totals.longestChain = math.max(totals.longestChain, stats.longestChain)
  totals.combos = totals.combos + stats.combos
  totals.matches = totals.matches + stats.matches
  totals.panelsCleared = totals.panelsCleared + stats.panelsCleared
end

---@param totals BalanceTotals
---@param count integer
---@return string
local function sideSummary(totals, count)
  return string.format("ch %s lk %s max x%d co %s clr %s", mean(totals.chains, count), mean(totals.chainLinks, count),
                       totals.longestChain, mean(totals.combos, count), mean(totals.panelsCleared, count))
end

---@param settings BalanceSettings
---@param job string
local function runPairing(settings, job)
  local labelA, labelB, levelText = string.match(job, "^(%w+):(%w+)@?(%d*)$")
  assert(labelA, "a pairing looks like H3:H8 or H3:H8@4, got " .. job)
  local sideA = CpuVersusTestUtils.parseSide(labelA)
  local sideB = CpuVersusTestUtils.parseSide(labelB)
  local level = tonumber(levelText) or math.max(stackLevel(sideA), stackLevel(sideB))

  local wins = {0, 0}
  local draws, timeouts, errors = 0, 0, 0
  local frames = 0
  local finished = 0
  local totals = {newTotals(), newTotals()}
  local winnersBySeed = {}
  local startTime = love.timer.getTime()
  for seed = settings.seed, settings.seed + settings.seeds - 1 do
    local success, result = pcall(CpuVersusTestUtils.playMatch, sideA, sideB, seed, level, settings.cylinder, settings.cap)
    if not success then
      errors = errors + 1
      winnersBySeed[#winnersBySeed + 1] = "E"
      print("ERROR " .. job .. " seed " .. seed .. ": " .. tostring(result))
    else
      ---@cast result CpuVersusResult
      if result.timedOut then
        timeouts = timeouts + 1
        winnersBySeed[#winnersBySeed + 1] = "T"
      elseif result.winner then
        wins[result.winner] = wins[result.winner] + 1
        frames = frames + result.frames
        finished = finished + 1
        winnersBySeed[#winnersBySeed + 1] = result.winner == 1 and "A" or "B"
      else
        draws = draws + 1
        frames = frames + result.frames
        finished = finished + 1
        winnersBySeed[#winnersBySeed + 1] = "D"
      end
      addStats(totals[1], result.sides[1])
      addStats(totals[2], result.sides[2])
    end
    collectgarbage("collect")
  end
  local played = settings.seeds - errors
  print(string.format("%-12s %s lvl%d  A %2d  B %2d  D %d  T %d  E %d  len %6ss  | A %s | B %s | %s | %.1fs",
                      labelA .. ":" .. labelB, settings.cylinder and "3D" or "2D", level, wins[1], wins[2], draws,
                      timeouts, errors, mean(frames / 60, finished), sideSummary(totals[1], played),
                      sideSummary(totals[2], played), table.concat(winnersBySeed), love.timer.getTime() - startTime))
end

---@param settings BalanceSettings
---@param job string
local function runSolo(settings, job)
  local label, levelText = string.match(job, "^(%w+)@?(%d*)$")
  assert(label, "a solo run looks like H3 or H3@4, got " .. job)
  local side = CpuVersusTestUtils.parseSide(label)
  local level = tonumber(levelText) or stackLevel(side)

  local survived, errors = 0, 0
  local frames = 0
  local totals = newTotals()
  local lengths = {}
  local startTime = love.timer.getTime()
  for seed = settings.seed, settings.seed + settings.seeds - 1 do
    local success, result = pcall(CpuVersusTestUtils.playSolo, side, seed, level, settings.cylinder, settings.cap)
    if not success then
      errors = errors + 1
      print("ERROR " .. job .. " seed " .. seed .. ": " .. tostring(result))
    else
      ---@cast result CpuVersusResult
      if result.timedOut then
        survived = survived + 1
      end
      frames = frames + result.frames
      lengths[#lengths + 1] = string.format("%d", result.frames / 60)
      addStats(totals, result.sides[1])
    end
    collectgarbage("collect")
  end
  local played = settings.seeds - errors
  print(string.format("solo %-5s %s lvl%d  survived %2d/%d  E %d  mean %6ss  | %s | %s | %.1fs", label,
                      settings.cylinder and "3D" or "2D", level, survived, played, errors, mean(frames / 60, played),
                      sideSummary(totals, played), table.concat(lengths, " "), love.timer.getTime() - startTime))
end

function love.load()
  local settings = parseArguments(arg)
  print(string.format("seeds %d from %d, cap %d frames%s", settings.seeds, settings.seed, settings.cap,
                      settings.cylinder and ", 3D" or ""))
  for _, job in ipairs(settings.jobs) do
    if settings.solo then
      runSolo(settings, job)
    else
      runPairing(settings, job)
    end
  end
  print("balance done")
  os.exit(0)
end

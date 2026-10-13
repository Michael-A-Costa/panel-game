local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
-- registers itself with ComputerPlayer
require("common.engine.computerPlayers.PplCpu.PplCpu")

-- Plays PPL CPU against PPL CPU headlessly, two engine stacks targeting each other the way ClientMatch sets up a
-- VERSUS match (INTEGRATION §A5 "Two stacks"), and counts what each side did. Used by balanceLauncher.lua to check
-- the difficulty ladder and by PplLadderTests for its fixed-seed regressions. Deterministic per seed.

---@class CpuVersusSide
---@field options CpuOptions the CPU preset without the seed
---@field label string? for tables, e.g. "H8"

---@class CpuVersusSideStats
---@field matches integer matches made (each clear, chain links included)
---@field combos integer matches of 4 panels or more
---@field chains integer chains of x2 or more
---@field chainLinks integer chain links after the first match of a chain
---@field longestChain integer
---@field panelsCleared integer
---@field toppedOut boolean

---@class CpuVersusResult
---@field winner integer? 1 or 2 for the sides as passed (not the seats), nil for a draw or a timeout
---@field timedOut boolean the frame cap ran out before the match ended
---@field frames integer frames the match ran
---@field sides CpuVersusSideStats[] by side as passed

local CpuVersusTestUtils = {}

-- 5 minutes of play, the length PLAN phase 4 asks every preset to survive
CpuVersusTestUtils.DEFAULT_FRAME_CAP = 60 * 60 * 5

---@return CpuVersusSideStats
local function newSideStats()
  return {matches = 0, combos = 0, chains = 0, chainLinks = 0, longestChain = 0, panelsCleared = 0, toppedOut = false}
end

---@param stack Stack
---@param stats CpuVersusSideStats
---@param subscriber table kept alive while the match runs; signal subscriptions are weak
local function countMatches(stack, stats, subscriber)
  stack:connectSignal("matched", subscriber, function(_, matchedStack, _, isChainLink, comboSize)
    stats.matches = stats.matches + 1
    if comboSize >= 4 then
      stats.combos = stats.combos + 1
    end
    if isChainLink then
      stats.chainLinks = stats.chainLinks + 1
      if matchedStack.chain_counter == 2 then
        stats.chains = stats.chains + 1
      end
      stats.longestChain = math.max(stats.longestChain, matchedStack.chain_counter)
    end
  end)
end

---@param gameModeId GameModeID
---@param stackLevel integer
---@param seed integer
---@param stackCount integer
---@return Match
local function createMatch(gameModeId, stackLevel, seed, stackCount)
  local gameMode = GameModes.getPreset(gameModeId)
  local shockEnabled = gameMode.stackInteraction ~= GameModes.StackInteractions.NONE
  local match = Match(GeneratorSource(seed, shockEnabled), gameMode.matchRules)
  for _ = 1, stackCount do
    match:createStackWithSettings(LevelPresets.getModern(stackLevel), true, "controller")
  end
  return match
end

---@param match Match
local function start(match)
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
end

-- what ClientMatch:run does for CPU stacks: one input for each caught up stack, then one step of the match
---@param match Match
---@param cpus CpuImplementation[]
local function runFrame(match, cpus)
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    if not stack:game_ended() and #stack.confirmedInput == stack.clock then
      stack:receiveConfirmedInput(cpus[i]:getInput())
    end
  end
  match:run()
end

-- One single-game VERSUS match: sideA against sideB on the given stack level. On odd seeds side A plays stack 1, on even
-- seeds stack 2, so a series doesn't favour a seat.
---@param sideA CpuVersusSide
---@param sideB CpuVersusSide
---@param seed integer the match seed; the CPUs' seeds derive from it like ClientMatch's do
---@param stackLevel integer Panel Attack modern level of both stacks
---@param cylinder boolean? play on the 3D tower
---@param frameCap integer? frames before the match counts as a timeout
---@return CpuVersusResult
function CpuVersusTestUtils.playMatch(sideA, sideB, seed, stackLevel, cylinder, frameCap)
  frameCap = frameCap or CpuVersusTestUtils.DEFAULT_FRAME_CAP
  local gameModeId = cylinder and GameModes.IDs.ONE_PLAYER_VS_CPU_3D or GameModes.IDs.ONE_PLAYER_VS_CPU
  local match = createMatch(gameModeId, stackLevel, seed, 2)
  local sides = seed % 2 == 1 and {sideA, sideB} or {sideB, sideA}
  local stats = {newSideStats(), newSideStats()}
  local seatStats = seed % 2 == 1 and {stats[1], stats[2]} or {stats[2], stats[1]}
  local subscriber = {}
  local cpus = {}
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    local options = shallowcpy(sides[i].options)
    options.seed = ComputerPlayer.deriveSeed(seed, i)
    cpus[i] = ComputerPlayer.create("PplCpu", stack, options)
    countMatches(stack, seatStats[i], subscriber)
  end
  match:addTarget(match.stacks[1], match.stacks[2])
  match:addTarget(match.stacks[2], match.stacks[1])
  start(match)

  local frames = 0
  while not match:hasEnded() and frames < frameCap do
    frames = frames + 1
    runFrame(match, cpus)
  end

  local result = {winner = nil, timedOut = not match:hasEnded(), frames = frames, sides = stats}
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    seatStats[i].panelsCleared = stack.panels_cleared
    seatStats[i].toppedOut = stack:game_ended()
  end
  if not result.timedOut then
    local winners = match:getWinners()
    if #winners == 1 then
      local seat = winners[1] == match.stacks[1] and 1 or 2
      result.winner = (seed % 2 == 1) == (seat == 1) and 1 or 2
    end
  end
  return result
end

-- One CPU alone on an endless board of the given level, no garbage: how long it survives the rising stack.
---@param side CpuVersusSide
---@param seed integer
---@param stackLevel integer
---@param cylinder boolean?
---@param frameCap integer?
---@return CpuVersusResult result winner is 1 if it survived the cap
function CpuVersusTestUtils.playSolo(side, seed, stackLevel, cylinder, frameCap)
  frameCap = frameCap or CpuVersusTestUtils.DEFAULT_FRAME_CAP
  local gameModeId = cylinder and GameModes.IDs.ONE_PLAYER_ENDLESS_3D or GameModes.IDs.ONE_PLAYER_ENDLESS
  local match = createMatch(gameModeId, stackLevel, seed, 1)
  local stack = match.stacks[1]
  ---@cast stack Stack
  local stats = newSideStats()
  local subscriber = {}
  local options = shallowcpy(side.options)
  options.seed = ComputerPlayer.deriveSeed(seed, 1)
  local cpus = {ComputerPlayer.create("PplCpu", stack, options)}
  countMatches(stack, stats, subscriber)
  start(match)

  local frames = 0
  while not match:hasEnded() and frames < frameCap do
    frames = frames + 1
    runFrame(match, cpus)
  end
  stats.panelsCleared = stack.panels_cleared
  stats.toppedOut = stack:game_ended()
  return {winner = stats.toppedOut and nil or 1, timedOut = not stats.toppedOut, frames = frames, sides = {stats}}
end

-- Parses a preset label: "H8" is Hard stage 8 (E, N, H, V, S for Easy to Super Hard), "L5" is vs-CPU level 5.
---@param label string
---@return CpuVersusSide
function CpuVersusTestUtils.parseSide(label)
  local letter, number = string.match(label, "^(%a)(%d+)$")
  assert(letter, "a CPU preset looks like H8 or L5, got " .. tostring(label))
  number = tonumber(number)
  local options
  if letter == "L" then
    options = {level = number}
  else
    local difficulty = string.find("ENHVS", letter, 1, true)
    assert(difficulty, "difficulty letters are E, N, H, V, S or L for a level, got " .. letter)
    options = {difficulty = difficulty, stage = number}
  end
  ComputerPlayer.validateOptions({seed = 0, level = options.level, difficulty = options.difficulty, stage = options.stage})
  return {options = options, label = label}
end

return CpuVersusTestUtils

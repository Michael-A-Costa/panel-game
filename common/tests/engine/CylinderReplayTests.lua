local json = require("common.lib.dkjson")
local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local ReplayV3 = require("common.data.ReplayV3")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")

local idle = KeyDataEncoding.idle
local COUNTDOWN_FRAMES = consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- a busy but deterministic player: turns both ways, moves, swaps and waits
---@param frames integer
---@param seed integer
---@param buttons string[]
---@return string
local function scriptedInputs(frames, seed, buttons)
  local rng = love.math.newRandomGenerator(seed)
  local inputs = {}
  for i = 1, frames do
    local roll = rng:random(1, #buttons + 4)
    inputs[i] = buttons[roll] and CylinderTestUtils.inputFor(buttons[roll]) or idle
  end
  return table.concat(inputs)
end

-- everything about a stack that a replay has to reproduce
---@param stack Stack
---@return string
local function snapshot(stack)
  ---@type (integer | string)[]
  local parts = {stack.clock, stack.game_over_clock, stack.score, stack.cur_row, stack.cur_col, stack.rotationTimer,
                 stack.chain_counter, stack.panels_cleared}
  for row = 0, #stack.panels do
    for column = 1, stack.width do
      local panel = stack.panels[row][column]
      parts[#parts + 1] = panel.color .. (panel.isGarbage and "g" .. panel.x_offset or "") .. panel.state
    end
  end
  return table.concat(parts, ",")
end

---@param match Match
---@param inputCount integer
local function runUntilEnded(match, inputCount)
  local runs = 0
  while not match:hasEnded() do
    runs = runs + 1
    assert(runs <= inputCount, "the match should end before its inputs run out")
    match:run()
  end
end

-- writes the replay the way the game saves it and reads it back
---@param replay ReplayV3
---@return Match
local function reloadReplay(replay)
  local loaded = ReplayV3.createFromTable(json.decode(json.encode(replay)), true)
  local match = Match.createFromReplay(loaded)
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  return match
end

---@param replay ReplayV3
local function checkReplayVersion(replay)
  expect(replay.engineVersion, consts.ENGINE_VERSIONS.CYLINDER, "3D replays record the cylinder engine version")
  assert(replay.rules.stackSetupModifications.cylinder, "3D replays record the cylinder rule")
  -- an unmodified client refuses replays whose version sorts after its own, so this has to stay above all of them
  for version = 45, 299 do
    assert(replay.engineVersion > string.format("%03d", version), "a client on v" .. version .. " would play this replay")
  end
  local debugEnabled = DEBUG_ENABLED
  DEBUG_ENABLED = false
  assert(ReplayV3.replayCanBeViewed(replay), "this fork plays its own 3D replays")
  DEBUG_ENABLED = debugEnabled
end

local function endlessReplayRoundTripTest()
  local gameMode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local match = Match(GeneratorSource(4242, false), gameMode.matchRules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(10), false, "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)
  local inputs = string.rep(idle, COUNTDOWN_FRAMES) .. scriptedInputs(900, 7, {"left", "right", "up", "down", "swap", "raise"})
                 .. string.rep(KeyDataEncoding.raise, 3000)
  stack:receiveConfirmedInput(inputs)
  local replay = match:createNewReplay()

  runUntilEnded(match, inputs:len())
  assert(stack.game_over_clock > 0, "the endless run ends in a game over")
  assert(stack.score > 0, "the scripted player scored")
  ReplayV3.finalizeReplay(match, replay)
  checkReplayVersion(replay)

  local replayed = reloadReplay(replay)
  local replayedStack = replayed.stacks[1]
  ---@cast replayedStack Stack
  assert(replayedStack.cylinder and replayedStack.width == 18, "the replay rebuilds a 3D tower")
  runUntilEnded(replayed, inputs:len())
  expect(snapshot(replayedStack), snapshot(stack), "the replayed tower ends exactly like the recorded one")
end

endlessReplayRoundTripTest()

-- a 3D stack against an attack engine, so every 3D garbage shape lands during the recording
local function attackReplayRoundTripTest()
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_TRAINING).matchRules
  rules.stackSetupModifications.cylinder = true
  local match = Match(GeneratorSource(77, true), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(1), false, "controller")
  ---@cast stack Stack
  local attacker = match:createSimulatedStackWithSettings({
    delayBeforeStart = 0,
    delayBeforeRepeat = 100000,
    countdownAdjusted = true,
    -- a x4 chain for the full ring: a x5's two rows would top the tower out before the rest lands
    attackPatterns = {
      {width = 6, height = 1, startTime = 20, metal = true},
      {width = 3, height = 1, startTime = 30},
      {width = 5, height = 1, startTime = 40},
      {chain = {60, 80}, chainEndTime = 100},
      {chain = {120, 140, 160}, chainEndTime = 180},
    }
  })
  match:addTarget(attacker, stack)
  match:start()
  stack:setMaxRunsPerFrame(1)
  attacker:setMaxRunsPerFrame(1)

  local inputs = string.rep(idle, COUNTDOWN_FRAMES) .. scriptedInputs(900, 11, {"left", "right", "left", "up", "down"})
                 .. string.rep(KeyDataEncoding.raise, 3000)
  stack:receiveConfirmedInput(inputs)
  local replay = match:createNewReplay()

  local widthsSeen = {}
  local runs = 0
  while not match:hasEnded() do
    runs = runs + 1
    assert(runs <= inputs:len(), "the match should end before its inputs run out")
    match:run()
    for row = 1, #stack.panels do
      for column = 1, stack.width do
        local panel = stack.panels[row][column]
        if panel.isGarbage then
          widthsSeen[panel.width] = true
        end
      end
    end
  end
  for _, width in ipairs({3, 5, 6, 12, 18}) do
    assert(widthsSeen[width], "a " .. width .. " wide block should have landed on the tower")
  end
  assert(stack.game_over_clock > 0, "the tower tops out in the end")
  ReplayV3.finalizeReplay(match, replay)
  checkReplayVersion(replay)

  local replayed = reloadReplay(replay)
  local replayedStack = replayed.stacks[1]
  ---@cast replayedStack Stack
  -- like an opponent lagging online: the tower runs ahead of the attacker past the frames its blocks arrive on, so the
  -- match rolls it back to take each one on time, mid rotation included
  StackReplayTestingUtils:simulateMatchUntil(replayed, 400)
  StackReplayTestingUtils:simulateStack(replayedStack, 540)
  runUntilEnded(replayed, inputs:len())
  assert(replayedStack.rollbackCount > 0, "the tower should have been rolled back for late garbage")
  expect(snapshot(replayedStack), snapshot(stack), "the replayed tower ends exactly like the recorded one")
end

attackReplayRoundTripTest()

-- 2D replays keep today's version string and rules
local function flatReplayKeepsItsVersionTest()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 10)
  local replay = match:createNewReplay()
  expect(replay.engineVersion, consts.ENGINE_VERSION, "2D replays keep the regular engine version")
  assert(not replay.rules.stackSetupModifications.cylinder, "2D replays have no cylinder rule")
  StackReplayTestingUtils:cleanup(match)
end

flatReplayKeepsItsVersionTest()

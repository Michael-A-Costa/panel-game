local json = require("common.lib.dkjson")
local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local ReplayV3 = require("common.data.ReplayV3")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")

local idle = KeyDataEncoding.idle
local COUNTDOWN_FRAMES = consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH

-- a busy but deterministic player pressing one of buttons on most frames
---@param frames integer
---@param seed integer
---@param buttons ("left" | "right" | "up" | "down" | "swap" | "raise")[]
---@return string
local function scriptedInputs(frames, seed, buttons)
  local rng = love.math.newRandomGenerator(seed)
  local inputs = {}
  for i = 1, frames do
    local button = buttons[rng:random(1, #buttons + 4)]
    inputs[i] = button and KeyDataEncoding[button] or idle
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

-- saves the replay the way the game does and loads it again
---@param replay ReplayV3
---@return Match
local function reloadReplay(replay)
  local loaded = ReplayV3.createFromTable(json.decode(json.encode(replay)), true)
  local match = Match.createFromReplay(loaded)
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  local stack = match.stacks[1]
  ---@cast stack Stack
  assert(stack.cylinder, "the replay builds a cylinder")
  return match
end

local function endlessReplayTest()
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules
  rules.stackSetupModifications.cylinder = true
  local match = Match(GeneratorSource(4242, false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(10), false, "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)
  local inputs = string.rep(idle, COUNTDOWN_FRAMES) .. scriptedInputs(900, 7, {"left", "right", "up", "down", "swap", "raise"})
                 .. string.rep(KeyDataEncoding.raise, 3000)
  stack:receiveConfirmedInput(inputs)
  local replay = match:createNewReplay()

  runUntilEnded(match, inputs:len())
  assert(stack.score > 0, "the scripted player scored")
  ReplayV3.finalizeReplay(match, replay)

  local replayed = reloadReplay(replay)
  runUntilEnded(replayed, inputs:len())
  assertEqual(snapshot(replayed.stacks[1]), snapshot(stack))
end

endlessReplayTest()

-- against an attack engine, so every garbage shape of the cylinder lands during the recording
local function attackReplayTest()
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_TRAINING).matchRules
  rules.stackSetupModifications.cylinder = true
  local match = Match(GeneratorSource(77, true), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(1), false, "controller")
  ---@cast stack Stack
  local attacker = match:createSimulatedStackWithSettings({
    delayBeforeStart = 0,
    delayBeforeRepeat = 100000,
    countdownAdjusted = true,
    -- a chain of 4 for the full ring: one of 5 would top the tower out before the rest lands
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
    assert(widthsSeen[width], "a " .. width .. " wide block should have landed")
  end
  ReplayV3.finalizeReplay(match, replay)

  local replayed = reloadReplay(replay)
  local replayedStack = replayed.stacks[1]
  ---@cast replayedStack Stack
  -- the tower runs ahead of the attacker like against a lagging opponent online, so the match has to roll it back
  -- to take each block on time, during turns too
  StackReplayTestingUtils:simulateMatchUntil(replayed, 400)
  StackReplayTestingUtils:simulateStack(replayedStack, 540)
  runUntilEnded(replayed, inputs:len())
  assert(replayedStack.rollbackCount > 0, "the tower should have been rolled back for late garbage")
  assertEqual(snapshot(replayedStack), snapshot(stack))
end

attackReplayTest()

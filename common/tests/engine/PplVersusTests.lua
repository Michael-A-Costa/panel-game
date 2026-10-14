local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local consts = require("common.engine.consts")

-- Pokémon Puzzle League's 2P VS pace, which the Stadium modes turn on (docs/cpu-ai/STADIUM-SPEC.md §2)

local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

---@param gameModeId GameModeID
---@param level integer
---@param helperPairs PplHelperPairs?
---@return Stack
---@return Match
local function createStack(gameModeId, level, helperPairs)
  local rules = GameModes.getPreset(gameModeId).matchRules
  rules.doCountdown = false
  rules.stackSetupModifications.behaviours = {passiveRaise = false, allowManualRaise = false}
  rules.stackSetupModifications.pplHelperPairs = helperPairs
  local match = Match(GeneratorSource(1, false), rules)
  local levelData = LevelPresets.getModern(level)
  -- as Stadium plays: no pairs from the generator itself
  levelData.adjacentDenialFrequency = 1
  local stack = match:createStackWithSettings(levelData, false, "controller")
  ---@cast stack Stack
  return stack, match
end

-- runs the speed increases of the time interval mode up to a clock time
---@param stack Stack
---@param clock integer
local function advanceSpeedTo(stack, clock)
  while stack.nextSpeedIncreaseClock <= clock do
    stack.clock = stack.nextSpeedIncreaseClock
    stack:updateSpeed()
  end
  stack.clock = clock
end

local function tablesTest()
  expect(#consts.PPL_SPEED_TO_RISE_TIME, 99, "st_RaiseTimer has a value per speed level")
  expect(consts.PPL_SPEED_TO_RISE_TIME[1] * 16, 961, "speed 1 rises a row in 961 frames")
  expect(consts.PPL_SPEED_TO_RISE_TIME[99] * 16, 8, "speed 99 in 8")
  expect(#consts.PPL_SPEED_INCREASE_FRAMES, 40, "st_AdvanceLevel has 40 steps")
end

local function stadiumStackTest()
  for _, gameModeId in ipairs({GameModes.IDs.ONE_PLAYER_STADIUM, GameModes.IDs.ONE_PLAYER_STADIUM_3D}) do
    local stack = createStack(gameModeId, 4)
    assert(stack.pplVersus, gameModeId .. " plays PPL's pace")
    expect(stack.riseTimes, consts.PPL_SPEED_TO_RISE_TIME, "with PPL's rise times")
    local startingSpeed = stack.levelData.startingSpeed
    expect(stack.rise_timer, consts.PPL_SPEED_TO_RISE_TIME[startingSpeed], "from the first step")

    -- 15 s steps for the first four levels, then 10 s, 9 s, 8 s, 7 s, 6 s and finally 5 s
    expect(stack.nextSpeedIncreaseClock, 900, "the first increase comes after 15 seconds")
    advanceSpeedTo(stack, 3600)
    expect(stack.speed, startingSpeed + 4, "four increases in the first minute")
    advanceSpeedTo(stack, 6000)
    expect(stack.speed, startingSpeed + 8, "four more in the next 40 seconds")
    advanceSpeedTo(stack, 6000 + 4 * 540 + 4 * 480 + 8 * 420 + 4 * 360 + 12 * 300)
    expect(stack.speed, startingSpeed + 40, "one increase per step of the schedule")
    advanceSpeedTo(stack, stack.clock + 300)
    expect(stack.speed, startingSpeed + 41, "the last step repeats")
  end
end

local function topoutGraceTest()
  local stack = createStack(GameModes.IDs.ONE_PLAYER_STADIUM, 4)
  local grace = stack.levelData.maxHealth
  local cases = {
    {minutes = 0, health = grace},
    {minutes = 5, health = math.floor(grace * 0.75)},
    {minutes = 10, health = math.floor(grace / 2)},
    {minutes = 15, health = math.floor(grace * 0.75 / 2)},
    {minutes = 25, health = math.floor(grace * 0.75 / 4)},
    {minutes = 40, health = math.floor(grace / 8)},
  }
  for _, case in ipairs(cases) do
    stack.clock = case.minutes * 3600
    expect(stack:getMaxHealth(), case.health, "topout grace after " .. case.minutes .. " minutes")
  end

  -- topped out across the 5 minute mark: the grace shrinks under the stack, as PPL compares every frame
  stack.clock = 5 * 3600 - 1
  stack.wasToppedOut = false
  stack:updateHealth()
  local before = stack.health
  expect(before, math.floor(grace * 0.8), "refilled to the grace of minute 4")
  stack.wasToppedOut = true
  stack.health = before - 10
  stack.clock = 5 * 3600
  stack:updateHealth()
  expect(stack.health, before - 10 - (before - math.floor(grace * 0.75)), "loses what the grace shrank by")
  stack:updateHealth()
  expect(stack.health, before - 10 - (before - math.floor(grace * 0.75)), "once")
  stack.clock = 40 * 3600
  stack.health = 1
  stack:updateHealth()
  expect(stack.health, 0, "and never below 0")
end

-- every other mode keeps Panel Attack's pace, so their games and replays stay as they were
local function otherModesTest()
  local stack = createStack(GameModes.IDs.ONE_PLAYER_VS_CPU, 4)
  assert(not stack.pplVersus, "vs CPU keeps Panel Attack's pace")
  expect(stack.riseTimes, consts.SPEED_TO_RISE_TIME, "and rise times")
  local startingSpeed = stack.levelData.startingSpeed
  advanceSpeedTo(stack, 3600 * 20)
  expect(stack.speed, startingSpeed + 80, "one increase every 15 seconds")
  expect(stack:getMaxHealth(), stack.levelData.maxHealth, "and a topout grace that doesn't shrink")
end

-- the new row's horizontal pairs, and whether one sits on its own color in the row above
---@param stack Stack
---@return integer pairCount
---@return boolean stacked
local function newRowPairs(stack)
  local pairCount, stacked = 0, false
  for col = 1, stack.width - 1 do
    local color = stack.panels[0][col].color
    if color == stack.panels[0][col + 1].color then
      pairCount = pairCount + 1
      stacked = stacked or stack.panels[1][col].color == color or stack.panels[1][col + 1].color == color
    end
  end
  return pairCount, stacked
end

-- Easy brings a ready-made pair in every new row, Normal and Hard in every other one, starting with the first
local function helperPairsTest()
  local cases = {{"every", {1, 1, 1, 1, 1, 1}}, {"alternate", {1, 0, 1, 0, 1, 0}}, {false, {0, 0, 0, 0, 0, 0}}}
  for _, case in ipairs(cases) do
    for _, gameModeId in ipairs({GameModes.IDs.ONE_PLAYER_STADIUM, GameModes.IDs.ONE_PLAYER_STADIUM_3D}) do
      local stack, match = createStack(gameModeId, 1, case[1] or nil)
      match:start()
      -- the starting board rises in through new rows as well
      local startingRows = stack.newRowCount
      for row, expected in ipairs(case[2]) do
        stack:new_row()
        local pairCount, stacked = newRowPairs(stack)
        local name = tostring(case[1]) .. " " .. gameModeId .. " row " .. row
        expect(pairCount, expected, name .. " pairs")
        assert(not stacked, name .. ": a pair never sits on its own color")
      end
      expect(stack.newRowCount - startingRows, #case[2], "the stack counts its rows")
    end
  end
end

tablesTest()
helperPairsTest()
stadiumStackTest()
topoutGraceTest()
otherModesTest()

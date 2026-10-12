local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")

---@return Match
local function createCylinderEndlessMatch()
  local gameMode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local match = Match(GeneratorSource(1, false), gameMode.matchRules)
  match:createStackWithSettings(LevelPresets.getModern(5), false, "controller")
  match:start()
  match.stacks[1]:setMaxRunsPerFrame(1)
  return match
end

local function cylinderStackIsEighteenWide()
  local match = createCylinderEndlessMatch()
  local stack = match.stacks[1]
  ---@cast stack Stack

  assert(stack.cylinder, "the 3D preset should build a cylinder stack")
  assert(stack.width == consts.CYLINDER_WIDTH, "expected width " .. consts.CYLINDER_WIDTH .. ", got " .. stack.width)
  for row = 0, stack.height do
    for column = 1, stack.width do
      assert(stack.panels[row][column], "missing panel at row " .. row .. " column " .. column)
    end
  end
  assert(stack.rotationTimer == 0 and stack.rotationDirection == 0, "a new tower should not be rotating")
  assert(stack:getCylinderViewCenter() == stack.cur_col, "a resting tower is centred on the cursor")

  stack:receiveConfirmedInput(string.rep("A", 600))
  StackReplayTestingUtils:simulateMatchUntil(match, 600)
  assert(stack.clock == 600, "the cylinder stack should run")
  StackReplayTestingUtils:cleanup(match)
end

cylinderStackIsEighteenWide()

local function twoDimensionalStackIsUnchanged()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 5)
  local stack = match.stacks[1]
  ---@cast stack Stack

  assert(not stack.cylinder, "2D presets must not build a cylinder")
  assert(stack.width == 6, "2D stacks stay 6 wide")
  StackReplayTestingUtils:cleanup(match)
end

twoDimensionalStackIsUnchanged()

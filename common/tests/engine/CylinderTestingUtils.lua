local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")

local CylinderTestingUtils = {}

---@class CylinderMatchOptions
---@field doCountdown boolean?
---@field passiveRaise boolean? false by default so the board stays where the test put it
---@field shockEnabled boolean?
---@field inputMethod InputMethod?

-- an endless match on a cylinder, without countdown and rising unless asked for
---@param options CylinderMatchOptions?
---@return Match match
---@return Stack stack
function CylinderTestingUtils.createMatch(options)
  options = options or {}
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules
  rules.doCountdown = options.doCountdown or false
  rules.stackSetupModifications.cylinder = true
  rules.stackSetupModifications.behaviours = {
    passiveRaise = options.passiveRaise or false,
    allowManualRaise = options.passiveRaise or false,
  }

  local match = Match(GeneratorSource(1, options.shockEnabled or false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(5), false, options.inputMethod or "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)

  return match, stack
end

-- empties the board so a test can lay out its own
---@param stack Stack
function CylinderTestingUtils.clearBoard(stack)
  for row = 1, #stack.panels do
    for column = 1, stack.width do
      stack.panels[row][column]:clear(true, true)
    end
  end
  -- the incoming row stays full so row 1 rests on something; dimmed panels never match
  for column = 1, stack.width do
    stack.panels[0][column].color = (column - 1) % 5 + 1
  end
end

-- sets the colors of a row by column and flags the panels so the next match check looks at them
---@param stack Stack
---@param row integer
---@param colors table<integer, integer>
function CylinderTestingUtils.setColors(stack, row, colors)
  for column, color in pairs(colors) do
    local panel = stack.panels[row][column]
    panel.color = color
    panel.stateChanged = true
  end
end

return CylinderTestingUtils

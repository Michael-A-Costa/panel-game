local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")

local CylinderTestUtils = {}

---@class CylinderMatchOptions
---@field doCountdown boolean?
---@field passiveRaise boolean? false by default so a test's board stays where it put it
---@field shockEnabled boolean?
---@field inputMethod InputMethod?
---@field seed integer?

-- a 3D endless match for tests: no countdown and no rising unless asked for
---@param options CylinderMatchOptions?
---@return Match match
---@return Stack stack
function CylinderTestUtils.createMatch(options)
  options = options or {}
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS_3D).matchRules
  rules.doCountdown = options.doCountdown or false
  rules.stackSetupModifications.behaviours = {
    passiveRaise = options.passiveRaise or false,
    allowManualRaise = options.passiveRaise or false,
  }

  local match = Match(GeneratorSource(options.seed or 1, options.shockEnabled or false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(5), false, options.inputMethod or "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)

  return match, stack
end

-- empties every panel on the board so tests can lay out their own
---@param stack Stack
function CylinderTestUtils.clearBoard(stack)
  for row = 1, #stack.panels do
    for column = 1, stack.width do
      stack.panels[row][column]:clear(true, true)
    end
  end
  -- the incoming row stays full like in a real game, so row 1 rests on something; dimmed panels never match
  for column = 1, stack.width do
    stack.panels[0][column].color = (column - 1) % 5 + 1
  end
end

-- sets colors in a row, keyed by column; set panels count as changed so checkMatches looks at them
---@param stack Stack
---@param row integer
---@param colors table<integer, integer>
function CylinderTestUtils.setColors(stack, row, colors)
  for column, color in pairs(colors) do
    local panel = stack.panels[row][column]
    panel.color = color
    panel.stateChanged = true
  end
end

-- the input for pressing several buttons at once, e.g. inputFor("swap", "left")
---@param ... ("raise" | "swap" | "up" | "down" | "left" | "right")
---@return string
function CylinderTestUtils.inputFor(...)
  local bits = {raise = 32, swap = 16, up = 8, down = 4, left = 2, right = 1}
  local value = 0
  for _, button in ipairs({...}) do
    value = value + bits[button]
  end
  return KeyDataEncoding.base64encode[value + 1]
end

return CylinderTestUtils

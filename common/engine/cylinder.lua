local consts = require("common.engine.consts")
---@class Stack
local Stack = require("common.engine.Stack")

-- Rules of Pokémon Puzzle League's 3D mode that go beyond its board being wrapped: the tower turning under the cursor,
-- the countdown intro and where incoming garbage and new shock panels land. Generic code reaches them through Stack
-- methods that check stack.cylinder; the shape of the board itself is the topology in Stack.lua (Stack.wraps).

-- view columns where it starts the chain garbage it reshapes for the cylinder (attack3d.c)
local CYLINDER_CHAIN_X2_VIEW_COLUMN = 2 -- 6 wide over the middle of the front
local CYLINDER_CHAIN_X3_VIEW_COLUMN = 17 -- 12 wide, wrapping round to view column 10
local CYLINDER_FULL_RING_VIEW_COLUMN = 14
local CYLINDER_MAX_FULL_RING_ROWS = 10
-- view columns in which new shock panels enter, in front of the player (init3d.c)
local CYLINDER_FIRST_SHOCK_VIEW_COLUMN = 1
local CYLINDER_LAST_SHOCK_VIEW_COLUMN = 5

-- Starts turning the cylinder by one column. As in Pokémon Puzzle League a press during a turn is dropped, so a held
-- direction, repeating every 3 frames, turns it a column every 6.
---@param direction integer -1 to move cur_col left, 1 to move it right
function Stack:startRotation(direction)
  if self.rotationTimer == 0 then
    self.rotationDirection = direction
    self.rotationTimer = consts.CYLINDER_ROTATION_FRAMES
  end
end

function Stack:finishRotation()
  self.cur_col = self:getCursorColumnAfterMove(self.rotationDirection)
  self.rotationTimer = 0
  self.rotationDirection = 0
end

-- counts down the current turn; cur_col only changes once the turn is over
function Stack:advanceRotation()
  self.rotationTimer = self.rotationTimer - 1
  if self.rotationTimer == 0 then
    self:finishRotation()
  end
end

-- Pokémon Puzzle League turns the tower left while it rises into place (DoCountDown.s); the cursor keeps its column
---@param countDownFrame integer
function Stack:runCylinderIntro(countDownFrame)
  if countDownFrame < consts.CYLINDER_INTRO_FRAMES then
    self:startRotation(-1)
  end
end

-- Senders queue the same garbage for a cylinder as for a flat stack; like Pokémon Puzzle League, the cylinder reshapes
-- chain garbage and places every block relative to the cursor when it drops (attack3d.c), so it lands in front
---@param garbage Garbage
---@return integer width
---@return integer height
---@return integer originCol
function Stack:getCylinderGarbagePlacement(garbage)
  if not garbage.isChain then
    -- the drop columns of a flat stack, two view columns to the right
    return garbage.width, garbage.height, self:viewToBoardColumn(self:getGarbageSpawnColumn(garbage.width) + 1)
  elseif garbage.height == 1 then
    return 6, 1, self:viewToBoardColumn(CYLINDER_CHAIN_X2_VIEW_COLUMN)
  elseif garbage.height == 2 then
    return 12, 1, self:viewToBoardColumn(CYLINDER_CHAIN_X3_VIEW_COLUMN)
  else
    local height = math.min(garbage.height - 2, CYLINDER_MAX_FULL_RING_ROWS)
    return self.width, height, self:viewToBoardColumn(CYLINDER_FULL_RING_VIEW_COLUMN)
  end
end

---@return integer firstViewColumn
---@return integer lastViewColumn
function Stack:getCylinderShockPanelViewColumns()
  return CYLINDER_FIRST_SHOCK_VIEW_COLUMN, CYLINDER_LAST_SHOCK_VIEW_COLUMN
end

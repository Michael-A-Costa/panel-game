local consts = require("common.engine.consts")
---@class Stack
local Stack = require("common.engine.Stack")

-- Rules only a cylinder stack has, with no flat counterpart: the tower turning under the cursor, Pokémon Puzzle
-- League's column numbering from the player's point of view and where incoming garbage lands.

-- Pokémon Puzzle League numbers a cylinder's columns from the player's point of view: view column 0 is at the
-- tower's left edge, 1-8 face the player and the cursor is on 4 and 5
local CYLINDER_CURSOR_VIEW_COLUMN = 4
-- view columns where it starts the chain garbage it reshapes for the cylinder (attack3d.c)
local CYLINDER_CHAIN_X2_VIEW_COLUMN = 2 -- 6 wide over the middle of the front
local CYLINDER_CHAIN_X3_VIEW_COLUMN = 17 -- 12 wide, wrapping round to view column 10
local CYLINDER_FULL_RING_VIEW_COLUMN = 14
local CYLINDER_MAX_FULL_RING_ROWS = 10

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
  self.cur_col = self:wrapColumn(self.cur_col + self.rotationDirection)
  self.rotationTimer = 0
  self.rotationDirection = 0
end

-- counts down the held direction's repeat and the current turn; cur_col only changes once the turn is over
function Stack:updateCylinderTimers()
  if self.cylinderRepeatTimer > 0 then
    self.cylinderRepeatTimer = self.cylinderRepeatTimer - 1
  end
  if self.rotationTimer > 0 then
    self.rotationTimer = self.rotationTimer - 1
    if self.rotationTimer == 0 then
      self:finishRotation()
    end
  end
end

---@param viewColumn integer see CYLINDER_CURSOR_VIEW_COLUMN
---@return integer column
function Stack:viewToBoardColumn(viewColumn)
  return self:wrapColumn(self.cur_col + viewColumn - CYLINDER_CURSOR_VIEW_COLUMN)
end

---@param column integer
---@return integer viewColumn see CYLINDER_CURSOR_VIEW_COLUMN
function Stack:boardToViewColumn(column)
  return (column - self.cur_col + CYLINDER_CURSOR_VIEW_COLUMN) % self.width
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

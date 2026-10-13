local class = require("common.lib.class")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")

-- A placeholder CPU until the port of Pokémon Puzzle League's CPU lands: it slides panels along their row, one swap
-- at a time, to line up three of a color in the row or to stack three of a color in a column. It walks the cursor
-- to the closest such swap and makes it. It never raises, chains or clears garbage on purpose.

local IDLE = KeyDataEncoding.idle
local SWAP = KeyDataEncoding.swap
-- the furthest a panel is slid to complete three on top of each other, in columns
local MAX_SLIDE = 4
-- the widest stretch of a row in which three panels of a color are gathered, PPL's 6 column view
local MAX_SPAN = 6
local INPUT_FOR_DIRECTION = {
  up = KeyDataEncoding.up,
  down = KeyDataEncoding.down,
  left = KeyDataEncoding.left,
  right = KeyDataEncoding.right,
}

-- frames between two actions for PPL's (difficulty, stage), USA (AI-SPEC §6.3)
---@param difficulty integer
---@param stage integer
---@return integer
local function framesPerAction(difficulty, stage)
  local halfStage = math.floor((stage - 1) / 2)
  if difficulty == 1 then
    return 35 - halfStage
  elseif difficulty == 2 then
    return 20 - halfStage
  elseif difficulty == 3 then
    return 16 - halfStage
  elseif difficulty == 4 then
    if stage < 3 then
      return 11
    elseif stage < 5 then
      return 10
    elseif stage < 7 then
      return 9
    elseif stage < 9 then
      return 8
    else
      return 7
    end
  else
    if stage < 5 then
      return 7
    elseif stage < 9 then
      return 6
    elseif stage < 13 then
      return 5
    else
      return 4
    end
  end
end

-- the color a panel brings into a horizontal match, 0 if it can't be part of one right now
---@param panel Panel
---@return integer
local function matchableColor(panel)
  if panel.isGarbage or panel.color == 9 or (panel.state ~= "normal" and panel.state ~= "landing") then
    return 0
  end
  return panel.color
end

---@class SimpleCpu : CpuImplementation
---@field stack Stack
---@field seed integer unused; it plays without randomness
---@field framesPerAction integer frames from one cursor move or swap to the next
---@field nextActionClock integer the first clock at which the next action may happen
---@field targetRow integer row of the next swap to make, 0 if none was found
---@field targetColumn integer left column of the next swap to make
---@field targetDistance number cursor moves to the target
---@field lastSwapRow integer row of the last swap made, 0 before the first
---@field lastSwapColumn integer left column of the last swap made
---@overload fun(stack: Stack, options: CpuOptions): SimpleCpu
local SimpleCpu = class(
---@param self SimpleCpu
---@param stack Stack
---@param options CpuOptions
function(self, stack, options)
  self.stack = stack
  self.seed = options.seed
  self.framesPerAction = framesPerAction(ComputerPlayer.getPreset(options))
  self.nextActionClock = 0
  self.targetRow = 0
  self.targetColumn = 0
  self.targetDistance = math.huge
  self.lastSwapRow = 0
  self.lastSwapColumn = 0
end)

SimpleCpu.getFramesPerAction = framesPerAction

-- whether a panel moved into column of rowIndex rests there rather than falling through
---@param stack Stack
---@param rowIndex integer
---@param column integer
---@return boolean
local function isSupported(stack, rowIndex, column)
  if rowIndex == 1 then
    return true
  end
  local below = stack.panels[rowIndex - 1][column]
  return below.color ~= 0 and below.state ~= "falling"
end

-- whether a panel can be swapped along the row now and in the next few actions; empty spaces included
---@param panel Panel
---@return boolean
local function isSlidable(panel)
  return panel.state == "normal" and not panel.isGarbage and not panel.dont_swap
end

-- the column next to column in direction step (-1 left, 1 right), nil past the edge of a 2D stack
---@param stack Stack
---@param column integer
---@param step integer
---@return integer?
local function neighbour(stack, column, step)
  column = column + step
  if stack.cylinder then
    return stack:wrapColumn(column)
  elseif column < 1 or column > stack.width then
    return nil
  end
  return column
end

-- cursor moves needed to reach column; on a tower the shorter way round
---@param stack Stack
---@param column integer
---@return integer
local function columnDistance(stack, column)
  local distance = math.abs(column - stack.cur_col)
  if stack.cylinder then
    distance = math.min(distance, stack.width - distance)
  end
  return distance
end

-- keeps the swap at rowIndex, swapColumn as the target if it is closer to the cursor than the best so far
---@param rowIndex integer
---@param swapColumn integer left column of the swap
function SimpleCpu:considerSwap(rowIndex, swapColumn)
  -- a slide never swaps the same pair twice in a row; two gathers sharing a pair (A B A B) would swap it back and forth
  if rowIndex == self.lastSwapRow and swapColumn == self.lastSwapColumn then
    return
  end
  local stack = self.stack
  local distance = math.abs(rowIndex - stack.cur_row) + columnDistance(stack, swapColumn)
  if distance < self.targetDistance then
    local row = stack.panels[rowIndex]
    if stack:canSwap(row[swapColumn], row[stack:columnRightOf(swapColumn)]) then
      self.targetDistance = distance
      self.targetRow = rowIndex
      self.targetColumn = swapColumn
    end
  end
end

-- Three panels of a color in a row, left to right: the outer ones move towards the middle one, a column per swap,
-- until they form a run.
---@param rowIndex integer
---@param first integer
---@param second integer
---@param third integer
function SimpleCpu:considerGather(rowIndex, first, second, third)
  local stack = self.stack
  if neighbour(stack, first, 1) ~= second then
    self:considerSwap(rowIndex, first)
  end
  local leftOfThird = neighbour(stack, third, -1)
  if leftOfThird ~= second then
    self:considerSwap(rowIndex, leftOfThird)
  end
end

-- Looks for a panel of color that slides along the row into destination, coming from the side step points to.
---@param rowIndex integer
---@param destination integer
---@param step integer -1 when the panel comes from the left, 1 from the right
---@param color integer
function SimpleCpu:considerSlide(rowIndex, destination, step, color)
  local stack = self.stack
  local row = stack.panels[rowIndex]
  local current = destination
  for _ = 1, MAX_SLIDE do
    -- the sliding panel passes through current, so it has to rest there and current's panel has to move aside
    if not isSupported(stack, rowIndex, current) or not isSlidable(row[current]) then
      return
    end
    local source = neighbour(stack, current, step)
    if not source or not isSlidable(row[source]) then
      return
    elseif row[source].color == color then
      self:considerSwap(rowIndex, step < 0 and source or current)
      return
    end
    current = source
  end
end

-- a panel of color slid into rowIndex, column from either side, unless one is there already
---@param rowIndex integer
---@param column integer
---@param color integer
function SimpleCpu:considerSlidesInto(rowIndex, column, color)
  if matchableColor(self.stack.panels[rowIndex][column]) ~= color then
    self:considerSlide(rowIndex, column, -1, color)
    self:considerSlide(rowIndex, column, 1, color)
  end
end

-- picks the swap closest to the cursor that brings three panels of a color closer to a match, targetRow 0 if none
function SimpleCpu:findTarget()
  local stack = self.stack
  local panels = stack.panels
  self.targetDistance = math.huge
  self.targetRow = 0
  self.targetColumn = 0

  for rowIndex = 1, stack.top_cur_row do
    local row = panels[rowIndex]
    for column = 1, stack.width do
      local color = matchableColor(row[column])
      if color ~= 0 and isSlidable(row[column]) then
        -- the next two panels of its color further right, if the row lets them slide together
        local second = 0
        local current = column
        for _ = 2, MAX_SPAN do
          current = neighbour(stack, current, 1)
          if not current or not isSlidable(row[current]) or not isSupported(stack, rowIndex, current) then
            break
          elseif row[current].color == color then
            if second == 0 then
              second = current
            else
              self:considerGather(rowIndex, column, second, current)
              break
            end
          end
        end
      end

      -- the panels above and below: a panel of their color slid in here would stack three of it
      local below = rowIndex > 1 and matchableColor(panels[rowIndex - 1][column]) or 0
      local above = rowIndex < stack.height and matchableColor(panels[rowIndex + 1][column]) or 0
      if below ~= 0 and rowIndex > 2 and matchableColor(panels[rowIndex - 2][column]) == below then
        self:considerSlidesInto(rowIndex, column, below)
      end
      if above ~= 0 and rowIndex + 2 <= stack.height and matchableColor(panels[rowIndex + 2][column]) == above then
        self:considerSlidesInto(rowIndex, column, above)
      end
      if below ~= 0 and above == below then
        self:considerSlidesInto(rowIndex, column, below)
      end
    end
  end
end

-- the input that brings the cursor one step closer to the target, or swaps once it is there
---@return string
function SimpleCpu:stepTowardsTarget()
  local stack = self.stack
  local direction
  if stack.cur_row < self.targetRow then
    direction = "up"
  elseif stack.cur_row > self.targetRow then
    direction = "down"
  elseif stack.cur_col ~= self.targetColumn then
    if stack.cylinder then
      local stepsRight = (self.targetColumn - stack.cur_col) % stack.width
      direction = stepsRight <= stack.width / 2 and "right" or "left"
    else
      direction = self.targetColumn > stack.cur_col and "right" or "left"
    end
  else
    return SWAP
  end

  -- Panel Attack repeats a held direction only after a delay, so pressing it again needs a released frame first
  if stack.cursorDirection == direction then
    return IDLE
  end
  return INPUT_FOR_DIRECTION[direction]
end

---@return string
function SimpleCpu:getInput()
  local stack = self.stack
  if stack.do_countdown or stack.clock < self.nextActionClock then
    return IDLE
  end
  -- presses during a turn of the tower are dropped, and a swap would cut the turn short
  if stack.rotationTimer > 0 then
    return IDLE
  end

  -- looking again before every action keeps up with rises, falls and the opponent's garbage
  self:findTarget()
  if self.targetRow == 0 then
    return IDLE
  end

  local input = self:stepTowardsTarget()
  if input ~= IDLE then
    self.nextActionClock = stack.clock + self.framesPerAction
    if input == SWAP then
      self.lastSwapRow = self.targetRow
      self.lastSwapColumn = self.targetColumn
    end
  end
  return input
end

ComputerPlayer.register("SimpleCpu", SimpleCpu)

return SimpleCpu

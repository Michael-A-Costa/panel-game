local class = require("common.lib.class")
local consts = require("common.engine.consts")
table.new = require("table.new")

-- Read-only view of a Panel Attack stack as Pokémon Puzzle League's CPU sees its well (AI-SPEC §1.3, §7.2, §7.3).
-- Everything is in PPL's 0-based coordinates: rows 0 (bottom) to 11, columns 0 to 5.
-- On the 3D tower the columns are PPL's array columns, which are view columns: the cursor pair sits on 4 and 5 and
-- the window the CPU plans in is 0..5 (SPEC §9). All 18 view columns are kept so reads outside the window see the
-- real tower, as PPL's do (AI-SPEC §5); column -1 wraps to column 17 of the same row, where PPL's array read lands
-- on the row below.
-- refresh() rewrites the preallocated arrays in place; nothing here writes to the stack.

local ROWS = 12
local CURSOR_VIEW_COLUMN = consts.CYLINDER_CURSOR_VIEW_COLUMN

---@class PplBoard
---@field stack Stack the stack being read; never written
---@field cylinder boolean if the stack is the 3D tower
---@field width integer stored columns: 6 in 2D, the 18 view columns on the tower
---@field types integer[] PPL block type per cell, flat: index row * width + column + 1
---@field states integer[] PPL block state per cell, same layout
---@field faceFrames integer a matched panel flashes (PPL state 7) while its timer is above this
---@field cursorX integer cursor.x: the cursor's left cell; always 4 on the tower
---@field cursorY integer cursor.y
---@field curColumn integer the stack's cur_col when refreshed, for view and board column conversion
---@field oldChain integer well.old_chain: 0 without a chain, -(n - 1) during a xn chain
---@field alert boolean well.alert: the stack is close to the top
---@field death boolean well.state.death: topped out with no stop or shake time left
---@field raise boolean well.raise > 0: a manual raise is running
---@field swapping boolean cursor.delay ~= 0: a swap is queued or animating
---@field cursorState integer cursor.state: 0 calm, 1 panels active, 2 garbage turning into panels, 4 garbage shake
---@field waiting integer cursor.waiting ~= 0: panels are still falling or hovering
---@field fieldActive boolean CheckFieldActive: some cell is not idle
---@field garbageRow integer lowest row >= 1 with garbage in column 2 or 3, -1 if none (what AISetGarbage stores)
---@field clock integer the stack's clock, PPL's gCounter
---@overload fun(stack: Stack): PplBoard
local PplBoard = class(
---@param self PplBoard
---@param stack Stack
function(self, stack)
  self.stack = stack
  self.cylinder = stack.cylinder
  self.width = stack.width
  self.types = table.new(ROWS * self.width, 0)
  self.states = table.new(ROWS * self.width, 0)
  for i = 1, ROWS * self.width do
    self.types[i] = 0
    self.states[i] = 0
  end
  self.faceFrames = stack.levelData.frameConstants.FACE
  self:refresh()
end)

PplBoard.ROWS = ROWS

-- block types (AI-SPEC §1.3, §7.3)
PplBoard.EMPTY = 0
-- 1..6 are Panel Attack's colours 1..6
PplBoard.SHOCK = 7 -- PA's shock panel, PPL's "!" panel
PplBoard.SQUARE = 8 -- PA's colour 7 (squares): no PPL counterpart, a colour of its own
-- types 1..COLOR_TYPES match. Where PPL tests `type < 8` or loops `type = 1, 7`, use COLOR_TYPES instead
PplBoard.COLOR_TYPES = 8
PplBoard.GARBAGE = 9
PplBoard.OTHER = 10 -- colorless panels: never match, like PPL's types 8, 10 and 12

-- block states
PplBoard.IDLE = 0
PplBoard.FALLING = 1
PplBoard.SWAPPING = 2
PplBoard.HOVERING = 5
PplBoard.HOVERING_CHAIN = 6
PplBoard.FLASHING = 7
PplBoard.POPPING = 8
PplBoard.GARBAGE_TURNING = 9

local EMPTY = PplBoard.EMPTY
local GARBAGE = PplBoard.GARBAGE
local IDLE = PplBoard.IDLE
local FALLING = PplBoard.FALLING
local SWAPPING = PplBoard.SWAPPING
local HOVERING = PplBoard.HOVERING
local HOVERING_CHAIN = PplBoard.HOVERING_CHAIN
local FLASHING = PplBoard.FLASHING
local POPPING = PplBoard.POPPING
local GARBAGE_TURNING = PplBoard.GARBAGE_TURNING

local TYPE_OF_COLOR = {[0] = EMPTY, 1, 2, 3, 4, 5, 6, PplBoard.SQUARE, PplBoard.SHOCK, PplBoard.OTHER}

-- "landing" panels can be swapped and matched in PA, so they count as resting
local STATE_OF_PANEL_STATE = {
  normal = IDLE,
  landing = IDLE,
  dimmed = IDLE,
  dead = IDLE,
  falling = FALLING,
  swapping = SWAPPING,
  hovering = HOVERING,
  popping = POPPING,
  popped = POPPING,
}

---@param panel Panel
---@param faceFrames integer
---@return integer
local function stateOf(panel, faceFrames)
  local state = panel.state
  if state == "matched" then
    if panel.isGarbage then
      return GARBAGE_TURNING
    elseif panel.timer > faceFrames then
      return FLASHING
    else
      return POPPING
    end
  elseif state == "hovering" and panel.chaining then
    return HOVERING_CHAIN
  end
  return STATE_OF_PANEL_STATE[state] or IDLE
end

-- Reads the stack into the arrays and the status fields. Called once per CPU frame before planning.
function PplBoard:refresh()
  local stack = self.stack
  local width = self.width
  local types = self.types
  local states = self.states
  local panels = stack.panels
  local cylinder = self.cylinder
  local curColumn = stack.cur_col
  local faceFrames = self.faceFrames

  self.curColumn = curColumn
  self.cursorY = stack.cur_row - 1
  if cylinder then
    self.cursorX = CURSOR_VIEW_COLUMN
  else
    self.cursorX = curColumn - 1
  end
  self.clock = stack.clock
  self.raise = stack.manual_raise == true
  self.swapping = stack:swapQueued() or stack.swappingPanelCount > 0
  if stack.chain_counter == 0 then
    self.oldChain = 0
  else
    self.oldChain = 1 - stack.chain_counter
  end

  local garbageRow = -1
  local alert = false
  local fieldActive = false
  local panelsActive = false
  local panelsSettling = false
  local garbageTurning = false
  local toppedOut = false

  for row = 0, ROWS - 1 do
    local panelRow = panels[row + 1]
    local base = row * width + 1
    for column = 0, width - 1 do
      local boardColumn
      if cylinder then
        boardColumn = (curColumn - 1 + column - CURSOR_VIEW_COLUMN) % width + 1
      else
        boardColumn = column + 1
      end
      local panel = panelRow[boardColumn]
      local blockType
      if panel.isGarbage then
        blockType = GARBAGE
      else
        blockType = TYPE_OF_COLOR[panel.color] or PplBoard.OTHER
      end
      local state = stateOf(panel, faceFrames)
      types[base + column] = blockType
      states[base + column] = state

      if state ~= IDLE then
        fieldActive = true
        if state == GARBAGE_TURNING then
          garbageTurning = true
        elseif state ~= SWAPPING then
          panelsActive = true
          if state == FALLING or state == HOVERING or state == HOVERING_CHAIN then
            panelsSettling = true
          end
        end
      end
      if blockType == GARBAGE then
        if row >= 10 then
          alert = true
        end
        if garbageRow == -1 and row >= 1 and (column == 2 or column == 3) then
          garbageRow = row
        end
        if row == ROWS - 1 and state ~= FALLING then
          toppedOut = true
        end
      elseif blockType ~= EMPTY then
        if row >= 9 then
          alert = true
        end
        if row == ROWS - 1 then
          toppedOut = true
        end
      end
    end
  end

  self.garbageRow = garbageRow
  self.alert = alert
  self.fieldActive = fieldActive
  self.death = toppedOut and stack.stop_time == 0 and stack.pre_stop_time == 0 and stack.shake_time == 0
  if garbageTurning then
    self.cursorState = 2
  elseif stack.shake_time > 0 then
    self.cursorState = 4
  elseif panelsActive then
    self.cursorState = 1
  else
    self.cursorState = 0
  end
  self.waiting = panelsSettling and 1 or 0
end

-- Block type at (row, column). Rows outside 0..11 read as empty. In 2D so do columns outside 0..5; on the tower
-- they wrap around the ring like the real panels PPL reads there.
---@param row integer
---@param column integer
---@return integer
function PplBoard:type(row, column)
  if row < 0 or row >= ROWS then
    return EMPTY
  end
  local width = self.width
  if column < 0 or column >= width then
    if not self.cylinder then
      return EMPTY
    end
    column = column % width
  end
  return self.types[row * width + column + 1]
end

-- Block state at (row, column); out of range reads as idle, see type().
---@param row integer
---@param column integer
---@return integer
function PplBoard:state(row, column)
  if row < 0 or row >= ROWS then
    return IDLE
  end
  local width = self.width
  if column < 0 or column >= width then
    if not self.cylinder then
      return IDLE
    end
    column = column % width
  end
  return self.states[row * width + column + 1]
end

-- The spec's isIdle(c, r, T): a resting panel of type blockType at (row, column). Note the (row, column) order.
---@param row integer
---@param column integer
---@param blockType integer
---@return boolean
function PplBoard:isIdle(row, column, blockType)
  return self:type(row, column) == blockType and self:state(row, column) == IDLE
end

-- if blockType is a panel that can match (PPL's 1..7 plus squares)
---@param blockType integer
---@return boolean
function PplBoard.isColor(blockType)
  return blockType >= 1 and blockType <= PplBoard.COLOR_TYPES
end

-- A column offset taken the short way round the ring: -9..8.
---@param board PplBoard
---@param offset integer
---@return integer
local function ringOffset(board, offset)
  return (offset + 9) % board.width - 9
end

-- View column (0-based, as planners use) to the 0-based board column under it now; the same column in 2D.
-- Queued commands store board columns so a plan survives the tower turning (PLAN "Decisions taken").
---@param viewColumn integer
---@return integer
function PplBoard:toBoardColumn(viewColumn)
  if not self.cylinder then
    return viewColumn
  end
  return (self.curColumn - 1 + viewColumn - CURSOR_VIEW_COLUMN) % self.width
end

-- Board column (0-based) to the view column it is in now, taking the short way round the ring (-5..12).
---@param boardColumn integer
---@return integer
function PplBoard:toViewColumn(boardColumn)
  if not self.cylinder then
    return boardColumn
  end
  return CURSOR_VIEW_COLUMN + ringOffset(self, boardColumn - (self.curColumn - 1))
end

-- Signed column distance from board column a to board column b, the short way round on the tower.
---@param a integer
---@param b integer
---@return integer
function PplBoard:columnDelta(a, b)
  if not self.cylinder then
    return b - a
  end
  return ringOffset(self, b - a)
end

return PplBoard

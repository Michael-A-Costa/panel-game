local KeyDataEncoding = require("common.data.KeyDataEncoding")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestingUtils = require("common.tests.engine.CylinderTestingUtils")

local idle = KeyDataEncoding.idle

-- the view column mapping of Stack.lua, spelled out here so the tests check it too
---@param curCol integer
---@param viewColumn integer
---@return integer
local function boardColumnOfView(curCol, viewColumn)
  return ((curCol - 1) + (viewColumn - 4)) % 18 + 1
end

---@param stack Stack
---@param garbageId integer
---@return Panel[]
local function cellsOf(stack, garbageId)
  local cells = {}
  for row = 1, #stack.panels do
    for column = 1, stack.width do
      local panel = stack.panels[row][column]
      if panel.isGarbage and panel.garbageId == garbageId then
        cells[#cells + 1] = panel
      end
    end
  end
  return cells
end

-- a block wrapping the seam falls as one piece and lands on whatever holds up any of its columns
local function wrappedBlockFallsAndLandsTest()
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  CylinderTestingUtils.setColors(stack, 1, {[2] = 1})
  stack:receiveConfirmedInput(string.rep(idle, 40))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack:dropGarbage(6, 1, false, 16)
  ---@diagnostic disable-next-line: invisible
  local garbageId = stack.garbageCreatedCount
  local cells = cellsOf(stack, garbageId)
  assertEqual(#cells, 6)
  local xOffsets = {[16] = 0, [17] = 1, [18] = 2, [1] = 3, [2] = 4, [3] = 5}
  for _, cell in ipairs(cells) do
    assertEqual(cell.x_offset, xOffsets[cell.column], "x_offset in column " .. cell.column)
  end

  for clock = 3, 30 do
    StackReplayTestingUtils:simulateMatchUntil(match, clock)
    cells = cellsOf(stack, garbageId)
    assertEqual(#cells, 6, "cells on frame " .. clock)
    for _, cell in ipairs(cells) do
      assertEqual(cell.row, cells[1].row, "row on frame " .. clock)
      assertEqual(cell.state, cells[1].state, "state on frame " .. clock)
    end
  end
  assertEqual(cells[1].row, 2, "landed on the panel in column 2")
  assertEqual(cells[1].state, "normal")
  StackReplayTestingUtils:cleanup(match)
end

wrappedBlockFallsAndLandsTest()

local function fullRingFallsLandsAndClearsTest()
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  CylinderTestingUtils.setColors(stack, 1, {[9] = 3})
  stack:receiveConfirmedInput(string.rep(idle, 60))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack:dropGarbage(18, 2, false, 7)
  ---@diagnostic disable-next-line: invisible
  local garbageId = stack.garbageCreatedCount
  local cells = cellsOf(stack, garbageId)
  assertEqual(#cells, 36)
  for _, cell in ipairs(cells) do
    assertEqual(cell.x_offset, (cell.column - 7) % 18, "x_offset in column " .. cell.column)
  end

  StackReplayTestingUtils:simulateMatchUntil(match, 30)
  for _, cell in ipairs(cellsOf(stack, garbageId)) do
    assertEqual(cell.row, 2 + cell.y_offset, "landed on the panel in column 9, column " .. cell.column)
    assertEqual(cell.state, "normal")
  end

  -- a match under the ring turns its whole bottom row into panels
  CylinderTestingUtils.setColors(stack, 1, {[3] = 2, [4] = 2, [5] = 2})
  StackReplayTestingUtils:simulateMatchUntil(match, 31)
  for column = 1, 18 do
    local bottom = stack.panels[2][column]
    assertEqual(bottom.state, "matched", "bottom row, column " .. column)
    assertEqual(bottom.y_offset, -1, "bottom row, column " .. column)
    local top = stack.panels[3][column]
    assertEqual(top.color, 9, "top row, column " .. column)
    assertEqual(top.height, 1, "top row, column " .. column)
  end
  StackReplayTestingUtils:cleanup(match)
end

fullRingFallsLandsAndClearsTest()

-- Pokémon Puzzle League's garbage for the cylinder (attack3d.c): combos keep their size and rotation of drop columns
-- two view columns to the right; chains of 2 are 6 wide, 3 are 12 wide and longer ones a full ring of chain - 3 rows
local function garbagePlacementTest()
  local cases = {
    -- garbage, expected width, height, view column
    {{width = 3, height = 1}, 3, 1, 2},
    {{width = 3, height = 1}, 3, 1, 5},
    {{width = 3, height = 1}, 3, 1, 2},
    {{width = 4, height = 1}, 4, 1, 2},
    {{width = 4, height = 1}, 4, 1, 3},
    {{width = 4, height = 1}, 4, 1, 4},
    {{width = 5, height = 1}, 5, 1, 2},
    {{width = 5, height = 1}, 5, 1, 3},
    {{width = 6, height = 1}, 6, 1, 2},
    {{width = 6, height = 1, isMetal = true}, 6, 1, 2},
    {{width = 6, height = 1, isChain = true}, 6, 1, 2},
    {{width = 6, height = 2, isChain = true}, 12, 1, 17},
    {{width = 6, height = 3, isChain = true}, 18, 1, 14},
    {{width = 6, height = 4, isChain = true}, 18, 2, 14},
    {{width = 6, height = 12, isChain = true}, 18, 10, 14},
    {{width = 6, height = 20, isChain = true}, 18, 10, 14},
  }
  for _, curCol in ipairs({1, 10, 18}) do
    local match, stack = CylinderTestingUtils.createMatch()
    stack.cur_col = curCol
    for i, case in ipairs(cases) do
      local width, height, originCol = stack:getCylinderGarbagePlacement(case[1])
      local message = "case " .. i .. " with the cursor on " .. curCol
      assertEqual(width, case[2], message)
      assertEqual(height, case[3], message)
      assertEqual(originCol, boardColumnOfView(curCol, case[4]), message)
    end
    StackReplayTestingUtils:cleanup(match)
  end
end

garbagePlacementTest()

local function incomingGarbageDropsInFrontTest()
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  stack.cur_col = 10
  stack:receiveConfirmedInput(string.rep(idle, 10))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack.incomingGarbage:push({width = 6, height = 2, isChain = true, isMetal = false, frameEarned = 0, rowEarned = 1,
                              colEarned = 1})
  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  local row = stack.panels[stack.height + 1]
  local left = boardColumnOfView(10, 17)
  for i = 0, 17 do
    local column = (left - 1 + i) % 18 + 1
    assertEqual(row[column].isGarbage, i < 12, "column " .. column)
    if i < 12 then
      assertEqual(row[column].x_offset, i, "column " .. column)
    end
  end
  StackReplayTestingUtils:cleanup(match)
end

incomingGarbageDropsInFrontTest()

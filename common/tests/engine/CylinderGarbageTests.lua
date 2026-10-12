local KeyDataEncoding = require("common.data.KeyDataEncoding")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")

local idle = KeyDataEncoding.idle

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- SPEC §9: view column v is board column ((cur_col - 1) + (v - 4)) % 18 + 1; spelled out here rather than calling
-- the stack so the tests check the mapping too
---@param curCol integer
---@param viewColumn integer
---@return integer
local function boardColumnOfView(curCol, viewColumn)
  return ((curCol - 1) + (viewColumn - 4)) % 18 + 1
end

---@param stack Stack
---@param garbageId integer
---@return Panel[] the block's cells, bottom to top and left to right in board columns
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

-- a block wrapping the seam falls as one piece and lands as soon as any of its columns, wrapped ones included, is held up
local function wrappedBlockFallsAndLandsTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  -- the only panel under the block is on column 2, one of its cells past the seam
  CylinderTestUtils.setColors(stack, 1, {[2] = 1})
  stack:receiveConfirmedInput(string.rep(idle, 40))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack:dropGarbage(6, 1, false, 16)
  ---@diagnostic disable-next-line: invisible
  local garbageId = stack.garbageCreatedCount
  local cells = cellsOf(stack, garbageId)
  expect(#cells, 6, "cells of the dropped block")
  local expectedColumns = {[16] = 0, [17] = 1, [18] = 2, [1] = 3, [2] = 4, [3] = 5}
  for _, cell in ipairs(cells) do
    expect(cell.x_offset, expectedColumns[cell.column], "x_offset counts from the left edge across the seam, column "
           .. cell.column)
    expect(cell.row, stack.height + 1, "the block enters above the board")
  end

  for clock = 3, 30 do
    StackReplayTestingUtils:simulateMatchUntil(match, clock)
    cells = cellsOf(stack, garbageId)
    expect(#cells, 6, "the block stays whole on frame " .. clock)
    for _, cell in ipairs(cells) do
      expect(cell.row, cells[1].row, "all cells fall together on frame " .. clock)
      expect(cell.state, cells[1].state, "all cells share a state on frame " .. clock)
    end
  end

  expect(cells[1].row, 2, "the block landed on the panel under its wrapped part")
  expect(cells[1].state, "normal", "and rests there")
  StackReplayTestingUtils:cleanup(match)
end

wrappedBlockFallsAndLandsTest()

local function fullRingFallsLandsAndClearsTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  CylinderTestUtils.setColors(stack, 1, {[9] = 3})
  stack:receiveConfirmedInput(string.rep(idle, 60))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack:dropGarbage(18, 2, false, 7)
  ---@diagnostic disable-next-line: invisible
  local garbageId = stack.garbageCreatedCount
  local cells = cellsOf(stack, garbageId)
  expect(#cells, 36, "cells of a two row full ring")
  for _, cell in ipairs(cells) do
    expect(cell.width, 18, "width of a full ring")
    expect(cell.x_offset, (cell.column - 7) % 18, "x_offset of column " .. cell.column)
  end

  StackReplayTestingUtils:simulateMatchUntil(match, 30)
  cells = cellsOf(stack, garbageId)
  for _, cell in ipairs(cells) do
    expect(cell.row, 2 + cell.y_offset, "the ring landed on the single panel under it, column " .. cell.column)
    expect(cell.state, "normal", "landed state")
  end

  -- a match under the ring hits all of it: the bottom row turns into panels around the whole ring
  CylinderTestUtils.setColors(stack, 1, {[3] = 2, [4] = 2, [5] = 2})
  StackReplayTestingUtils:simulateMatchUntil(match, 31)
  for column = 1, 18 do
    local bottom = stack.panels[2][column]
    expect(bottom.state, "matched", "bottom row of the ring is hit at column " .. column)
    expect(bottom.y_offset, -1, "and set to turn into a panel at column " .. column)
    assert(bottom.color >= 1 and bottom.color <= 8, "it got a panel color at column " .. column)
    local top = stack.panels[3][column]
    expect(top.height, 1, "the row above is what is left of the ring at column " .. column)
    expect(top.color, 9, "and still garbage at column " .. column)
  end
  StackReplayTestingUtils:cleanup(match)
end

fullRingFallsLandsAndClearsTest()

-- SPEC §4 / attack3d.c: the receiving tower reshapes and places incoming garbage relative to its cursor
local function garbageShapesTest()
  for _, curCol in ipairs({1, 10, 18}) do
    local match, stack = CylinderTestUtils.createMatch()
    stack.cur_col = curCol

    local function check(garbage, width, height, viewColumn, what)
      local actualWidth, actualHeight, originCol = stack:getCylinderGarbagePlacement(garbage)
      local where = what .. " with the cursor on column " .. curCol
      expect(actualWidth, width, "width of " .. where)
      expect(actualHeight, height, "height of " .. where)
      expect(originCol, boardColumnOfView(curCol, viewColumn), "left edge of " .. where)
    end

    -- combos keep their 2D size and rotate through the 2D drop columns, two view columns to the right
    check({width = 3, height = 1}, 3, 1, 2, "the first 3 wide combo")
    check({width = 3, height = 1}, 3, 1, 5, "the second 3 wide combo")
    check({width = 3, height = 1}, 3, 1, 2, "the third 3 wide combo")
    check({width = 4, height = 1}, 4, 1, 2, "the first 4 wide combo")
    check({width = 4, height = 1}, 4, 1, 3, "the second 4 wide combo")
    check({width = 4, height = 1}, 4, 1, 4, "the third 4 wide combo")
    check({width = 5, height = 1}, 5, 1, 2, "the first 5 wide combo")
    check({width = 5, height = 1}, 5, 1, 3, "the second 5 wide combo")
    check({width = 6, height = 1}, 6, 1, 2, "a 6 wide combo")
    check({width = 6, height = 1, isMetal = true}, 6, 1, 2, "shock garbage")

    -- chains: x2 6 wide, x3 12 wide from view column 17, x4 and up a full ring of chain - 3 rows, at most 10
    check({width = 6, height = 1, isChain = true}, 6, 1, 2, "a x2 chain")
    check({width = 6, height = 2, isChain = true}, 12, 1, 17, "a x3 chain")
    check({width = 6, height = 3, isChain = true}, 18, 1, 14, "a x4 chain")
    check({width = 6, height = 4, isChain = true}, 18, 2, 14, "a x5 chain")
    check({width = 6, height = 12, isChain = true}, 18, 10, 14, "a x13 chain")
    check({width = 6, height = 20, isChain = true}, 18, 10, 14, "a x21 chain")
    StackReplayTestingUtils:cleanup(match)
  end
end

garbageShapesTest()

-- garbage from the incoming queue enters the board in front of wherever the cursor is when it drops
local function incomingGarbageDropsInFrontTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  stack.cur_col = 10
  stack:receiveConfirmedInput(string.rep(idle, 10))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)

  stack.incomingGarbage:push({width = 6, height = 2, isChain = true, isMetal = false, frameEarned = 0, rowEarned = 1,
                              colEarned = 1})
  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  local row = stack.panels[stack.height + 1]
  assert(row, "the x3 chain entered the board")
  local left = boardColumnOfView(10, 17)
  for i = 0, 17 do
    local column = (left - 1 + i) % 18 + 1
    if i < 12 then
      assert(row[column].isGarbage, "column " .. column .. " is part of the 12 wide block")
      expect(row[column].x_offset, i, "x_offset at column " .. column)
    else
      assert(not row[column].isGarbage, "column " .. column .. " is behind the tower, outside the block")
    end
  end
  StackReplayTestingUtils:cleanup(match)
end

incomingGarbageDropsInFrontTest()

local KeyDataEncoding = require("common.data.KeyDataEncoding")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestingUtils = require("common.tests.engine.CylinderTestingUtils")

-- The board topology answers every "which column is next to which" question for both shapes of board, so that generic
-- code like swapping and matching doesn't have to know which one it runs on.

local function flatBoardTest()
  local match, stack = CylinderTestingUtils.createMatch({flat = true})
  assertEqual(stack.width, 6)
  assert(not stack.wraps)

  assertEqual(stack:columnLeftOf(4), 3)
  assertEqual(stack:columnLeftOf(1), nil, "left of the left edge")
  assertEqual(stack:columnRightOf(5), 6)
  assertEqual(stack:columnRightOf(6), nil, "right of the right edge")
  assertEqual(stack:wrapColumn(7), 7, "a flat board doesn't wrap")
  assert(stack:areNeighbourColumns(2, 3) and stack:areNeighbourColumns(3, 2))
  assert(not stack:areNeighbourColumns(6, 1), "the edges are not neighbours")
  assert(not stack:areNeighbourColumns(2, 4))
  assertEqual(stack:getColumnOffset(5, 2), 3)
  assertEqual(stack:getColumnOffset(2, 4), -2, "left of the origin")

  for cursorColumn = 1, 5 do
    stack.cur_col = cursorColumn
    for column = 1, stack.width do
      assertEqual(stack:viewToBoardColumn(stack:boardToViewColumn(column)), column, "view column round trip")
    end
    assertEqual(stack:boardToViewColumn(1), 0, "the view doesn't depend on the cursor")
  end

  stack.cur_col = 1
  assertEqual(stack:getCursorColumnAfterMove(-1), 1, "the cursor stops at the left edge")
  assertEqual(stack:getCursorColumnAfterMove(1), 2)
  stack.cur_col = 5
  assertEqual(stack:getCursorColumnAfterMove(1), 5, "the cursor's right half stops at the right edge")
  local left, right = stack:getCursorSwapColumns()
  assertEqual(left, 5)
  assertEqual(right, 6)
  StackReplayTestingUtils:cleanup(match)
end

flatBoardTest()

local function wrappedBoardTest()
  local match, stack = CylinderTestingUtils.createMatch()
  assertEqual(stack.width, 18)
  assert(stack.wraps)

  assertEqual(stack:columnLeftOf(1), 18, "left of column 1")
  assertEqual(stack:columnRightOf(18), 1, "right of column 18")
  assertEqual(stack:wrapColumn(19), 1)
  assertEqual(stack:wrapColumn(0), 18)
  assert(stack:areNeighbourColumns(18, 1) and stack:areNeighbourColumns(1, 18), "across the seam")
  assert(not stack:areNeighbourColumns(18, 2))
  assertEqual(stack:getColumnOffset(2, 17), 3, "across the seam")
  assertEqual(stack:getColumnOffset(17, 2), 15, "always to the right")

  -- the cursor faces the player in view columns 4 and 5
  stack.cur_col = 1
  assertEqual(stack:viewToBoardColumn(4), 1)
  assertEqual(stack:viewToBoardColumn(0), 15)
  assertEqual(stack:boardToViewColumn(15), 0)
  for cursorColumn = 1, stack.width do
    stack.cur_col = cursorColumn
    for viewColumn = 0, stack.width - 1 do
      assertEqual(stack:boardToViewColumn(stack:viewToBoardColumn(viewColumn)), viewColumn, "view column round trip")
    end
  end

  stack.cur_col = 1
  assertEqual(stack:getCursorColumnAfterMove(-1), 18, "left from column 1")
  stack.cur_col = 18
  assertEqual(stack:getCursorColumnAfterMove(1), 1, "right from column 18")
  local left, right = stack:getCursorSwapColumns()
  assertEqual(left, 18)
  assertEqual(right, 1, "the cursor straddles the seam")
  StackReplayTestingUtils:cleanup(match)
end

wrappedBoardTest()

-- nothing in the topology is tied to the 3D mode's width: a 6 wide board that wraps has its seam between 6 and 1
local function anyWidthWrapsTest()
  local match, stack = CylinderTestingUtils.createMatch({flat = true})
  stack.wraps = true
  assertEqual(stack:columnRightOf(6), 1)
  assert(stack:areNeighbourColumns(6, 1))
  stack.cur_col = 6
  local left, right = stack:getCursorSwapColumns()
  assertEqual(left, 6)
  assertEqual(right, 1)
  assertEqual(stack:getCursorColumnAfterMove(1), 1)
  StackReplayTestingUtils:cleanup(match)
end

anyWidthWrapsTest()

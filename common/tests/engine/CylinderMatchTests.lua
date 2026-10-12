local KeyDataEncoding = require("common.data.KeyDataEncoding")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestingUtils = require("common.tests.engine.CylinderTestingUtils")

-- lays out a board and runs the frame that checks it for matches
---@param rows table<integer, table<integer, integer>> colors by row and column
---@param garbageBlocks integer[][]? one row blocks in row 1 as {left column, width}, wrapping around the seam
---@param cursorColumn integer?
---@return Match match
---@return Stack stack
local function matchBoard(rows, garbageBlocks, cursorColumn)
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  for row, colors in pairs(rows) do
    CylinderTestingUtils.setColors(stack, row, colors)
  end
  for _, block in ipairs(garbageBlocks or {}) do
    local left, width = block[1], block[2]
    -- the stack's own counter keeps the ids apart from its garbage
    ---@diagnostic disable-next-line: invisible
    stack.garbageCreatedCount = stack.garbageCreatedCount + 1
    for i = 0, width - 1 do
      local panel = stack.panels[1][stack:wrapColumn(left + i)]
      panel.isGarbage = true
      ---@diagnostic disable-next-line: invisible
      panel.garbageId = stack.garbageCreatedCount
      panel.color = 9
      panel.width = width
      panel.height = 1
      panel.x_offset = i
      panel.y_offset = 0
      panel.state = "normal"
    end
  end
  stack.cur_col = cursorColumn or 3
  stack:receiveConfirmedInput(string.rep(KeyDataEncoding.idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  return match, stack
end

---@param stack Stack
---@param row integer
---@return string columns of the matched panels in the row, ascending
local function matchedColumns(stack, row)
  local columns = {}
  for column = 1, stack.width do
    if stack.panels[row][column].state == "matched" then
      columns[#columns + 1] = column
    end
  end
  return table.concat(columns, ",")
end

local function horizontalMatchAcrossTheSeamTest()
  local match, stack = matchBoard({[1] = {[17] = 1, [18] = 1, [1] = 1, [2] = 2}})
  assertEqual(matchedColumns(stack, 1), "1,17,18")
  assertEqual(stack.panels[1][17].combo_size, 3)
  StackReplayTestingUtils:cleanup(match)

  match, stack = matchBoard({[1] = {[17] = 1, [18] = 1, [2] = 1}})
  assertEqual(matchedColumns(stack, 1), "", "a gap in column 1 breaks the run")
  StackReplayTestingUtils:cleanup(match)
end

horizontalMatchAcrossTheSeamTest()

-- a ring of a single color has no end for the search to stop at
local function ringOfOneColorTest()
  local ring = {}
  for column = 1, 18 do
    ring[column] = 4
  end
  local match, stack = matchBoard({[1] = ring})
  assertEqual(matchedColumns(stack, 1), "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18")
  assertEqual(stack.panels[1][1].combo_size, 18)
  StackReplayTestingUtils:cleanup(match)
end

ringOfOneColorTest()

-- a run pops from left to right as the player sees it, across the seam too
local function popOrderFollowsTheViewTest()
  for _, cursorColumn in ipairs({3, 18}) do
    local match, stack = matchBoard({[1] = {[17] = 2, [18] = 2, [1] = 2, [2] = 2}}, nil, cursorColumn)
    for popIndex, column in ipairs({17, 18, 1, 2}) do
      assertEqual(stack.panels[1][column].combo_index, popIndex, "column " .. column .. " with the cursor on " .. cursorColumn)
    end
    StackReplayTestingUtils:cleanup(match)
  end
end

popOrderFollowsTheViewTest()

local function garbageContactAcrossTheSeamTest()
  -- a match in columns 16-18 hits the block in columns 1-6
  local match, stack = matchBoard({[1] = {[16] = 2, [17] = 2, [18] = 2}}, {{1, 6}})
  assertEqual(matchedColumns(stack, 1), "1,2,3,4,5,6,16,17,18")
  StackReplayTestingUtils:cleanup(match)

  -- a match on top of the far end of a block in columns 16-3
  match, stack = matchBoard({[2] = {[2] = 5, [3] = 5, [4] = 5}}, {{16, 6}})
  assertEqual(matchedColumns(stack, 1), "1,2,3,16,17,18")
  StackReplayTestingUtils:cleanup(match)

  -- a block in columns 13-18 passes the hit on to a block in columns 1-3
  match, stack = matchBoard({[1] = {[10] = 1, [11] = 1, [12] = 1}}, {{13, 6}, {1, 3}})
  assertEqual(matchedColumns(stack, 1), "1,2,3,10,11,12,13,14,15,16,17,18")
  StackReplayTestingUtils:cleanup(match)

  -- but not across a gap in column 18
  match, stack = matchBoard({[1] = {[9] = 1, [10] = 1, [11] = 1}}, {{12, 6}, {1, 3}})
  assertEqual(matchedColumns(stack, 1), "9,10,11,12,13,14,15,16,17")
  StackReplayTestingUtils:cleanup(match)
end

garbageContactAcrossTheSeamTest()

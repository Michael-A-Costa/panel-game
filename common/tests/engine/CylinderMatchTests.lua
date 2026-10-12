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

-- lays out row 1 (and optionally more), runs one frame and returns the stack after checkMatches ran
---@param rows table<integer, table<integer, integer>>
---@param cursorColumn integer?
---@return Match match
---@return Stack stack
local function matchBoard(rows, cursorColumn)
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  for row, colors in pairs(rows) do
    CylinderTestUtils.setColors(stack, row, colors)
  end
  stack.cur_col = cursorColumn or 3
  stack:receiveConfirmedInput(string.rep(idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  return match, stack
end

---@param stack Stack
---@param row integer
---@return integer[] columns of the matched panels in the row, ascending
local function matchedColumns(stack, row)
  local columns = {}
  for column = 1, stack.width do
    if stack.panels[row][column].state == "matched" then
      columns[#columns + 1] = column
    end
  end
  return columns
end

local function horizontalMatchAcrossTheSeamTest()
  local match, stack = matchBoard({[1] = {[17] = 1, [18] = 1, [1] = 1, [2] = 2}})
  local columns = matchedColumns(stack, 1)
  expect(#columns, 3, "panels matched across the seam")
  expect(table.concat(columns, ","), "1,17,18", "matched columns")
  expect(stack.panels[1][2].state, "normal", "the neighbour of another colour")
  expect(stack.panels[1][17].combo_size, 3, "a 3 combo, counted once")
  StackReplayTestingUtils:cleanup(match)

  -- the same 3 in a row away from the seam, for contrast
  match, stack = matchBoard({[1] = {[5] = 1, [6] = 1, [7] = 1}})
  expect(table.concat(matchedColumns(stack, 1), ","), "5,6,7", "a run away from the seam")
  StackReplayTestingUtils:cleanup(match)

  -- panels that only look close across the seam don't match
  match, stack = matchBoard({[1] = {[17] = 1, [18] = 1, [2] = 1}})
  expect(#matchedColumns(stack, 1), 0, "a gap at column 1 breaks the run")
  StackReplayTestingUtils:cleanup(match)
end

horizontalMatchAcrossTheSeamTest()

-- a whole ring of one colour has no end to stop at; it has to match once, all 18 of it
local function fullRingOfOneColourTest()
  local ring = {}
  for column = 1, 18 do
    ring[column] = 4
  end
  local match, stack = matchBoard({[1] = ring})
  expect(#matchedColumns(stack, 1), 18, "panels matched in a full ring")
  expect(stack.panels[1][1].combo_size, 18, "combo size of a full ring")
  StackReplayTestingUtils:cleanup(match)
end

fullRingOfOneColourTest()

-- a run crossing the board's seam pops as one sweep in the order the player sees it
local function popOrderFollowsTheViewTest()
  -- with the cursor on column 3, the view starts at column 17 (view column 0)
  local match, stack = matchBoard({[1] = {[17] = 2, [18] = 2, [1] = 2, [2] = 2}}, 3)
  expect(stack.panels[1][17].combo_index, 1, "column 17 pops first")
  expect(stack.panels[1][18].combo_index, 2, "column 18 pops second")
  expect(stack.panels[1][1].combo_index, 3, "column 1 pops third")
  expect(stack.panels[1][2].combo_index, 4, "column 2 pops last")
  StackReplayTestingUtils:cleanup(match)

  -- turned elsewhere the run still pops left to right as seen from the front
  match, stack = matchBoard({[1] = {[17] = 2, [18] = 2, [1] = 2, [2] = 2}}, 18)
  expect(stack.panels[1][17].combo_index, 1, "column 17 pops first with the cursor on the seam")
  expect(stack.panels[1][2].combo_index, 4, "column 2 pops last with the cursor on the seam")
  StackReplayTestingUtils:cleanup(match)
end

popOrderFollowsTheViewTest()

local function verticalMatchesAreUnchangedTest()
  local match, stack = matchBoard({[1] = {[18] = 3}, [2] = {[18] = 3}, [3] = {[18] = 3}})
  expect(stack.panels[2][18].state, "matched", "a column matches as in 2D")
  expect(stack.panels[1][18].combo_size, 3, "combo size of the column")
  StackReplayTestingUtils:cleanup(match)
end

verticalMatchesAreUnchangedTest()

-- a landed one row block from leftColumn, wrapping around the seam if it runs past column 18
---@param stack Stack
---@param leftColumn integer
---@param width integer
---@param row integer
local function placeLandedGarbage(stack, leftColumn, width, row)
  -- use the stack's own counter so the ids don't collide with its garbage
  ---@diagnostic disable-next-line: invisible
  stack.garbageCreatedCount = stack.garbageCreatedCount + 1
  ---@diagnostic disable-next-line: invisible
  local garbageId = stack.garbageCreatedCount
  for i = 0, width - 1 do
    local panel = stack.panels[row][stack:wrapColumn(leftColumn + i)]
    panel.isGarbage = true
    panel.garbageId = garbageId
    panel.color = 9
    panel.width = width
    panel.height = 1
    panel.x_offset = i
    panel.y_offset = 0
    panel.state = "normal"
  end
end

-- matching next to garbage hits it, also when the match and the block are on different sides of the seam
local function garbageContactAcrossTheSeamTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  -- the block covers columns 1-6, the match ends on column 18 right of the seam's other side
  placeLandedGarbage(stack, 1, 6, 1)
  CylinderTestUtils.setColors(stack, 1, {[16] = 2, [17] = 2, [18] = 2})
  stack:receiveConfirmedInput(string.rep(idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  expect(stack.panels[1][18].state, "matched", "the match")
  expect(stack.panels[1][1].state, "matched", "the block left of the seam is hit by the match right of it")
  expect(stack.panels[1][6].state, "matched", "the whole block is hit")
  StackReplayTestingUtils:cleanup(match)

  -- a block wrapping the seam (columns 16-3) touched by a match from above on its far side
  match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  placeLandedGarbage(stack, 16, 6, 1)
  CylinderTestUtils.setColors(stack, 2, {[2] = 5, [3] = 5, [4] = 5})
  stack:receiveConfirmedInput(string.rep(idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  expect(stack.panels[2][3].state, "matched", "the match above")
  expect(stack.panels[1][16].state, "matched", "the wrapped block is hit from above at its far end")
  expect(stack.panels[1][3].state, "matched", "every cell of it")
  expect(stack.panels[1][4].state, "normal", "the column right of the block is not garbage")
  StackReplayTestingUtils:cleanup(match)

  -- garbage touching garbage across the seam passes the hit on
  match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  placeLandedGarbage(stack, 13, 6, 1) -- columns 13-18
  placeLandedGarbage(stack, 1, 3, 1) -- columns 1-3, touching the first block across the seam
  CylinderTestUtils.setColors(stack, 1, {[10] = 1, [11] = 1, [12] = 1})
  stack:receiveConfirmedInput(string.rep(idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  expect(stack.panels[1][13].state, "matched", "the block next to the match")
  expect(stack.panels[1][2].state, "matched", "the block touching it across the seam")
  StackReplayTestingUtils:cleanup(match)

  -- and a gap at the seam keeps the hit from passing
  match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  placeLandedGarbage(stack, 12, 6, 1) -- columns 12-17
  placeLandedGarbage(stack, 1, 3, 1)
  CylinderTestUtils.setColors(stack, 1, {[9] = 1, [10] = 1, [11] = 1})
  stack:receiveConfirmedInput(string.rep(idle, 5))
  StackReplayTestingUtils:simulateMatchUntil(match, 1)
  expect(stack.panels[1][12].state, "matched", "the block next to the match")
  expect(stack.panels[1][2].state, "normal", "the block past the empty column 18 is not touched")
  StackReplayTestingUtils:cleanup(match)
end

garbageContactAcrossTheSeamTest()

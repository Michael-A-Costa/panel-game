local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplBrain = require("common.engine.computerPlayers.PplCpu.PplBrain")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")

-- Plain matches, combos and the fallback (AI-SPEC §2.4, AIStupidMove from §2.5).
-- Each planner returns true when it queued commands (PPL's -1). Columns are view columns (PplBoard); queue with
-- brain:addCommand. The combo planners read what AIBoundaryCheck and AIComboCheck left in brain.rowCheck /
-- colCheck / totCheck / distance / bestColor (0-based colour index = type - 1, like PPL's arrays).

local EMPTY = PplBoard.EMPTY
local GARBAGE = PplBoard.GARBAGE
local COLOR_TYPES = PplBoard.COLOR_TYPES
local ROWS = PplBoard.ROWS
local NO_DISTANCE = PplBrain.NO_DISTANCE
-- AIComboX's colour index: PPL's "!" panel, Panel Attack's shock panel
local SHOCK_INDEX = PplBoard.SHOCK - 1

local PplCombos = {}

-- AIPossibleRow (lastPlan 1, ai.c:968): a horizontal 3 of one colour anywhere in row. Queues only the slide: the
-- caller makes sure the cursor is on row (UpdateAI passes cursor_y, the others queue command 1 first).
---@param board PplBoard
---@param brain PplBrain
---@param row integer
---@return boolean planned
function PplCombos.possibleRow(board, brain, row)
  if board:type(row, 2) == GARBAGE or board:type(row, 3) == GARBAGE then
    return false
  end
  for blockType = 1, COLOR_TYPES do
    local count = 0
    local first, second, third = -1, -1, -1
    for column = brain.l, brain.r do
      if board:isIdle(row, column, blockType) then
        count = count + 1
        if first < 0 then
          first = column
        elseif second < 0 then
          second = column
        elseif third < 0 then
          third = column
        end
      end
    end

    if count >= 3 then
      if second - first == 1 then
        brain:addCommand(3, third, second + 1)
      elseif third - second == 1 then
        brain:addCommand(3, first, second - 1)
      elseif board.clock % 2 == 0 then
        -- PPL picks the pair by the frame counter's parity (gCounter)
        brain:addCommand(8, first, second)
      else
        brain:addCommand(8, second, third)
      end
      return true
    end
  end
  return false
end

-- The first column in left..right of row holding a resting panel of blockType that can slide to column, -1 if none
---@param board PplBoard
---@param row integer
---@param left integer
---@param right integer
---@param blockType integer
---@param column integer
---@return integer
local function reachablePanel(board, row, left, right, blockType, column)
  for candidate = left, right do
    if board:isIdle(row, candidate, blockType) and PplHelpers.moveAcross(board, row, candidate, column) then
      return candidate
    end
  end
  return -1
end

-- AIPossibleCol (lastPlan 2, AIPossibleCol.s): a vertical 3 through one of the cursor's two cells, with a panel
-- of its colour from the row above and one from the row above that or the row below, taken from the cursor's
-- columns and one more on each side. Writes slots 0 and 1 of the colour's rowCheck / colCheck, as PPL does.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.possibleCol(board, brain)
  local cursorY = brain.cursorY
  local cursorX = brain.cursorX
  if cursorY == 0 or cursorY >= 9 then
    return false
  end
  local left, right
  if cursorX == brain.l then
    left = cursorX
    right = cursorX + 2
  elseif cursorX + 1 == brain.r then
    left = cursorX - 1
    right = cursorX + 1
  else
    left = cursorX - 1
    right = cursorX + 2
  end

  for side = 0, 1 do
    local column = cursorX + side
    local blockType = board:type(cursorY, column)
    -- PPL: the cursor cell's state is not checked, a falling or swapping panel counts too (AI-SPEC §2.4)
    if blockType ~= EMPTY and blockType <= COLOR_TYPES then
      local found = reachablePanel(board, cursorY + 1, left, right, blockType, column)
      if found ~= -1 then
        local rows = brain.rowCheck[blockType - 1]
        local columns = brain.colCheck[blockType - 1]
        rows[0] = cursorY + 1
        columns[0] = found
        -- two rows above, else one above and one below
        local secondRow = cursorY + 2
        found = reachablePanel(board, secondRow, left, right, blockType, column)
        if found == -1 then
          secondRow = cursorY - 1
          found = reachablePanel(board, secondRow, left, right, blockType, column)
        end
        if found ~= -1 then
          rows[1] = secondRow
          columns[1] = found
          local firstColumn = columns[0]
          if firstColumn == column then
            brain:addCommand(1, secondRow)
            brain:addCommand(4, found, column)
          elseif found == column then
            brain:addCommand(1, rows[0])
            brain:addCommand(4, firstColumn, column)
          elseif PplHelpers.moveAcross(board, cursorY, column, firstColumn) then
            -- the cursor's panel goes under the upper one instead (the cursor is on its row already)
            brain:addCommand(3, column, firstColumn)
            brain:addCommand(1, secondRow)
            brain:addCommand(4, found, firstColumn)
          else
            brain:addCommand(1, rows[0])
            brain:addCommand(4, firstColumn, column)
            brain:addCommand(1, secondRow)
            brain:addCommand(4, found, column)
          end
          return true
        end
      end
    end
  end
  return false
end

-- Columns the cursor moves to cover column with one of its cells (AIDistance's horizontal part)
---@param brain PplBrain
---@param column integer
---@return integer
local function sideways(brain, column)
  local cursorX = brain.cursorX
  if column < cursorX then
    return cursorX - column
  elseif cursorX < column then
    return column - (cursorX + 1)
  end
  return 0
end

-- Copies count rows of a colour's list, from entry first on, into brain.sortArray and sorts them by AISortRows
-- from the cursor row. brain.sortArray[0..count-1] then holds indices 0..count-1 into that copy.
---@param brain PplBrain
---@param colorIndex integer
---@param first integer
---@param count integer
---@return integer[] order 0-based
local function sortFromCursor(brain, colorIndex, first, count)
  local order = brain.sortArray
  local rows = brain.rowCheck[colorIndex]
  for i = 0, count - 1 do
    order[i] = rows[first + i]
  end
  PplHelpers.sortRows(brain, brain.cursorY, count, order)
  return order
end

-- AIComboCheck (ai.c:1039): after AIBoundaryCheck, the cursor distance of every colour with 3 or more panels in
-- consecutive rows, 18 for those that can't all slide to the column of the one visited last; the nearest colour
-- goes into brain.bestColor (PPL's AIdistance[7]).
---@param board PplBoard
---@param brain PplBrain
function PplCombos.comboCheck(board, brain)
  local cursorY = brain.cursorY
  local totCheck = brain.totCheck
  local distance = brain.distance
  for colorIndex = 0, COLOR_TYPES - 1 do
    local total = totCheck[colorIndex]
    if total >= 3 then
      local rows = brain.rowCheck[colorIndex]
      local columns = brain.colCheck[colorIndex]
      local lastRow = rows[total - 1]
      local firstRow = rows[0]
      if cursorY >= lastRow then
        distance[colorIndex] = math.abs(cursorY - lastRow) + sideways(brain, columns[total - 1])
      elseif firstRow >= cursorY then
        distance[colorIndex] = math.abs(cursorY - firstRow) + sideways(brain, columns[0])
      else
        -- the list spans the cursor row, so one entry is on it
        for entry = 0, total - 1 do
          if rows[entry] == cursorY then
            -- PPL: measures sideways to the cursor ROW as if it were a column (AI-SPEC §2.4, §8.3)
            distance[colorIndex] = sideways(brain, cursorY)
            break
          end
        end
      end
    end
  end

  local best = NO_DISTANCE
  for colorIndex = 0, COLOR_TYPES - 1 do
    if distance[colorIndex] ~= NO_DISTANCE then
      local total = totCheck[colorIndex]
      local rows = brain.rowCheck[colorIndex]
      local columns = brain.colCheck[colorIndex]
      local order = sortFromCursor(brain, colorIndex, 0, total)
      local target = columns[order[total - 1]]
      for i = 0, total - 1 do
        local entry = order[i]
        if not PplHelpers.moveAcross(board, rows[entry], columns[entry], target) then
          distance[colorIndex] = NO_DISTANCE
          break
        end
      end
      if distance[colorIndex] < best then
        best = distance[colorIndex]
        brain.bestColor = colorIndex
      end
    end
  end
end

-- Stacks the colour's entries in the order AISortRows gives into the column of the entry visited last; command
-- slideCode 3 slides from the planned column, 4 re-picks the nearest panel of the colour first.
---@param brain PplBrain
---@param colorIndex integer
---@param order integer[] entry indices, 0-based
---@param slideCode integer
local function stackInLastColumn(brain, colorIndex, order, slideCode)
  local rows = brain.rowCheck[colorIndex]
  local columns = brain.colCheck[colorIndex]
  local target = columns[order[2]]
  for i = 0, 2 do
    local entry = order[i]
    if columns[entry] ~= target then
      brain:addCommand(1, rows[entry])
      brain:addCommand(slideCode, columns[entry], target)
    end
  end
end

-- AICombo3a (lastPlan 5, AICombo3a.s): stacks the top three panels of the colour AIComboCheck found nearest.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.combo3a(board, brain)
  local colorIndex = brain.bestColor
  if colorIndex == NO_DISTANCE then
    return false
  end
  -- PPL: it sorts the rows of the top three entries but uses the resulting indices 0..2 on the list itself, so
  -- with 4 or 5 entries it moves the bottom three in the top three's order (AI-SPEC §2.4, §8.3)
  local order = sortFromCursor(brain, colorIndex, brain.totCheck[colorIndex] - 3, 3)
  stackInLastColumn(brain, colorIndex, order, 3)
  return true
end

-- AICombo3b (lastPlan 6, ai.c:1218): the first colour with exactly three panels, reachable or not.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.combo3b(board, brain)
  for colorIndex = 0, COLOR_TYPES - 1 do
    if brain.totCheck[colorIndex] == 3 then
      stackInLastColumn(brain, colorIndex, sortFromCursor(brain, colorIndex, 0, 3), 4)
      return true
    end
  end
  return false
end

-- AIComboX (lastPlan 9, chainLimit 0 only, ai.c:1324): AICombo3b for three shock ("!") panels only.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.comboX(board, brain)
  if brain.totCheck[SHOCK_INDEX] ~= 3 then
    return false
  end
  stackInLastColumn(brain, SHOCK_INDEX, sortFromCursor(brain, SHOCK_INDEX, 0, 3), 4)
  return true
end

-- AICombo45 (lastPlan 3 for 5, 4 for 4; character bit 0x01; ai.c:1263): the first colour with exactly size panels
-- in consecutive rows goes into one column, the bottom panel's or the next one's, whichever the cursor is nearer.
-- Entry 2, the middle of the stack, comes last so no three of them pop before the rest are in.
---@param board PplBoard
---@param brain PplBrain
---@param size integer 4 or 5
---@return boolean planned
function PplCombos.combo45(board, brain, size)
  for colorIndex = 0, COLOR_TYPES - 1 do
    if brain.totCheck[colorIndex] == size then
      local rows = brain.rowCheck[colorIndex]
      local columns = brain.colCheck[colorIndex]
      local order = sortFromCursor(brain, colorIndex, 0, size)
      local target = columns[1]
      if math.abs(brain.cursorX + 1 - columns[1]) >= math.abs(brain.cursorX - columns[0]) then
        target = columns[0]
      end
      for i = 0, size - 1 do
        local entry = order[i]
        if entry ~= 2 and columns[entry] ~= target then
          brain:addCommand(1, rows[entry])
          brain:addCommand(4, columns[entry], target)
        end
      end
      if columns[2] ~= target then
        brain:addCommand(1, rows[2])
        brain:addCommand(4, columns[2], target)
      end
      return true
    end
  end
  return false
end

-- AIStupidMove (ai.c:2386), the fallback: the lowest row with a horizontal 3; else, with garbage on the board and
-- room above it in columns 2/3, raise; else wander to a random row 0..5 (command 10 then re-centres the vision,
-- or makes one random move in 3D).
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned always true
function PplCombos.stupidMove(board, brain)
  for row = 0, ROWS - 1 do
    if PplCombos.possibleRow(board, brain, row) then
      -- the first call's command was only the test: plan again behind a move to that row
      brain:clearQueues()
      brain:addCommand(1, row)
      PplCombos.possibleRow(board, brain, row)
      return true
    end
  end

  if brain.garbageRow ~= -1 then
    local highest = ROWS - 1
    while highest > brain.garbageRow and board:type(highest, 2) == EMPTY and board:type(highest, 3) == EMPTY do
      highest = highest - 1
    end
    if highest < ROWS - 1 then
      brain:addCommand(12)
      brain:addCommand(1, brain.cursorY - 1)
      brain:addCommand(10)
      return true
    end
  end

  brain:addCommand(1, brain:random(6))
  brain:addCommand(10)
  return true
end

return PplCombos

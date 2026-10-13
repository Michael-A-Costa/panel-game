local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")

-- PPL's shared AI helpers (AI-SPEC §1.9) and board scans (§1.10). Columns are view columns, rows PPL rows.
-- PPL's -1 / 0 results are booleans here; helpers that queue commands or moves say so.

local EMPTY = PplBoard.EMPTY
local IDLE = PplBoard.IDLE
local FLASHING = PplBoard.FLASHING
local POPPING = PplBoard.POPPING
local GARBAGE = PplBoard.GARBAGE
local COLOR_TYPES = PplBoard.COLOR_TYPES
local ROWS = PplBoard.ROWS
local VERTICAL = 11
local HORIZONTAL = 22
local SORT_USED = 12

local PplHelpers = {}

PplHelpers.VERTICAL = VERTICAL
PplHelpers.HORIZONTAL = HORIZONTAL

---------------------------------------------------------------------------------------------------------------------
-- moves (§1.9)

-- AIVertMove: up (3) or down (4) moves from cursor_y to row; queues nothing when already there.
---@param brain PplBrain
---@param row integer
---@return boolean queued
function PplHelpers.vertMove(brain, row)
  local delta = row - brain.cursorY
  if delta == 0 then
    return false
  end
  local move = delta > 0 and 3 or 4
  for _ = 1, math.abs(delta) do
    brain:setMove(move)
  end
  return true
end

-- AIHoriMove: right (2) or left (1) moves until the cursor's left cell is on column.
-- In 2D column 5 means the cursor pair 4/5. On the tower there is no edge, and the clamp to column 0 already
-- happened when the command was queued (PplBrain:addCommand).
---@param board PplBoard
---@param brain PplBrain
---@param column integer
---@return boolean queued
function PplHelpers.horiMove(board, brain, column)
  local target = column
  if not board.cylinder then
    if column == 5 then
      target = 4
    else
      target = math.max(column, 0)
    end
  end
  local delta = target - brain.cursorX
  if delta == 0 then
    return false
  end
  local move = delta > 0 and 2 or 1
  for _ = 1, math.abs(delta) do
    brain:setMove(move)
  end
  return true
end

-- AIHoriMoveBlock (the "slide" in UpdateAI): moves the panel in column from to column to along the cursor row,
-- one swap per column, starting from cursor_x as it was when planned.
---@param brain PplBrain
---@param from integer
---@param to integer
---@return boolean queued
function PplHelpers.horiMoveBlock(brain, from, to)
  local start, steps, direction
  if from < to then
    -- the cursor's left cell picks the panel up and carries it right
    start = brain.cursorX
    steps = to - from - 1
    direction = 2
  elseif to < from then
    start = brain.cursorX + 1
    steps = from - to - 1
    direction = 1
  else
    return false
  end

  if start < from then
    for _ = 1, from - start do
      brain:setMove(2)
    end
  elseif from < start then
    for _ = 1, start - from do
      brain:setMove(1)
    end
  end
  brain:setMove(5)
  for _ = 1, steps do
    brain:setMove(direction)
    brain:setMove(5)
  end
  return true
end

-- One AIHoriMoveCheckCheck detour: when column of the slide path holds two panels of the slid colour above/below
-- the cursor row, knock one of them aside first (vertical moves relative to the unchanged cursor_y).
---@param brain PplBrain
---@param row integer the row of the pair panel to move
---@param backRow integer the cursor row to return to
---@param column integer
---@param aside integer where that panel goes
---@param cursorAfter integer cursor_x after the detour
local function detour(brain, row, backRow, column, aside, cursorAfter)
  PplHelpers.vertMove(brain, row)
  PplHelpers.horiMoveBlock(brain, column, aside)
  PplHelpers.vertMove(brain, backRow)
  brain.cursorX = cursorAfter
end

---@param board PplBoard
---@param row integer
---@param column integer
---@param blockType integer
---@return boolean
local function isUnpoppedType(board, row, column, blockType)
  return board:type(row, column) == blockType and board:state(row, column) ~= POPPING
end

-- AIHoriMoveCheckCheck (ai.c:497 draft, AI-SPEC §1.9): used while a chain is being set up, before a slide from
-- from to to on the cursor row. If the slid panel would make a vertical 3 with two of its colour stacked in a
-- column it crosses, it queues a detour that moves one of those two aside and returns true; the caller then speeds
-- up the whole queue. PPL's -1 / 0.
---@param board PplBoard
---@param brain PplBrain
---@param from integer
---@param to integer
---@return boolean
function PplHelpers.horiMoveCheckCheck(board, brain, from, to)
  local y = brain.cursorY
  local blockType = board:type(y, from)
  if blockType == EMPTY or blockType > COLOR_TYPES then
    return false
  end

  if from < to then
    local count = to - from
    local first = from + 1
    if y >= 2 then
      for i = 0, count - 1 do
        local column = first + i
        if isUnpoppedType(board, y - 1, column, blockType) and isUnpoppedType(board, y - 2, column, blockType) then
          -- AIVertMove measures from the unchanged cursor_y, so "to y + 2" brings the cursor back up from y - 2
          detour(brain, y - 2, y + 2, column, column - 1, column - 1)
          return true
        end
      end
    end
    if y < 10 then
      for i = 0, count - 1 do
        local column = first + i
        if isUnpoppedType(board, y + 1, column, blockType) and isUnpoppedType(board, y + 2, column, blockType) then
          detour(brain, y + 1, y - 1, column, column - 1, column - 1)
          return true
        end
      end
    end
    if y >= 1 and y <= 10 then
      for i = 0, count - 1 do
        local column = first + i
        if isUnpoppedType(board, y + 1, column, blockType) and isUnpoppedType(board, y - 1, column, blockType) then
          detour(brain, y + 1, y - 1, column, column - 1, column - 1)
          return true
        end
      end
    end
  elseif to < from then
    local count = from - to
    local first = from - 1
    if y >= 2 then
      for i = 0, count - 1 do
        local column = first - i
        if isUnpoppedType(board, y - 1, column, blockType) and isUnpoppedType(board, y - 2, column, blockType) then
          detour(brain, y - 2, y + 2, column, column + 1, column)
          return true
        end
      end
    end
    if y < 10 then
      for i = 0, count - 1 do
        local column = first - i
        if isUnpoppedType(board, y + 1, column, blockType) and isUnpoppedType(board, y + 2, column, blockType) then
          detour(brain, y + 1, y - 1, column, column + 1, column)
          return true
        end
      end
    end
    if y >= 1 and y <= 10 then
      for i = 0, count - 1 do
        local column = first - i
        if isUnpoppedType(board, y - 1, column, blockType) and isUnpoppedType(board, y + 1, column, blockType) then
          detour(brain, y + 1, y - 1, column, column + 1, column)
          return true
        end
      end
    end
  end
  return false
end

-- AIRowPack (command 8): brings the panels in pos1 and pos2 next to each other, carrying whichever is nearer.
---@param brain PplBrain
---@param pos1 integer
---@param pos2 integer
---@return boolean queued
function PplHelpers.rowPack(brain, pos1, pos2)
  local gap = pos2 - pos1
  if gap < 2 then
    return false
  end
  local left = math.abs(brain.cursorX - pos1)
  local right = math.abs(brain.cursorX - (pos2 - 1))
  local carry
  if left < right then
    -- carry pos1's panel right to pos2 - 1
    local approach = brain.cursorX < pos1 and 2 or 1
    for _ = 1, left do
      brain:setMove(approach)
    end
    carry = 2
  else
    -- carry pos2's panel left to pos1 + 1
    local approach = brain.cursorX + 1 < pos2 and 2 or 1
    for _ = 1, right do
      brain:setMove(approach)
    end
    carry = 1
  end
  brain:setMove(5)
  for _ = 1, gap - 2 do
    brain:setMove(carry)
    brain:setMove(5)
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- measures and searches (§1.9)

-- AISearchClose: if pos1 is at least as close to the cursor as pos2 (whose left neighbour the cursor would take)
---@param brain PplBrain
---@param pos1 integer
---@param pos2 integer
---@return boolean
function PplHelpers.searchClose(brain, pos1, pos2)
  return math.abs(brain.cursorX - pos1) <= math.abs(brain.cursorX - (pos2 - 1))
end

-- AIMoveAcross: can a panel slide from from to to on row? Every cell strictly between must be empty or resting,
-- with something under it so the panel doesn't drop. The end cells are not checked.
---@param board PplBoard
---@param row integer
---@param from integer
---@param to integer
---@return boolean
function PplHelpers.moveAcross(board, row, from, to)
  if from == to then
    return true
  end
  local step = from < to and 1 or -1
  for column = from + step, to - step, step do
    if board:type(row, column) ~= EMPTY and board:state(row, column) ~= IDLE then
      return false
    end
    if row ~= 0 and board:type(row - 1, column) == EMPTY then
      return false
    end
  end
  return true
end

-- AIShortestD (command 4): the resting panel on the cursor row with from's colour that is nearest to to
-- (to itself if it already has that colour, ties go left). -1 when there is none.
---@param board PplBoard
---@param brain PplBrain
---@param from integer
---@param to integer
---@return integer column
function PplHelpers.shortestDistance(board, brain, from, to)
  local row = brain.cursorY
  local blockType = board:type(row, from)
  if board:type(row, to) == blockType then
    return to
  end
  local left = -1
  for column = to - 1, brain.l, -1 do
    if board:isIdle(row, column, blockType) then
      left = column
      break
    end
  end
  local right = -1
  for column = to + 1, brain.r do
    if board:isIdle(row, column, blockType) then
      right = column
      break
    end
  end
  if left == -1 then
    return right
  elseif right == -1 then
    return left
  elseif to - left > right - to then
    return right
  else
    return left
  end
end

-- AISortRows: greedy nearest-row order. array[0..total-1] holds rows (12 = unused) and is overwritten with the
-- entry indices in visiting order, starting nearest to row; ties go to the lower index. Like PPL, callers copy
-- their rows into brain.sortArray first.
---@param brain PplBrain
---@param row integer
---@param total integer
---@param array integer[] 0-based
function PplHelpers.sortRows(brain, row, total, array)
  local index = brain.sortIndex
  local chosen = 0
  for i = 0, total - 1 do
    local best = SORT_USED
    for j = 0, total - 1 do
      local value = array[j]
      if value ~= SORT_USED then
        local distance = math.abs(value - row)
        if distance < best then
          best = distance
          chosen = j
        end
      end
    end
    -- with nothing left PPL records the previous pick again
    index[i] = chosen
    row = array[chosen]
    array[chosen] = SORT_USED
  end
  for i = 0, total - 1 do
    array[i] = index[i]
  end
end

-- AIDistance: moves the cursor needs to cover (row, column) with either of its cells
---@param brain PplBrain
---@param row integer
---@param column integer
---@return integer
function PplHelpers.distance(brain, row, column)
  local sideways = 0
  if column < brain.cursorX then
    sideways = brain.cursorX - column
  elseif column > brain.cursorX then
    sideways = column - 1 - brain.cursorX
  end
  return math.abs(brain.cursorY - row) + sideways
end

-- AIClearPosition: pushes the panel at (row, column) sideways into an empty neighbour (queues 1 and 3).
-- True when the cell is already empty or a push was queued.
---@param board PplBoard
---@param brain PplBrain
---@param row integer
---@param column integer
---@return boolean
function PplHelpers.clearPosition(board, brain, row, column)
  if board:type(row, column) == EMPTY then
    return true
  end
  local target
  if column == 0 then
    if board:type(row, 1) == EMPTY then
      target = 1
    end
  elseif column == 5 then
    if board:type(row, 4) == EMPTY then
      target = 4
    end
  elseif board:type(row, column + 1) == EMPTY then
    target = column + 1
  elseif board:type(row, column - 1) == EMPTY then
    target = column - 1
  end
  if target then
    brain:addCommand(1, row)
    brain:addCommand(3, column, target)
    return true
  end
  return false
end

-- AILowerRow: slides the panel at (row, column) towards the nearest hole in the row below so it drops a row,
-- left side first. brain.totCheck is read as column locks here (-1 = locked, AI-SPEC §1.2). Queues 1 and 3.
---@param board PplBoard
---@param brain PplBrain
---@param row integer
---@param column integer
---@return boolean queued
function PplHelpers.lowerRow(board, brain, row, column)
  local locks = brain.totCheck
  if locks[column] == -1 or row == 0 then
    return false
  end
  local below = row - 1
  for side = -1, 1, 2 do
    local last = side < 0 and 0 or 5
    for c = column + side, last, side do
      if board:type(row, c) ~= EMPTY and locks[c] == -1 then
        break
      end
      if board:type(below, c) == EMPTY then
        if locks[c] ~= -1 then
          -- next to it the panel drops at once, so the cursor waits a row lower
          if c == column + side then
            brain:addCommand(1, below)
          else
            brain:addCommand(1, row)
          end
          brain:addCommand(3, column, c)
          return true
        end
        break
      end
    end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- board scans (§1.10)

-- AISetGarbage: brain.garbageRow from the board, frozen while garbage turns into panels (cursor.state 2 or 3)
---@param board PplBoard
---@param brain PplBrain
function PplHelpers.setGarbage(board, brain)
  if board.cursorState == 2 or board.cursorState == 3 then
    return
  end
  brain.garbageRow = board.garbageRow
end

-- AIFlashCheck (AIFlashCheck.s; the ai.c draft reads the wrong row): the first run of 3+ flashing cells in rows
-- 0..7, columns 0..5, into brain.direction/where/from/to. Runs of 2 (an L or a T) are skipped; a lone flashing
-- cell ends the search.
---@param board PplBoard
---@param brain PplBrain
---@return boolean found
function PplHelpers.flashCheck(board, brain)
  local startRow = 0
  local startColumn = 0
  while true do
    local foundRow, foundColumn
    for row = startRow, 7 do
      for column = (row == startRow) and startColumn or 0, 5 do
        if board:state(row, column) == FLASHING then
          foundRow = row
          foundColumn = column
          break
        end
      end
      if foundRow then
        break
      end
    end
    if not foundRow then
      brain.direction = 0
      return false
    end

    if board:state(foundRow + 1, foundColumn) == FLASHING then
      brain.direction = VERTICAL
      brain.where = foundColumn
      brain.from = foundRow
      brain.to = foundRow + 1
      for row = foundRow + 2, ROWS - 1 do
        if board:state(row, foundColumn) ~= FLASHING then
          break
        end
        brain.to = row
      end
    elseif board:state(foundRow, foundColumn + 1) == FLASHING then
      brain.direction = HORIZONTAL
      brain.where = foundRow
      brain.from = foundColumn
      brain.to = foundColumn + 1
      for column = foundColumn + 2, 5 do
        if board:state(foundRow, column) ~= FLASHING then
          break
        end
        brain.to = column
      end
    else
      brain.direction = 0
      return false
    end

    if brain.to - brain.from >= 2 then
      return true
    end
    if brain.direction == VERTICAL then
      startRow = brain.to
      startColumn = brain.where + 1
    else
      startRow = brain.where
      startColumn = brain.to + 1
    end
  end
end

-- AIScrollCheck: per column of the vision window, the height of the unbroken stack from row 0 (up to the garbage),
-- into heights[column] when given; returns the total.
---@param board PplBoard
---@param brain PplBrain
---@param heights integer[]? 0-based by column
---@return integer total
function PplHelpers.scrollCheck(board, brain, heights)
  local limit = brain.garbageRow ~= -1 and brain.garbageRow or ROWS
  local total = 0
  for column = brain.l, brain.r do
    local height = 0
    for row = 0, limit - 1 do
      local blockType = board:type(row, column)
      -- PPL's `type < 8`: anything but garbage and colorless
      if (blockType ~= EMPTY and blockType <= COLOR_TYPES) or (blockType == EMPTY and board:state(row, column) ~= IDLE) then
        height = height + 1
      else
        break
      end
    end
    total = total + height
    if heights then
      heights[column] = height
    end
  end
  return total
end

-- AIBoundaryCheck: per colour, a resting panel and then the leftmost resting panel of that colour in each
-- following row of the vision window, as long as every row has one (3 to 5 entries make a vertical match).
-- Types above COLOR_TYPES (garbage) are skipped: PPL would index past AItotCheck (AI-SPEC §1.10).
---@param board PplBoard
---@param brain PplBrain
function PplHelpers.boundaryCheck(board, brain)
  local limit = brain.garbageRow ~= -1 and (brain.garbageRow - 1) or brain.t
  if limit - brain.b < 2 then
    return
  end
  local rowCheck = brain.rowCheck
  local colCheck = brain.colCheck
  local totCheck = brain.totCheck
  for row = brain.b, limit do
    for column = brain.l, brain.r do
      local blockType = board:type(row, column)
      if blockType ~= EMPTY and blockType <= COLOR_TYPES and board:state(row, column) == IDLE then
        local colorIndex = blockType - 1
        if totCheck[colorIndex] < 3 then
          local rows = rowCheck[colorIndex]
          local columns = colCheck[colorIndex]
          rows[0] = row
          columns[0] = column
          totCheck[colorIndex] = 1
          for nextRow = row + 1, limit do
            local hit = false
            for nextColumn = brain.l, brain.r do
              if board:isIdle(nextRow, nextColumn, blockType) then
                rows[totCheck[colorIndex]] = nextRow
                columns[totCheck[colorIndex]] = nextColumn
                totCheck[colorIndex] = totCheck[colorIndex] + 1
                hit = true
                break
              end
            end
            if not hit or totCheck[colorIndex] > 4 then
              break
            end
          end
        end
      end
    end
  end
end

-- AIVisionCheck: clears the scratch tables and distances, then AIBoundaryCheck. UpdateAI inlines it after
-- AIChangeVision.
---@param board PplBoard
---@param brain PplBrain
function PplHelpers.visionCheck(board, brain)
  brain:clearScratch()
  brain:resetDistances()
  PplHelpers.boundaryCheck(board, brain)
end

PplHelpers.COLOR_TYPES = COLOR_TYPES
PplHelpers.GARBAGE = GARBAGE

return PplHelpers

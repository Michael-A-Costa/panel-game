local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplBrain = require("common.engine.computerPlayers.PplCpu.PplBrain")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplCombos = require("common.engine.computerPlayers.PplCpu.PplCombos")

-- Garbage and stack height planners (AI-SPEC §2.3, §2.5 AIVolumeCheck): clear the lowest garbage, chain off
-- garbage while it turns into panels, raise a low stack and flatten a tall one.
-- Each returns true when it queued commands (PPL's -1). Columns are view columns (PplBoard); queue with
-- brain:addCommand. AIStupidMove, the last fallback of §2.5, is in PplCombos (AI-SPEC §7.1).
-- AIChainGarbage1, AIChainPack and AILowerRow use brain.totCheck (PPL's AItotCheck) per column: 0 nothing,
-- a block type to chain onto, -1 locked (AI-SPEC §1.2).

local EMPTY = PplBoard.EMPTY
local SHOCK = PplBoard.SHOCK
local GARBAGE = PplBoard.GARBAGE
local IDLE = PplBoard.IDLE
local FLASHING = PplBoard.FLASHING
local COLOR_TYPES = PplBoard.COLOR_TYPES
local ROWS = PplBoard.ROWS
local COLOR_SLOTS = PplBrain.COLOR_SLOTS
local LOCKED = -1

-- character bits (AI-SPEC §3.2)
local RAISE = 0x02
local RELAXED_GARBAGE_CHAINS = 0x40
local FOURTH_PANEL = 0x80

-- AIVolumeCheck's raise thresholds (ai.c:1548-1575)
local RAISE_PANEL_LIMIT = 42
local RAISE_HEIGHT_LIMIT = 9
local GARBAGE_RAISE_LIMIT = 8

-- AIVolumeCheck's column heights (sp10 in PPL); rewritten by every call
local heights = {[0] = 0, 0, 0, 0, 0, 0}

local PplGarbage = {}

-- AIChainPack's colour loops run over PPL's six plain colours and skip the "!" panel; PA's squares are plain too
---@param blockType integer
---@return boolean
local function isPlainColor(blockType)
  return blockType ~= SHOCK
end

-- AIClearGarbage (lastPlan 0x20, AIClearGarbage.s), AI-SPEC §2.3: a match that touches the lowest garbage. First a
-- horizontal 3 in the row right under it, else a vertical 3 in rows G-1..G-3 of a column under the garbage, built
-- from a panel in row G-1 and one panel of its colour per row below that can slide over to its column.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.clearGarbage(board, brain)
  if board.cursorState == 2 then
    return false
  end
  local garbageRow = brain.garbageRow
  local rowUnder = garbageRow - 1
  if PplCombos.possibleRow(board, brain, rowUnder) then
    -- the first call was only the test: plan again behind a move to that row
    brain:clearQueues()
    brain:addCommand(1, rowUnder)
    PplCombos.possibleRow(board, brain, rowUnder)
    return true
  end
  if garbageRow < 3 then
    return false
  end
  for column = 0, 5 do
    if board:state(rowUnder, column) == FLASHING then
      -- something under the garbage is matching already
      return false
    end
  end

  brain:clearScratch()
  local totCheck = brain.totCheck
  for column = 0, 5 do
    local blockType = board:type(rowUnder, column)
    -- PPL has no colour test here and indexes past AItotCheck for garbage (AI-SPEC §2.3 note): skipped instead
    if blockType ~= EMPTY and blockType <= COLOR_TYPES and totCheck[blockType - 1] == 0 then
      local colorIndex = blockType - 1
      local rows = brain.rowCheck[colorIndex]
      local columns = brain.colCheck[colorIndex]
      rows[0] = rowUnder
      columns[0] = column
      totCheck[colorIndex] = 1
      -- up to three rows down, as long as each one has a panel of the colour that can slide over
      for row = rowUnder - 1, rowUnder - 3, -1 do
        local found = false
        for from = 0, 5 do
          if board:isIdle(row, from, blockType) and PplHelpers.moveAcross(board, row, from, column) then
            local slot = totCheck[colorIndex]
            rows[slot] = row
            columns[slot] = from
            totCheck[colorIndex] = slot + 1
            found = true
            break
          end
        end
        if not found then
          break
        end
      end

      if totCheck[colorIndex] >= 3 then
        local order = brain.sortArray
        for i = 0, 2 do
          order[i] = rows[i]
        end
        PplHelpers.sortRows(brain, brain.cursorY, 3, order)

        -- build the 3 under the garbage: this column if the garbage covers it, else column 3 or 2, whichever it covers
        local target
        if board:type(garbageRow, column) == GARBAGE then
          target = column
        elseif board:type(garbageRow, 2) ~= GARBAGE then
          target = 3
        else
          target = 2
        end
        if brain:hasCharacter(FOURTH_PANEL) and totCheck[colorIndex] >= 4 and not board.death then
          -- a fourth panel of the colour, moved in first when it is close
          local distance = math.abs(columns[3] - target)
          if distance ~= 0 and distance < 3 then
            brain:addCommand(1, rows[3])
            brain:addCommand(4, columns[3], target)
          end
        end
        for i = 0, 2 do
          local entry = order[i]
          if columns[entry] ~= target then
            brain:addCommand(1, rows[entry])
            brain:addCommand(4, columns[entry], target)
          end
        end
        return true
      end
    end
  end
  return false
end

-- AIChainGarbage1 (lastPlan 0x1E, character bit 0x20, ai.c:2185), AI-SPEC §2.3. Runs while garbage turns into
-- panels; brain.garbageRow is frozen then, so row G holds the colours the garbage is turning into. Lines up two
-- panels of a revealed colour under it, so that the new panel makes a chain once it is free.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.chainGarbage1(board, brain)
  local garbageRow = brain.garbageRow
  if garbageRow < 2 then
    return false
  end
  -- the chain limit applies as for the chain planners (AI-SPEC §3.3)
  if brain.chainLimit < 0 then
    if brain.chainLimit >= board.oldChain then
      return false
    end
  elseif brain.chainLimit == 0 then
    if board.oldChain < -3 then
      return false
    end
  end

  local locks = brain.totCheck
  for i = 0, COLOR_SLOTS - 1 do
    locks[i] = 0
  end
  -- a revealed panel with two of its colour under it (gaps allowed) chains by itself: lock that column
  local top = 0
  for column = 5, 0, -1 do
    local blockType = board:type(garbageRow, column)
    if blockType ~= GARBAGE and blockType ~= EMPTY then
      locks[column] = blockType
      local count = 0
      for row = garbageRow - 1, 0, -1 do
        local below = board:type(row, column)
        if below ~= EMPTY then
          if below ~= blockType then
            break
          end
          count = count + 1
        end
        if count == 2 then
          locks[column] = LOCKED
          top = math.max(top, row + 1)
          break
        end
      end
    end
  end

  local rows = brain.rowCheck[0]
  local columns = brain.colCheck[0]
  for column = 5, 0, -1 do
    local blockType = locks[column]
    if blockType ~= LOCKED and blockType ~= 0 then
      -- from the top down, the first rows with a panel of the colour in this column or able to slide into it
      local found = 0
      local inColumn = 0
      for row = garbageRow - 1, 0, -1 do
        local hit = false
        for from = 0, 5 do
          if locks[from] ~= LOCKED and board:isIdle(row, from, blockType) then
            if board:type(row, column) == blockType then
              inColumn = inColumn + 1
              rows[found] = row
              columns[found] = column
              found = found + 1
              hit = true
              break
            elseif PplHelpers.moveAcross(board, row, from, column) then
              rows[found] = row
              columns[found] = from
              found = found + 1
              hit = true
              break
            end
          end
        end

        if not hit then
          if found ~= 0 then
            break
          end
        elseif found == 1 then
          if PplGarbage.chainGarbage2(board, brain, blockType, column) then
            return true
          end
          if locks[column] == LOCKED then
            break
          end
        elseif found == 2 then
          break
        end
      end

      if inColumn == 2 then
        -- both are in the column already: clear what sits between them and the garbage
        -- (AIClearPosition may queue commands even though this planner goes on, as in PPL)
        if PplHelpers.clearPosition(board, brain, rows[0] + 1, column) then
          locks[column] = LOCKED
        end
        top = math.max(top, rows[0])
      elseif found == 2 and (brain:hasCharacter(RELAXED_GARBAGE_CHAINS) or top < rows[0]) then
        local count = 0
        local last = rows[0] + 1
        for row = rows[0] + 1, garbageRow - 1 do
          if board:type(row, column) ~= EMPTY and board:state(row, column) == IDLE then
            count = count + 1
            last = row
          end
        end
        if count < 2 and (rows[0] + 1 == garbageRow or PplHelpers.clearPosition(board, brain, last, column)) then
          local row = rows[1] - 1
          if board:type(row, column) == blockType then
            -- PPL: at column 0 the move to column -1 clamps to 0, so the swap takes columns 0 and 1
            brain:addCommand(1, row)
            brain:addCommand(2, column - 1)
            brain:addCommand(9)
          end
          local order = brain.sortArray
          order[0] = rows[0]
          order[1] = rows[1]
          PplHelpers.sortRows(brain, brain.cursorY, 2, order)
          for i = 0, 1 do
            local entry = order[i]
            if columns[entry] ~= column then
              brain:addCommand(1, rows[entry])
              brain:addCommand(4, columns[entry], column)
            end
          end
          locks[column] = LOCKED
          return true
        end
      end
    end
  end
  return false
end

-- AIChainGarbage2 (ai.c:2348), called by AIChainGarbage1 with the colour below and the column, AI-SPEC §2.3: the cell
-- above the revealed panel has its colour too, so one more panel under them (the one AIChainGarbage1 found first,
-- brain.rowCheck[0][0]) makes the 3.
---@param board PplBoard
---@param brain PplBrain
---@param below integer block type
---@param column integer
---@return boolean planned
function PplGarbage.chainGarbage2(board, brain, below, column)
  local garbageRow = brain.garbageRow
  local blockType = board:type(garbageRow + 1, column)
  if blockType ~= below or blockType == GARBAGE then
    return false
  end
  local locks = brain.totCheck
  if blockType == EMPTY or locks[column] == LOCKED then
    return false
  end
  local row = brain.rowCheck[0][0]
  local from = brain.colCheck[0][0]
  if not PplHelpers.moveAcross(board, row, from, column) then
    return false
  end

  local count = 0
  for above = row + 1, garbageRow - 1 do
    if board:type(above, column) ~= EMPTY then
      count = count + 1
    end
  end
  if count < 2 and (row + 1 == garbageRow or PplHelpers.clearPosition(board, brain, row + 1, column)) then
    locks[column] = LOCKED
    if from ~= column then
      brain:addCommand(1, row)
      brain:addCommand(4, from, column)
      return true
    end
  end
  return false
end

-- AIChainPack (lastPlan 0x1F, ai.c:2078), AI-SPEC §2.3: the fallback while garbage turns into panels. Compacts the
-- stack under it so what falls can chain: fill the holes in locked columns, bring each colour into consecutive rows,
-- split pairs in a row, fill holes under a panel up and to the right. Every step drops one panel a row (AILowerRow).
-- PPL: when AIChainGarbage1 did not run this frame, the column locks are whatever an earlier planner left in
-- AItotCheck (AI-SPEC §2.3)
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.chainPack(board, brain)
  local garbageRow = brain.garbageRow
  local locks = brain.totCheck

  -- the highest first hole of the locked columns
  local top = 0
  for column = 0, 5 do
    if locks[column] == LOCKED then
      for row = 0, garbageRow - 1 do
        if board:type(row, column) == EMPTY then
          top = math.max(top, row)
          break
        end
      end
    end
  end
  if top ~= 0 then
    for row = garbageRow - 1, top, -1 do
      for column = 0, 5 do
        if board:type(row, column) ~= EMPTY and board:state(row, column) == IDLE
            and PplHelpers.lowerRow(board, brain, row, column) then
          return true
        end
      end
    end
    return false
  end

  -- per colour, from the bottom: the first panel that is not in the row right above the previous one is lowered
  for blockType = 1, COLOR_TYPES do
    if isPlainColor(blockType) then
      local last = -1
      for row = 0, garbageRow - 1 do
        for column = 0, 5 do
          if locks[column] ~= LOCKED and board:isIdle(row, column, blockType) then
            if last == -1 or last == row - 1 or not PplHelpers.lowerRow(board, brain, row, column) then
              last = row
              break
            end
            return true
          end
        end
      end
    end
  end

  -- two of a colour in one row: lower one of them
  for row = garbageRow - 1, 1, -1 do
    for blockType = 1, COLOR_TYPES do
      if isPlainColor(blockType) then
        local count = 0
        local first = 0
        for column = 0, 5 do
          if board:isIdle(row, column, blockType) then
            if count == 0 then
              first = column
            end
            count = count + 1
            if count >= 2 then
              if PplHelpers.lowerRow(board, brain, row, first) or PplHelpers.lowerRow(board, brain, row, column) then
                return true
              end
              break
            end
          end
        end
      end
    end
  end

  -- a hole with a resting panel diagonally up and to the right of it
  for row = 0, garbageRow - 2 do
    for column = 0, 4 do
      if board:type(row, column) == EMPTY and board:type(row + 1, column + 1) ~= EMPTY
          and board:state(row + 1, column + 1) == IDLE and locks[column + 1] ~= LOCKED
          and PplHelpers.lowerRow(board, brain, row + 1, column + 1) then
        return true
      end
    end
  end
  return false
end

-- The top of the tallest column anywhere on the tower, garbage included: 1 + the highest occupied row.
---@param board PplBoard
---@return integer
local function towerHeight(board)
  local height = 0
  for column = 0, board.width - 1 do
    for row = ROWS - 1, height, -1 do
      if board:type(row, column) ~= EMPTY then
        height = row + 1
        break
      end
    end
  end
  return height
end

-- AIVolumeCheck (lastPlan 0x32 / 0x33 / 0x34, ai.c:1508), AI-SPEC §2.5. skipFlatten is PPL's `exit` argument:
-- true runs only the raise logic. With character bit 0x02 a low stack is raised (command 12, PA's manual raise),
-- also under garbage that sits low; otherwise the top panel of the tallest column is pushed into a hole beside it
-- or dropped a row.
---@param board PplBoard
---@param brain PplBrain
---@param skipFlatten boolean
---@return boolean planned
function PplGarbage.volumeCheck(board, brain, skipFlatten)
  local total = PplHelpers.scrollCheck(board, brain, heights)
  local highest = heights[0]
  for column = 1, 5 do
    if heights[column] > highest then
      highest = heights[column]
    end
  end

  if brain:hasCharacter(RAISE) then
    -- A raise lifts the whole tower, but AIScrollCheck measures only the 6 columns in view (AI-SPEC §5), so PPL's
    -- logic raises the tower whenever the CPU looks at a low part of it and tops out on the other 12 columns. On the
    -- tower the tallest column decides instead (Stadium 3D is ours, like the board-column commands); 2D is unchanged.
    local raiseHeight = highest
    if board.cylinder then
      raiseHeight = math.max(highest, towerHeight(board))
    end
    if brain.garbageRow == -1 then
      local height = raiseHeight
      -- cursor.state 3 counts as a full stack (AI-SPEC §8 question 6); PA's board never reports it
      if board.cursorState == 3 then
        height = ROWS
      end
      if total < RAISE_PANEL_LIMIT and height < RAISE_HEIGHT_LIMIT then
        -- one raise, and more while the estimate stays low: PPL counts a raise as 9 panels and 2 rows, then 3 rows
        height = height + 2
        total = total + 9
        brain:addCommand(12)
        if total < RAISE_PANEL_LIMIT then
          while height < RAISE_HEIGHT_LIMIT do
            brain:addCommand(12)
            height = height + 3
          end
        end
        brain:addCommand(1, brain:random(4) + 2)
        brain:addCommand(10)
        return true
      end
    else
      -- the top of what sits in columns 2 and 3 above the garbage
      local top = ROWS - 1
      while top > brain.garbageRow and board:type(top, 2) == EMPTY and board:type(top, 3) == EMPTY do
        top = top - 1
      end
      if board.cursorState == 3 then
        top = ROWS
      end
      if raiseHeight < RAISE_HEIGHT_LIMIT and top < GARBAGE_RAISE_LIMIT then
        brain:addCommand(12)
        brain:addCommand(1, brain.cursorY - 1)
        brain:addCommand(10)
        return true
      end
    end
  end

  if skipFlatten then
    return false
  end

  -- the right end of the first run of tallest columns, and the left end of the last one
  local left = -1
  for column = 0, 5 do
    if heights[column] == highest then
      left = column
    elseif left ~= -1 then
      break
    end
  end
  local right = -1
  for column = 5, 0, -1 do
    if heights[column] == highest then
      right = column
    elseif right ~= -1 then
      break
    end
  end

  -- PPL: with every column empty this is row -1, below the board (AI-SPEC §2.5); it reads as empty here
  local row = highest - 1
  if row == brain.garbageRow then
    row = row - 1
  end
  -- the cursor's own cells first, in a random order, else the nearer end of the tallest columns
  local cursorX = brain.cursorX
  local column = -1
  if brain:random(115) % 2 == 0 then
    if board:type(row, cursorX) ~= EMPTY then
      column = cursorX
    elseif board:type(row, cursorX + 1) ~= EMPTY then
      column = cursorX + 1
    end
  else
    if board:type(row, cursorX + 1) ~= EMPTY then
      column = cursorX + 1
    elseif board:type(row, cursorX) ~= EMPTY then
      column = cursorX
    end
  end
  if column == -1 then
    if left == right or PplHelpers.searchClose(brain, left, right) then
      column = left
    else
      column = right
    end
  end

  -- at the first colour change from the top, push the lower panel sideways into a hole
  for a = row, 2, -1 do
    if board:type(a, column) ~= board:type(a - 1, column) then
      if column ~= 0 and board:type(a - 1, column - 1) == EMPTY then
        brain:addCommand(1, a - 1)
        brain:addCommand(3, column, column - 1)
        return true
      end
      if column ~= 5 and board:type(a - 1, column + 1) == EMPTY then
        brain:addCommand(1, a - 1)
        brain:addCommand(3, column, column + 1)
        return true
      end
      break
    end
  end

  -- PPL: column - 1 and column + 1 are read without an edge check (AI-SPEC §2.5): empty in 2D, the real
  -- neighbours on the tower
  if board:type(row, column - 1) ~= GARBAGE and board:type(row, column + 1) ~= GARBAGE then
    -- PPL: AILowerRow reads AItotCheck as column locks, whatever earlier planners left in it (AI-SPEC §2.5)
    if row ~= 0 and PplHelpers.lowerRow(board, brain, row, column) then
      return true
    end
  end
  return false
end

return PplGarbage

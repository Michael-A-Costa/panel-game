local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")

-- Plain matches, combos and the fallback (AI-SPEC §2.4, AIStupidMove from §2.5).
-- Each planner returns true when it queued commands (PPL's -1). Columns are view columns (PplBoard); queue with
-- brain:addCommand. The combo planners read what AIBoundaryCheck and AIComboCheck left in brain.rowCheck /
-- colCheck / totCheck / distance / bestColor (0-based colour index = type - 1, like PPL's arrays).

-- STUBS: possibleCol, comboCheck, combo3a, combo3b, comboX and combo45 still return false ("no plan").
-- Phase 2b fills them in. possibleRow and stupidMove are complete.

local EMPTY = PplBoard.EMPTY
local GARBAGE = PplBoard.GARBAGE
local COLOR_TYPES = PplBoard.COLOR_TYPES
local ROWS = PplBoard.ROWS

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

-- AIPossibleCol (lastPlan 2), AI-SPEC §2.4
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.possibleCol(board, brain)
  return false
end

-- AIComboCheck, AI-SPEC §2.4: ranks the colours AIBoundaryCheck listed into brain.distance / brain.bestColor
---@param board PplBoard
---@param brain PplBrain
function PplCombos.comboCheck(board, brain)
end

-- AICombo3a (lastPlan 5), AI-SPEC §2.4
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.combo3a(board, brain)
  return false
end

-- AICombo3b (lastPlan 6), AI-SPEC §2.4
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.combo3b(board, brain)
  return false
end

-- AIComboX (lastPlan 9, chainLimit 0 only), AI-SPEC §2.4
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplCombos.comboX(board, brain)
  return false
end

-- AICombo45 (lastPlan 3 for 5, 4 for 4; character bit 0x01), AI-SPEC §2.4
---@param board PplBoard
---@param brain PplBrain
---@param size integer 4 or 5
---@return boolean planned
function PplCombos.combo45(board, brain, size)
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

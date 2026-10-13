local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplBrain = require("common.engine.computerPlayers.PplCpu.PplBrain")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")

-- Chain extension planners (AI-SPEC §2.1, §2.2): with a flash found by AIFlashCheck (brain.direction 11 or 22,
-- brain.where/from/to), arrange panels so that what falls after the pop makes the next chain link.
-- Each returns true when it queued commands (PPL's -1); planners that set up a chain also set brain.step = 1.
-- Columns are view columns (PplBoard); queue with brain:addCommand, read the board through board:type/state/isIdle.
-- Ported from m2c drafts of the asm (AIChainVert1.s ... AIChainHori5.s), checked against the spec.

local EMPTY = PplBoard.EMPTY
local IDLE = PplBoard.IDLE
local COLOR_TYPES = PplBoard.COLOR_TYPES
local ROWS = PplBoard.ROWS
local CHECK_SLOTS = PplBrain.CHECK_SLOTS
local isColor = PplBoard.isColor
local moveAcross = PplHelpers.moveAcross

-- character bit for AIChainVert1's slide-in (AI-SPEC §3.2)
local SLIDE_IN = 0x04
-- AIChainVert3's slide codes: try flash rows from+1..to-1 (111) or from..to-1 (222)
local SLIDE_INNER = 111
local SLIDE_ALL = 222
-- AISortRows' "unused" row
local SORT_USED = 12

local PplChains = {}

---------------------------------------------------------------------------------------------------------------------
-- shared bits

-- Appends (row, column) to a colour's candidate list (AIrowCheck/AIcolCheck, AItotCheck counts).
---@param brain PplBrain
---@param colorIndex integer
---@param row integer
---@param column integer
local function push(brain, colorIndex, row, column)
  local slot = brain.totCheck[colorIndex]
  brain.rowCheck[colorIndex][slot] = row
  brain.colCheck[colorIndex][slot] = column
  brain.totCheck[colorIndex] = slot + 1
end

-- Writes a candidate into a fixed slot. PPL's 5-slot rows overflow into the next colour's row in AIChainVert4/5;
-- those spilled slots are never read back, so they are dropped here (AI-SPEC §2.1, AIChainVert4).
---@param brain PplBrain
---@param colorIndex integer
---@param slot integer
---@param row integer
---@param column integer
local function store(brain, colorIndex, slot, row, column)
  if slot < CHECK_SLOTS then
    brain.rowCheck[colorIndex][slot] = row
    brain.colCheck[colorIndex][slot] = column
  end
end

-- The first column from first to last (by step) holding a resting panel of blockType on row. With target, the
-- panel must also be able to slide to target (AIMoveAcross). -1 when there is none.
---@param board PplBoard
---@param row integer
---@param first integer
---@param last integer
---@param step integer 1 or -1
---@param blockType integer
---@param target integer?
---@return integer column
local function findIdle(board, row, first, last, step, blockType, target)
  for column = first, last, step do
    if board:isIdle(row, column, blockType) and (not target or moveAcross(board, row, column, target)) then
      return column
    end
  end
  return -1
end

-- AISortRows over a colour's first total candidates: brain.sortArray[0..total-1] becomes their visiting order.
---@param brain PplBrain
---@param colorIndex integer
---@param total integer
local function sortCandidates(brain, colorIndex, total)
  local array = brain.sortArray
  local rows = brain.rowCheck[colorIndex]
  for i = 0, total - 1 do
    array[i] = rows[i]
  end
  PplHelpers.sortRows(brain, brain.cursorY, total, array)
end

-- slide the panel in fromColumn to toColumn on row: commands 1 and 3 (or 4 / 5 / 7 with code)
---@param brain PplBrain
---@param row integer
---@param code integer
---@param fromColumn integer
---@param toColumn integer
local function slideOnRow(brain, row, code, fromColumn, toColumn)
  brain:addCommand(1, row)
  brain:addCommand(code, fromColumn, toColumn)
end

---------------------------------------------------------------------------------------------------------------------
-- vertical flash (AI-SPEC §2.1): column where, rows from..to

-- AIChainVert1 (lastPlan 11, AIChainVert1.s): the colour just under the flash, gathered into the flash column under
-- it and above it, so the panels above land on the ones below after the pop. With bit 4 a pair is enough when a
-- third can be slid in at the right moment (AIChainVert3).
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert1(board, brain)
  local canSlide = brain:hasCharacter(SLIDE_IN)
  local where = brain.where
  local from = brain.from
  local to = brain.to
  if from == 0 or to >= 10 then
    return false
  end
  brain:clearScratch()

  -- three columns around the flash, kept inside the window at its edges
  local left, right
  if where == brain.l then
    left, right = where, where + 2
  elseif where == brain.r then
    left, right = where - 2, where
  else
    left, right = where - 1, where + 1
  end

  local totCheck = brain.totCheck
  for column = left, right do
    local blockType = board:type(from - 1, column)
    if isColor(blockType) and board:state(from - 1, column) == IDLE and totCheck[blockType - 1] == 0 then
      local colorIndex = blockType - 1
      push(brain, colorIndex, from - 1, column)
      if from - 2 >= 0 then
        local under = findIdle(board, from - 2, left, right, 1, blockType, where)
        if under ~= -1 then
          push(brain, colorIndex, from - 2, under)
        end
      end
      local above = 0
      local top = findIdle(board, to + 1, left, right, 1, blockType, where)
      if top ~= -1 then
        push(brain, colorIndex, to + 1, top)
        above = 1
      end

      if totCheck[colorIndex] >= 2 and top ~= -1 then
        local higher = findIdle(board, to + 2, left, right, 1, blockType, where)
        if higher ~= -1 then
          push(brain, colorIndex, to + 2, higher)
          above = above + 1
        end

        local slide = 0
        local proceed = true
        if canSlide then
          -- PPL: 222 wants a pair of two panels above the flash, but the count includes the one under it, so a
          -- pair never has above == 2 and 222 is never used (AI-SPEC §2.1, §6.4)
          if totCheck[colorIndex] == 2 and above == 2 then
            slide = SLIDE_ALL
          else
            slide = SLIDE_INNER
          end
        else
          -- without the slide-in a pair isn't enough
          proceed = totCheck[colorIndex] ~= 2
        end

        if proceed then
          if totCheck[colorIndex] >= 3 then
            -- half the time only the first three candidates are used, and half the time no slide-in on top
            if brain:random(516) % 2 == 0 then
              totCheck[colorIndex] = 3
            end
            if slide ~= 0 and brain:random(516) % 2 == 0 then
              slide = 0
            end
          end

          local total = totCheck[colorIndex]
          sortCandidates(brain, colorIndex, total)
          local rows = brain.rowCheck[colorIndex]
          local columns = brain.colCheck[colorIndex]
          for i = 0, total - 1 do
            local entry = brain.sortArray[i]
            if columns[entry] ~= where then
              slideOnRow(brain, rows[entry], 4, columns[entry], where)
            end
          end

          if slide ~= 0 and PplChains.chainVert3(board, brain, blockType, slide) then
            -- AIChainVert3 ends with command 5, which marks the setup done
            brain.step = 1
            return true
          end
          if total >= 3 then
            brain:addCommand(11)
            brain.step = 1
            return true
          end
          -- only a pair and nothing to slide in: take this colour's commands back
          brain:delCommands(brain.totalCommand)
        end
      end
    end
  end
  return false
end

-- AIChainVert2 (lastPlan 12, AIChainVert2.s): a horizontal 3 on the flash's bottom row. Two panels of a colour on
-- that row are parked beside the flash column and a third one above the flash is moved into the column, so it
-- drops next to them after the pop.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert2(board, brain)
  brain:clearScratch()
  local where = brain.where
  local from = brain.from
  local top = brain.to + 1

  for blockType = 1, COLOR_TYPES do
    local colorIndex = blockType - 1
    local rows = brain.rowCheck[colorIndex]
    local columns = brain.colCheck[colorIndex]

    -- up to two on each side of the column on row from, nearest first: left in slots 0/1, right in 2/3
    local leftCount = 0
    for column = where - 1, brain.l, -1 do
      if board:isIdle(from, column, blockType) and moveAcross(board, from, column, where - 1) then
        rows[leftCount] = from
        columns[leftCount] = column
        leftCount = leftCount + 1
        if leftCount >= 2 then
          break
        end
      end
    end
    local rightCount = 0
    for column = where + 1, brain.r do
      if board:isIdle(from, column, blockType) and moveAcross(board, from, column, where + 1) then
        rows[2 + rightCount] = from
        columns[2 + rightCount] = column
        rightCount = rightCount + 1
        if rightCount >= 2 then
          break
        end
      end
    end

    if leftCount + rightCount >= 2 then
      -- the one that falls: a panel just above the flash that can reach the column, into slot 4
      local found = false
      for column = brain.l, brain.r do
        if board:isIdle(top, column, blockType) and moveAcross(board, top, column, where) then
          local distance = where - column
          if distance <= 0 then
            -- PPL: the asm computes -where - column here, so every panel right of the column passes the
            -- "within 3" test (AI-SPEC §2.1, §8.2)
            distance = -where - column
          end
          if distance < 4 then
            rows[4] = top
            columns[4] = column
            found = true
            break
          end
        end
      end

      if found then
        -- three of the five slots take part, visited nearest row first
        local array = brain.sortArray
        for i = 0, 4 do
          array[i] = SORT_USED
        end
        if leftCount == 2 then
          array[0] = rows[0]
          array[1] = rows[1]
        elseif rightCount == 2 then
          array[2] = rows[2]
          array[3] = rows[3]
        else
          array[0] = rows[0]
          array[2] = rows[2]
        end
        array[4] = rows[4]
        PplHelpers.sortRows(brain, brain.cursorY, 5, array)

        for i = 0, 2 do
          local slot = array[i]
          -- slots 0..3 park at where-1, where-2, where+1, where+2; slot 4 goes into the column (command 4)
          local target
          local code = 3
          if slot == 0 then
            target = where - 1
          elseif slot == 1 then
            target = where - 2
          elseif slot == 2 then
            target = where + 1
          elseif slot == 3 then
            target = where + 2
          else
            target = where
            code = 4
          end
          if columns[slot] ~= target then
            slideOnRow(brain, rows[slot], code, columns[slot], target)
          end
        end
        brain:addCommand(11)
        brain.step = 1
        return true
      end
    end
  end
  return false
end

-- AIChainVert3 = func_8007ACAC_usa (called by AIChainVert1 with the colour and slide code 111 / 222): slides a panel
-- of blockType into the flash column at a flash row, top row first. Command 5's swap retries until that cell has
-- popped, so the panel goes in at the moment it opens.
---@param board PplBoard
---@param brain PplBrain
---@param blockType integer
---@param slide integer
---@return boolean planned
function PplChains.chainVert3(board, brain, blockType, slide)
  local where = brain.where
  local lowest = brain.from + 1
  if slide == SLIDE_ALL then
    lowest = brain.from
  end
  for row = brain.to - 1, lowest, -1 do
    local left = findIdle(board, row, where - 1, brain.l, -1, blockType, where)
    local right = findIdle(board, row, where + 1, brain.r, 1, blockType, where)
    -- the right one unless the left one is strictly nearer
    if right ~= -1 and (left == -1 or where - left >= right - where) then
      slideOnRow(brain, row, 5, right, where)
      return true
    elseif left ~= -1 then
      slideOnRow(brain, row, 5, left, where)
      return true
    end
  end
  return false
end

-- Side scans of AIChainVert4/5 on row (from + 1): every reachable resting panel of blockType left of the column
-- into slots 1, 2, ... and right of it into slots 3, 4, ... (no early stop, so 3+ hits on one side run into the
-- other side's slots, as in PPL). Updates totCheck.
---@param board PplBoard
---@param brain PplBrain
---@param colorIndex integer
---@param blockType integer
---@param row integer
---@return integer leftCount
---@return integer rightCount
local function scanPairRow(board, brain, colorIndex, blockType, row)
  local where = brain.where
  local totCheck = brain.totCheck
  local leftCount = 0
  for column = where - 1, brain.l, -1 do
    if board:isIdle(row, column, blockType) and moveAcross(board, row, column, where - 1) then
      store(brain, colorIndex, 1 + leftCount, row, column)
      leftCount = leftCount + 1
      totCheck[colorIndex] = totCheck[colorIndex] + 1
    end
  end
  local rightCount = 0
  for column = where + 1, brain.r do
    if board:isIdle(row, column, blockType) and moveAcross(board, row, column, where + 1) then
      store(brain, colorIndex, 3 + rightCount, row, column)
      rightCount = rightCount + 1
      totCheck[colorIndex] = totCheck[colorIndex] + 1
    end
  end
  return leftCount, rightCount
end

-- slides candidate slot of colorIndex to toColumn on its own row
---@param brain PplBrain
---@param colorIndex integer
---@param slot integer
---@param toColumn integer
local function slideCandidate(brain, colorIndex, slot, toColumn)
  slideOnRow(brain, brain.rowCheck[colorIndex][slot], 3, brain.colCheck[colorIndex][slot], toColumn)
end

-- AIChainVert4 (lastPlan 14, character bit 0x08, AIChainVert4.s): a panel just above the flash goes into the
-- column, two of its colour wait beside the column on row from + 1, and a "plug" on that row is swapped into the
-- column the moment its cell pops (command 5). The plug drops to from, so the falling panel lands at from + 1 next
-- to the pair.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert4(board, brain)
  local where = brain.where
  if where == brain.l or where == brain.r then
    return false
  end
  brain:clearScratch()
  local pairRow = brain.from + 1
  local top = brain.to + 1
  local totCheck = brain.totCheck

  for topColumn = where - 1, where + 1 do
    local blockType = board:type(top, topColumn)
    if isColor(blockType) and board:state(top, topColumn) == IDLE and totCheck[blockType - 1] == 0 then
      local colorIndex = blockType - 1
      push(brain, colorIndex, top, topColumn)
      local leftCount, rightCount = scanPairRow(board, brain, colorIndex, blockType, pairRow)

      if totCheck[colorIndex] ~= 1 then
        local plugRight = board:type(pairRow, where + 1) ~= EMPTY
        local plugLeft = board:type(pairRow, where - 1) ~= EMPTY
        if leftCount == 2 and plugRight then
          slideCandidate(brain, colorIndex, 0, where)
          slideCandidate(brain, colorIndex, 1, where - 1)
          slideCandidate(brain, colorIndex, 2, where - 2)
          slideOnRow(brain, pairRow, 5, where + 1, where)
          brain.step = 1
          return true
        end
        if rightCount == 2 and plugLeft then
          slideCandidate(brain, colorIndex, 0, where)
          slideCandidate(brain, colorIndex, 3, where + 1)
          slideCandidate(brain, colorIndex, 4, where + 2)
          slideOnRow(brain, pairRow, 5, where - 1, where)
          brain.step = 1
          return true
        end

        -- a single panel on one side: fetch a partner from the row above on the other side
        if leftCount == 1 then
          local partner = findIdle(board, pairRow + 1, where + 1, brain.r, 1, blockType, where + 1)
          if partner ~= -1 then
            store(brain, colorIndex, 2, pairRow + 1, partner)
            leftCount = 2
          end
        elseif rightCount == 1 then
          local partner = findIdle(board, pairRow + 1, where - 1, brain.l, -1, blockType, where - 1)
          if partner ~= -1 then
            store(brain, colorIndex, 4, pairRow + 1, partner)
            rightCount = 2
          end
        end

        if (leftCount == 2 and plugRight) or (rightCount == 2 and plugLeft) then
          -- PPL: tests leftCount ~= 0, not "the left side was fetched": two on the left without a right plug and
          -- a fetched right partner send the left pair's second panel across the flashing column, and its swap
          -- is refused (AIChainVert4.s, AI-SPEC §2.1)
          if leftCount ~= 0 then
            slideCandidate(brain, colorIndex, 0, where)
            slideCandidate(brain, colorIndex, 1, where - 1)
            slideCandidate(brain, colorIndex, 2, where + 1)
            slideOnRow(brain, pairRow, 5, where + 1, where)
          else
            slideCandidate(brain, colorIndex, 0, where)
            slideCandidate(brain, colorIndex, 3, where + 1)
            slideCandidate(brain, colorIndex, 4, where - 1)
            slideOnRow(brain, pairRow, 5, where - 1, where)
          end
          brain.step = 1
          return true
        end
      end
    end
  end
  return false
end

-- the end of every AIChainVert5 plan: wait until the column above starts falling, then swap
---@param brain PplBrain
local function timedSwap(brain)
  brain:addCommand(13, brain.from + 2, brain.where)
  brain:addCommand(9)
  brain:addCommand(11)
  brain.step = 1
end

-- AIChainVert5 (lastPlan 15, character bit 0x10, only during a chain, AIChainVert5.s): the panels of AIChainVert4,
-- but it ends with a timed swap on the flash's bottom row once the column above starts falling (command 13, then a
-- plain swap). A panel of the colour sitting two above the flash is knocked aside first.
-- PPL: what the timed swap builds is not clear from the code; ported as read (AI-SPEC §2.1, §8.1).
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert5(board, brain)
  brain:clearScratch()
  local where = brain.where
  local from = brain.from
  local pairRow = from + 1
  local top = brain.to + 1
  local totCheck = brain.totCheck

  for topColumn = where - 1, where + 1 do
    -- PPL: bounded by 0..5, not the vision window (AIChainVert5.s:42)
    if topColumn >= 0 and topColumn <= 5 then
      local blockType = board:type(top, topColumn)
      if isColor(blockType) and board:state(top, topColumn) == IDLE and totCheck[blockType - 1] == 0 then
        local colorIndex = blockType - 1
        push(brain, colorIndex, top, topColumn)
        local leftCount, rightCount = scanPairRow(board, brain, colorIndex, blockType, pairRow)

        if totCheck[colorIndex] ~= 1 then
          local onTop = board:type(top + 1, where) == blockType
          if leftCount == 2 then
            if onTop then
              slideOnRow(brain, top + 1, 6, where, where - 1)
            end
            slideCandidate(brain, colorIndex, 0, where)
            slideCandidate(brain, colorIndex, 1, where - 1)
            slideCandidate(brain, colorIndex, 2, where - 2)
            brain:addCommand(1, from)
            brain:addCommand(2, where - 1)
            timedSwap(brain)
            return true
          end
          if rightCount == 2 then
            if onTop then
              slideOnRow(brain, top + 1, 6, where, where + 1)
            end
            slideCandidate(brain, colorIndex, 0, where)
            slideCandidate(brain, colorIndex, 3, where + 1)
            slideCandidate(brain, colorIndex, 4, where + 2)
            brain:addCommand(1, from)
            brain:addCommand(2, where)
            timedSwap(brain)
            return true
          end
          if leftCount == 1 and rightCount == 1 then
            if onTop then
              brain:addCommand(1, top + 1)
              if brain:random(100) % 2 == 0 then
                brain:addCommand(6, where, where - 1)
              else
                brain:addCommand(6, where, where + 1)
              end
            end
            slideCandidate(brain, colorIndex, 0, where)
            slideCandidate(brain, colorIndex, 1, where - 1)
            slideCandidate(brain, colorIndex, 3, where + 1)
            brain:addCommand(1, from)
            if brain:random(100) % 2 == 0 then
              brain:addCommand(2, where - 1)
            else
              brain:addCommand(2, where)
            end
            timedSwap(brain)
            return true
          end
        end
      end
    end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- horizontal flash (AI-SPEC §2.2): row where, columns from..to

-- AIChainHori1 (lastPlan 0x15, AIChainHori1.s): a vertical 3 through the flash row. Panels of the colour just under
-- the flash row and just above it are gathered into one column over the flash; the upper ones land on the lower
-- ones after the pop.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori1(board, brain)
  local from = brain.from
  local to = brain.to
  -- PPL: guards the flash's first column, not its row, so a flash on row 0 reads row -1 (empty here)
  -- (AI-SPEC §2.2, §8.3)
  if from == 0 then
    return false
  end
  brain:clearScratch()
  local row = brain.where

  -- the flash columns with one column of margin, kept inside the window
  local first, last
  if from == brain.l then
    first, last = from, to + 1
  elseif to == brain.r then
    first, last = from - 1, to
  else
    first, last = from - 1, to + 1
  end

  local totCheck = brain.totCheck
  for column = first, last do
    local blockType = board:type(row - 1, column)
    if isColor(blockType) and board:state(row - 1, column) == IDLE and totCheck[blockType - 1] == 0 then
      local colorIndex = blockType - 1
      push(brain, colorIndex, row - 1, column)
      if row - 2 >= 0 then
        local under = findIdle(board, row - 2, first, last, 1, blockType)
        if under ~= -1 then
          push(brain, colorIndex, row - 2, under)
        end
      end
      local up = findIdle(board, row + 1, first, last, 1, blockType)
      if up ~= -1 then
        push(brain, colorIndex, row + 1, up)
      end

      if totCheck[colorIndex] >= 2 and up ~= -1 then
        local higher = findIdle(board, row + 2, first, last, 1, blockType)
        if higher ~= -1 then
          push(brain, colorIndex, row + 2, higher)
        end

        local total = totCheck[colorIndex]
        if total >= 3 then
          sortCandidates(brain, colorIndex, total)
          local order = brain.sortArray
          local rows = brain.rowCheck[colorIndex]
          local columns = brain.colCheck[colorIndex]
          -- the column to stack in: the last-visited candidate's, kept over the flash; or the first-visited
          -- one's when the cursor is nearer to it
          local target = columns[order[total - 1]]
          if target < from then
            target = from
          elseif target > to then
            target = to
          else
            local firstColumn = columns[order[0]]
            if math.abs(brain.cursorX - (firstColumn - 1)) < math.abs(brain.cursorX - target) then
              target = firstColumn
            end
          end
          for i = 0, total - 1 do
            local entry = order[i]
            if columns[entry] ~= target then
              slideOnRow(brain, rows[entry], 4, columns[entry], target)
            end
          end
          brain:addCommand(11)
          brain.step = 1
          return true
        end
      end
    end
  end
  return false
end

-- AIChainHori2 (lastPlan 0x16, AIChainHori2.s): a horizontal 3 on the flash row. One or two panels from the row
-- above go onto a flash end, and two or one of the colour already on the flash row are parked beside it; after
-- the pop the upper ones drop in next to them. Always exactly three panels.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori2(board, brain)
  brain:clearScratch()
  local row = brain.where
  local upper = row + 1
  local from = brain.from
  local to = brain.to

  for blockType = 1, COLOR_TYPES do
    local colorIndex = blockType - 1
    local rows = brain.rowCheck[colorIndex]
    local columns = brain.colCheck[colorIndex]

    -- resting panels of the colour on the row above: the first two into slots 0/1
    -- (PPL keeps the full set in a per-column array; it is the same as reading the board again)
    local count = 0
    for column = brain.l, brain.r do
      if board:isIdle(upper, column, blockType) then
        if count < 2 then
          rows[count] = upper
          columns[count] = column
        end
        count = count + 1
      end
    end

    if count > 0 then
      -- panels of the colour on the flash row, left of the flash first, into slots 2/3
      local need = 1
      if count == 1 then
        need = 2
      end
      local leftCount = 0
      local rightCount = 0
      local side = 0
      for column = from - 1, brain.l, -1 do
        if board:isIdle(row, column, blockType) then
          rows[2 + leftCount] = row
          columns[2 + leftCount] = column
          leftCount = leftCount + 1
          if leftCount == need then
            side = 1
            break
          end
        end
      end
      if side == 0 then
        for column = to + 1, brain.r do
          if board:isIdle(row, column, blockType) then
            rows[2 + rightCount] = row
            columns[2 + rightCount] = column
            rightCount = rightCount + 1
            if rightCount == need then
              side = 2
              break
            end
          end
        end
      end

      if side ~= 0 then
        local used = count
        if count >= 3 then
          -- pick the two upper panels again: the ones over the flash first
          local overFlash = 0
          for column = from, to do
            if board:isIdle(upper, column, blockType) then
              overFlash = overFlash + 1
            end
          end
          used = 0
          if overFlash == 2 then
            for column = from, to do
              if board:isIdle(upper, column, blockType) then
                columns[used] = column
                used = used + 1
                if used == 2 then
                  break
                end
              end
            end
          elseif overFlash ~= 1 then
            used = 2
          else
            for column = from - 1, brain.l, -1 do
              if board:isIdle(upper, column, blockType) then
                columns[used] = column
                used = used + 1
                break
              end
            end
            local stop = brain.r
            if used == 1 then
              stop = to
            end
            for column = from, stop do
              if board:isIdle(upper, column, blockType) then
                columns[used] = column
                used = used + 1
                if used == 2 then
                  break
                end
              end
            end
          end
        end

        local array = brain.sortArray
        array[0] = rows[0]
        array[1] = SORT_USED
        if used == 2 then
          array[1] = rows[1]
        end
        array[2] = rows[2]
        array[3] = SORT_USED
        if leftCount == 2 or rightCount == 2 then
          array[3] = rows[3]
        end
        PplHelpers.sortRows(brain, brain.cursorY, 4, array)

        local upperDone = false
        local target = 0
        for i = 0, 2 do
          local slot = array[i]
          if slot == 2 then
            if side == 1 then
              target = from - 1
            else
              target = to + 1
            end
          elseif slot == 3 then
            if side == 1 then
              target = from - 2
            else
              target = to + 2
            end
          end

          if slot < 2 then
            -- the upper panels are planned together, on the first of their slots in the order
            if not upperDone then
              if used == 2 then
                local a = columns[0]
                local b = columns[1]
                if side == 1 then
                  if b < from + 1 then
                    slideOnRow(brain, upper, 3, b, from + 1)
                    slideOnRow(brain, upper, 5, a, from)
                  else
                    slideOnRow(brain, upper, 3, a, from)
                    slideOnRow(brain, upper, 5, b, from + 1)
                  end
                else
                  if a < to - 1 then
                    slideOnRow(brain, upper, 3, b, to)
                    slideOnRow(brain, upper, 5, a, to - 1)
                  else
                    slideOnRow(brain, upper, 3, a, to - 1)
                    slideOnRow(brain, upper, 5, b, to)
                  end
                end
              else
                if side == 1 then
                  target = from
                else
                  target = to
                end
                if columns[0] ~= target then
                  slideOnRow(brain, upper, 4, columns[0], target)
                end
              end
              upperDone = true
            end
          elseif columns[slot] ~= target then
            slideOnRow(brain, row, 5, columns[slot], target)
          end
        end
        brain:addCommand(11)
        brain.step = 1
        return true
      end
    end
  end
  return false
end

-- AIChainHori3's plan with the third panel landing on the left end of the flash: park the left panel at from - 1,
-- put the third on from (one row up), carry the right panel to to + 1, swap it into the flash end once it pops
-- (command 5) and run it under the cleared row to from + 1 (command 6). The third falls into the gap.
---@param brain PplBrain
---@param upper integer the row of the third panel
---@param left integer
---@param right integer
---@param third integer column of the third panel
local function planHori3Left(brain, upper, left, right, third)
  local from = brain.from
  local to = brain.to
  slideOnRow(brain, upper - 1, 3, left, from - 1)
  slideOnRow(brain, upper, 3, third, from)
  slideOnRow(brain, upper - 1, 7, right, to + 1)
  brain:addCommand(5, to + 1, to)
  brain:addCommand(6, to, from + 1)
  brain:addCommand(11)
end

-- the mirror image of planHori3Left: the third lands on the right end
---@param brain PplBrain
---@param upper integer
---@param left integer
---@param right integer
---@param third integer
local function planHori3Right(brain, upper, left, right, third)
  local from = brain.from
  local to = brain.to
  slideOnRow(brain, upper - 1, 3, right, to + 1)
  slideOnRow(brain, upper, 3, third, to)
  slideOnRow(brain, upper - 1, 7, left, from - 1)
  brain:addCommand(5, from - 1, from)
  brain:addCommand(6, from, to - 1)
  brain:addCommand(11)
end

-- AIChainHori3 (lastPlan 0x17, character bit 0x04, AIChainHori3.s): one panel of a colour on each side of the flash
-- in its row, and a third either anywhere on the row above (when nothing sits on the flash) or as the only panel
-- on the flash. See planHori3Left.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori3(board, brain)
  local from = brain.from
  local to = brain.to
  -- PPL: set once, not per colour, and moved up a row by every colour with panels on both sides, so later colours
  -- look one row higher and plan with shifted rows (AI-SPEC §2.2, §8.3)
  local row = brain.where

  for blockType = 1, COLOR_TYPES do
    local left = findIdle(board, row, from - 1, brain.l, -1, blockType)
    local right = -1
    if left ~= -1 then
      right = findIdle(board, row, to + 1, brain.r, 1, blockType)
    end

    if left ~= -1 and right ~= -1 then
      row = row + 1
      local filled = 0
      local only = -1
      for column = from, to do
        if board:type(row, column) ~= EMPTY then
          filled = filled + 1
          only = column
        end
      end

      if filled == 0 then
        local third = findIdle(board, row, brain.l, brain.r, 1, blockType)
        if third ~= -1 then
          if third < from then
            planHori3Left(brain, row, left, right, third)
          else
            planHori3Right(brain, row, left, right, third)
          end
          brain.step = 1
          return true
        end
      elseif filled == 1 and board:type(row, only) == blockType then
        -- the single panel on the flash: its state isn't checked
        if only - from < to - only then
          planHori3Left(brain, row, left, right, only)
        else
          planHori3Right(brain, row, left, right, only)
        end
        brain.step = 1
        return true
      end
    end
  end
  return false
end

-- if some cell of the row above the flash is empty (AIChainHori4/5 need a gap to drop a panel into)
---@param board PplBoard
---@param brain PplBrain
---@return boolean
local function hasGapAbove(board, brain)
  for column = brain.from, brain.to do
    if board:type(brain.where + 1, column) == EMPTY then
      return true
    end
  end
  return false
end

-- The drop-in step of AIChainHori4/5: the first gap (where + 1, x) over the flash for which a resting panel of
-- blockType sits right beside column x on some row above, lowest row first and the left side first. Sliding it
-- over the gap drops it in.
---@param board PplBoard
---@param brain PplBrain
---@param blockType integer
---@return integer x the gap's column, -1 if none
---@return integer y the row of the panel to slide
---@return integer side its column, x - 1 or x + 1
local function findDropIn(board, brain, blockType)
  local upper = brain.where + 1
  for x = brain.from, brain.to do
    if board:type(upper, x) == EMPTY then
      for y = upper + 1, ROWS - 1 do
        -- PPL: the edges are the hard-coded columns 0 and 5, not the vision window
        if x ~= 0 and board:isIdle(y, x - 1, blockType) then
          return x, y, x - 1
        elseif x ~= 5 and board:isIdle(y, x + 1, blockType) then
          return x, y, x + 1
        end
      end
    end
  end
  return -1, -1, -1
end

-- queues the drop-in found by findDropIn: slide over the gap, then wait until it has landed (command 20)
---@param brain PplBrain
---@param x integer
---@param y integer
---@param side integer
local function dropIn(brain, x, y, side)
  local upper = brain.where + 1
  slideOnRow(brain, y, 3, side, x)
  brain:addCommand(1, upper)
  brain:addCommand(20, upper, x)
end

-- AIChainHori4 (lastPlan 0x18, character bit 0x08, AIChainHori4.s): a horizontal 3 on the flash row from a panel
-- beside the flash in its row, one of its colour on the row above, and one dropped into a gap of the row above.
-- The two upper panels are slid onto the flash end (sped up), so they fall next to the parked one.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori4(board, brain)
  if not hasGapAbove(board, brain) then
    return false
  end
  local row = brain.where
  local upper = row + 1
  local from = brain.from
  local to = brain.to

  for column = brain.l, brain.r do
    local blockType = board:type(row, column)
    if board:state(row, column) == IDLE and isColor(blockType) then
      -- one of the colour on the row above, whatever its state
      local partner = -1
      for c = brain.l, brain.r do
        if board:type(upper, c) == blockType then
          partner = c
          break
        end
      end

      if partner ~= -1 then
        local x, y, side = findDropIn(board, brain, blockType)
        if x ~= -1 then
          if column < from then
            slideOnRow(brain, row, 3, column, from - 1)
            dropIn(brain, x, y, side)
            if partner < x then
              if x == from then
                brain:addCommand(6, x, x + 1)
                brain:addCommand(6, partner, from)
              else
                brain:addCommand(6, partner, from)
                brain:addCommand(6, x, from + 1)
              end
            else
              brain:addCommand(6, x, from)
              brain:addCommand(6, partner, from + 1)
            end
          else
            slideOnRow(brain, row, 3, column, to + 1)
            dropIn(brain, x, y, side)
            if partner < x then
              brain:addCommand(6, x, to)
              brain:addCommand(6, partner, to - 1)
            elseif x == to then
              brain:addCommand(6, x, x - 1)
              brain:addCommand(6, partner, to)
            else
              brain:addCommand(6, partner, to)
              brain:addCommand(6, x, to - 1)
            end
          end
          brain:addCommand(11)
          brain.step = 1
          return true
        end
      end
    end
  end
  return false
end

-- AIChainHori5 (lastPlan 0x19, character bit 0x08, AIChainHori5.s): two panels of a colour on one side of the flash
-- in its row are parked at from - 1, from - 2 (or to + 1, to + 2), and one dropped into a gap of the row above is
-- slid onto the flash end next to them.
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori5(board, brain)
  brain:clearScratch()
  if not hasGapAbove(board, brain) then
    return false
  end
  local row = brain.where
  local from = brain.from
  local to = brain.to

  for blockType = 1, COLOR_TYPES do
    local colorIndex = blockType - 1
    local rows = brain.rowCheck[colorIndex]
    local columns = brain.colCheck[colorIndex]
    local leftCount = 0
    for column = from - 1, brain.l, -1 do
      if board:isIdle(row, column, blockType) then
        rows[leftCount] = row
        columns[leftCount] = column
        leftCount = leftCount + 1
        if leftCount == 2 then
          break
        end
      end
    end
    local rightCount = 0
    for column = to + 1, brain.r do
      if board:isIdle(row, column, blockType) then
        rows[2 + rightCount] = row
        columns[2 + rightCount] = column
        rightCount = rightCount + 1
        if rightCount == 2 then
          break
        end
      end
    end

    if leftCount == 2 or rightCount == 2 then
      local x, y, side = findDropIn(board, brain, blockType)
      if x ~= -1 then
        -- PPL: tests leftCount ~= 0, not leftCount == 2: with one on the left and two on the right it parks the
        -- left one and slot 1, still 0 from the clear, so column 0 is slid to from - 2 (AI-SPEC §2.2, §8.3)
        if leftCount ~= 0 then
          slideOnRow(brain, row, 3, columns[0], from - 1)
          slideOnRow(brain, row, 3, columns[1], from - 2)
          dropIn(brain, x, y, side)
          brain:addCommand(6, x, from)
        else
          slideOnRow(brain, row, 3, columns[2], to + 1)
          slideOnRow(brain, row, 3, columns[3], to + 2)
          dropIn(brain, x, y, side)
          brain:addCommand(6, x, to)
        end
        brain:addCommand(11)
        brain.step = 1
        return true
      end
    end
  end
  return false
end

return PplChains

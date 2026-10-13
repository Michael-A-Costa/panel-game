local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplChains = require("common.engine.computerPlayers.PplCpu.PplChains")
local PplGarbage = require("common.engine.computerPlayers.PplCpu.PplGarbage")
local PplCombos = require("common.engine.computerPlayers.PplCpu.PplCombos")

-- PPL's UpdateAI (AI-SPEC §1.5, from the m2c of UpdateAI.s, not the #if 0 draft in ai.c) and the command
-- expansion inside it (§1.6). Once per frame on the state after the previous frame: cool down after chains, watch
-- for flashes, and when both queues are empty run the planner cascade in PPL's priority order. Then turn the next
-- command(s) into moves for PplExecutor.

local EMPTY = PplBoard.EMPTY
local FALLING = PplBoard.FALLING
local ROWS = PplBoard.ROWS
local VERTICAL = PplHelpers.VERTICAL

-- character bits (AI-SPEC §3.2)
local COMBO_45 = 0x01
local SLIDE_IN = 0x04
local ADVANCED_SETUPS = 0x08
local TIMED_SWAP = 0x10
local GARBAGE_CHAINS = 0x20

local PplPlanner = {}

-- AIChainFrequency, inlined at the top of UpdateAI: after a x2 or x3 chain ends, think == 0 CPUs wait
-- 333..443 frames before they build chains or 4/5 combos again. A new chain cancels the wait.
---@param board PplBoard
---@param brain PplBrain
local function coolDown(board, brain)
  local oldChain = board.oldChain
  if brain.think > 0 and oldChain ~= 0 then
    brain.think = 0
  elseif oldChain ~= brain.chainCheck and oldChain == 0 and brain.chainCheck >= -2 then
    if brain.think == 0 then
      brain.think = brain:random(111) + 333
    end
  end
  if brain.think > 0 then
    brain.think = brain.think - 1
  end
end

-- if the chain planners may build another link now (garbage, chainLimit; AI-SPEC §3.3)
---@param board PplBoard
---@param brain PplBrain
---@return boolean
local function chainAllowed(board, brain)
  if brain.garbageRow ~= -1 then
    return brain.garbageRow >= 6 and board.oldChain >= -3
  elseif brain.chainLimit < 0 then
    return brain.chainLimit < board.oldChain
  elseif brain.chainLimit == 0 then
    return board.oldChain >= -3
  end
  return false
end

-- extends the running chain off the flash AIFlashCheck found
---@param board PplBoard
---@param brain PplBrain
local function planChainLink(board, brain)
  if brain.direction == VERTICAL then
    if PplChains.chainVert1(board, brain) then
      brain.lastPlan = 11
    elseif PplChains.chainVert2(board, brain) then
      brain.lastPlan = 12
    elseif brain:hasCharacter(ADVANCED_SETUPS) and PplChains.chainVert4(board, brain) then
      brain.lastPlan = 14
    elseif brain:hasCharacter(TIMED_SWAP) and board.oldChain ~= 0 and PplChains.chainVert5(board, brain) then
      brain.lastPlan = 15
    end
  else
    if PplChains.chainHori1(board, brain) then
      brain.lastPlan = 0x15
    elseif PplChains.chainHori2(board, brain) then
      brain.lastPlan = 0x16
    elseif brain:hasCharacter(SLIDE_IN) and PplChains.chainHori3(board, brain) then
      brain.lastPlan = 0x17
    elseif brain:hasCharacter(ADVANCED_SETUPS) and PplChains.chainHori4(board, brain) then
      brain.lastPlan = 0x18
    elseif brain:hasCharacter(ADVANCED_SETUPS) and PplChains.chainHori5(board, brain) then
      brain.lastPlan = 0x19
    end
  end
end

-- vertical 3s, 4/5 combos and the fallbacks around the cursor (the inlined AIVisionCheck onwards)
---@param board PplBoard
---@param brain PplBrain
local function planNearCursor(board, brain)
  brain:changeVision()
  PplHelpers.visionCheck(board, brain)
  PplCombos.comboCheck(board, brain)
  if brain.chainLimit == 0 and PplCombos.comboX(board, brain) then
    brain.lastPlan = 9
    return
  end
  if brain.think <= 0 and brain:hasCharacter(COMBO_45) then
    -- the 4 roll only happens when the 5 roll misses (UpdateAI.s:467-492)
    if brain:random(803) % 7 == 0 then
      if PplCombos.combo45(board, brain, 5) then
        brain.lastPlan = 3
        return
      end
    elseif brain:random(566) % 5 == 0 then
      if PplCombos.combo45(board, brain, 4) then
        brain.lastPlan = 4
        return
      end
    end
  end
  if PplCombos.combo3a(board, brain) then
    brain.lastPlan = 5
  elseif PplCombos.combo3b(board, brain) then
    brain.lastPlan = 6
  elseif PplGarbage.volumeCheck(board, brain, false) then
    brain.lastPlan = 0x34
  else
    PplCombos.stupidMove(board, brain)
  end
end

-- The planner cascade, run when both queues are empty. The first planner that queues commands wins.
---@param board PplBoard
---@param brain PplBrain
local function plan(board, brain)
  -- 1. garbage on the board
  if brain.garbageRow ~= -1 then
    if board.cursorState == 2 then
      -- garbage is turning into panels: chain off it, or tidy up under it
      if brain:hasCharacter(GARBAGE_CHAINS) and PplGarbage.chainGarbage1(board, brain) then
        brain.lastPlan = 0x1E
      elseif PplGarbage.chainPack(board, brain) then
        brain.lastPlan = 0x1F
      else
        -- a 0 frame wait, so the plan isn't empty
        brain:addCommand(14, 0)
      end
      brain.step = 2
    elseif PplGarbage.clearGarbage(board, brain) then
      brain.lastPlan = 0x20
    elseif brain:random(1972) % 3 == 0 and PplGarbage.volumeCheck(board, brain, false) then
      brain.lastPlan = 0x32
    end
  end
  if brain.totalCommand ~= 0 then
    return
  end

  -- 2. extend the running chain off the current flash
  if brain.think <= 0 and brain.direction ~= 0 and chainAllowed(board, brain) then
    planChainLink(board, brain)
  end
  if brain.totalCommand ~= 0 then
    return
  end

  -- 3. stack height: the raise logic always, flattening only while close to the top
  if PplGarbage.volumeCheck(board, brain, not board.alert) then
    brain.lastPlan = 0x33
  end
  if brain.totalCommand ~= 0 then
    return
  end

  -- 4. simple 3s through the cursor
  if PplCombos.possibleRow(board, brain, brain.cursorY) then
    brain.lastPlan = 1
  elseif PplCombos.possibleCol(board, brain) then
    brain.lastPlan = 2
  else
    -- 5. vertical stacks within +/- 2 rows of the cursor, then the fallbacks
    planNearCursor(board, brain)
  end
end

-- Column parameters of a command as view columns now. The pair keeps its distance even when the tower has turned
-- so far that one of them would wrap the other way.
---@param board PplBoard
---@param first integer stored (board) column
---@param second integer stored (board) column
---@return integer from
---@return integer to
local function viewColumns(board, first, second)
  local from = board:toViewColumn(first)
  return from, from + board:columnDelta(first, second)
end

-- Commands 13, 14 and 20 stay queued until their condition is met (AI-SPEC §1.6).
---@param board PplBoard
---@param brain PplBrain
---@param slot integer 1-based storage index of the command
---@param code integer
---@return boolean done
local function waitDone(board, brain, slot, code)
  if code == 14 then
    -- wait n frames
    local frames = brain.commandFirst[slot]
    brain.commandFirst[slot] = frames - 1
    return frames <= 0
  end

  local row = brain.commandFirst[slot]
  local column = board:toViewColumn(brain.commandSecond[slot])
  if code == 20 then
    -- wait for a panel to drop into (row, column), or for the field to calm down
    return not (board.fieldActive and board:type(row, column) == EMPTY)
  end

  -- 13: if something can still fall into (row, column) from above, wait until the column starts falling
  local limit = brain.garbageRow ~= -1 and brain.garbageRow or ROWS
  local scan = row - 2
  while scan < limit and board:type(scan, column) == EMPTY do
    scan = scan + 1
  end
  if (board.fieldActive or board:type(row - 2, column) == EMPTY) and scan ~= limit then
    return board:state(row, column) == FALLING
  end
  return true
end

-- Expands queued commands into moves, lazily: it stops at the first command that produced moves, and the rest wait
-- until those have run. On the tower the stored board columns go back to view columns here.
-- PPL: queued rows are not moved up when the stack rises a row, so they point one row low after a rise (AI-SPEC §1.4).
---@param board PplBoard
---@param brain PplBrain
function PplPlanner.expandCommands(board, brain)
  repeat
    local slot = brain.comHead + 1
    local code = brain.commandCodes[slot]
    local first = brain.commandFirst[slot]
    local second = brain.commandSecond[slot]

    if code == 13 or code == 14 or code == 20 then
      if not waitDone(board, brain, slot, code) then
        return
      end
    elseif code == 1 then
      -- PPL: skipped before a slide that goes nowhere, even when that next slot is left over from an older plan
      -- (AI-SPEC §1.6)
      local nextCode = brain.commandCodes[slot + 1]
      if not ((nextCode == 3 or nextCode == 4 or nextCode == 5)
          and brain.commandFirst[slot + 1] == brain.commandSecond[slot + 1]) then
        PplHelpers.vertMove(brain, first)
      end
    elseif code == 2 then
      PplHelpers.horiMove(board, brain, board:toViewColumn(first))
    elseif code == 3 or code == 5 or code == 7 then
      local from, to = viewColumns(board, first, second)
      if brain.step == 1 and PplHelpers.horiMoveCheckCheck(board, brain, from, to) then
        brain:speedUpMoves()
      end
      PplHelpers.horiMoveBlock(brain, from, to)
      if code == 5 then
        -- the last swap retries until it goes through (move 6)
        if brain.moveTail ~= 0 then
          brain.moves[brain.moveTail] = 6
        end
        brain.step = 2
      end
    elseif code == 4 then
      local from, to = viewColumns(board, first, second)
      -- pick the nearest panel of that colour again, it may have moved since planning
      from = PplHelpers.shortestDistance(board, brain, from, to)
      -- PPL: -1 means no panel of that colour is left, and the slide starts beyond the left edge (AI-SPEC §8.3).
      -- Kept in 2D. On the tower column -1 is a real panel, so the slide is dropped there instead.
      if from ~= -1 or not board.cylinder then
        brain.commandFirst[slot] = board:toBoardColumn(from)
        if brain.step == 1 and PplHelpers.horiMoveCheckCheck(board, brain, from, to) then
          brain:speedUpMoves()
        end
        PplHelpers.horiMoveBlock(brain, from, to)
      end
    elseif code == 6 then
      local from, to = viewColumns(board, first, second)
      PplHelpers.horiMoveBlock(brain, from, to)
      brain:speedUpMoves()
    elseif code == 8 then
      local pos1, pos2 = viewColumns(board, first, second)
      PplHelpers.rowPack(brain, pos1, pos2)
    elseif code == 9 then
      brain:setMove(5)
    elseif code == 10 then
      brain:setMove(8)
    elseif code == 11 then
      brain.step = 2
    elseif code == 12 then
      brain:setMove(7)
      brain.delay = 0
    end

    brain.totalCommand = brain.totalCommand - 1
    brain.comHead = brain.comHead + 1
  until brain.totalCommand <= 0 or brain:hasMoves()
end

-- UpdateAI: plans on the state after the previous frame. PplCpu updates brain.chainCheck afterwards.
---@param board PplBoard
---@param brain PplBrain
function PplPlanner.update(board, brain)
  coolDown(board, brain)

  -- no planning while a swap animates or a manual raise runs
  if board.swapping or board.raise then
    return
  end
  brain:setCursor()
  PplHelpers.setGarbage(board, brain)

  if not PplHelpers.flashCheck(board, brain) then
    -- after a finished setup, sit still while the field is busy
    if brain.step == 2 and board.cursorState ~= 2 and brain.totalCommand == 0
        and (board.cursorState == 1 or board.waiting ~= 0) then
      return
    end
  elseif brain.step ~= 1 then
    -- a new flash: drop the plan and plan the next link
    brain.step = 0
    brain:clearQueues()
  elseif brain:random(321) % 3 == 0 then
    -- mid-setup: drop it one time in three
    brain.step = 0
    brain:clearQueues()
  else
    -- keep the setup, no new chain plan
    brain.direction = 0
  end

  if brain:hasMoves() then
    return
  end

  if brain.totalCommand == 0 then
    brain.step = 0
    brain:clearQueues()
    plan(board, brain)
  end

  if brain.totalCommand > 0 then
    brain:finishMoves()
    PplPlanner.expandCommands(board, brain)
  end
end

return PplPlanner

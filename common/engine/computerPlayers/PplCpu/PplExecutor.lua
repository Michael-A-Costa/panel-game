local KeyDataEncoding = require("common.data.KeyDataEncoding")
local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")

-- PPL's AIMove, AI2DMove and AI3DMove (AI-SPEC §1.6 moves table, §1.7): every `delay` frames the next queued move
-- becomes one Panel Attack input. PPL moves the cursor directly; here the CPU has to press buttons, so a few
-- things follow Panel Attack's controller instead (INTEGRATION §A2):
-- - holding a direction on two frames in a row is a hold, not two presses: an equal direction gets an idle frame
--   in between (PLAN "Decisions taken", quick moves);
-- - a swap right after a swap is denied while the first is queued: it waits a frame;
-- - whether a swap is refused is decided with the stack's own canSwap; if the stack still denies it, the CPU
--   learns it next frame (observe);
-- - a manual raise is held until the stack's manual raise is over.
-- Nothing here writes to the stack.

local IDLE = KeyDataEncoding.idle
local LEFT = KeyDataEncoding.left
local RIGHT = KeyDataEncoding.right
local UP = KeyDataEncoding.up
local DOWN = KeyDataEncoding.down
local SWAP = KeyDataEncoding.swap
local RAISE = KeyDataEncoding.raise
local EMPTY = PplBoard.EMPTY

-- moves 1-4 and their quick variants 11-14
local DIRECTION_OF_MOVE = {
  [1] = LEFT, [2] = RIGHT, [3] = UP, [4] = DOWN,
  [11] = LEFT, [12] = RIGHT, [13] = UP, [14] = DOWN,
}
local QUICK_MOVES = {[11] = true, [12] = true, [13] = true, [14] = true, [15] = true}
local SWAP_MOVES = {[5] = true, [6] = true, [15] = true}

local PplExecutor = {}

-- if the stack would take a swap at the cursor right now. On the tower a swap during a turn snaps the turn to its
-- end first, so it swaps the pair the tower is turning to.
---@param stack Stack
---@return boolean
local function canSwapAtCursor(stack)
  local column = stack.cur_col
  if stack.cylinder and stack.rotationTimer > 0 then
    column = stack:wrapColumn(column + stack.rotationDirection)
  end
  local row = stack.panels[stack.cur_row]
  local canSwap = stack:canSwap(row[column], row[stack:columnRightOf(column)])
  return canSwap
end

-- if the hands can't do this move on this frame and it has to wait for the next one
---@param board PplBoard
---@param brain PplBrain
---@param move integer
---@return boolean
local function handsBusy(board, brain, move)
  local direction = DIRECTION_OF_MOVE[move]
  if direction then
    if board.cylinder and (direction == LEFT or direction == RIGHT) then
      -- a turn pressed again while one runs is dropped like PPL's, not delayed (AI3DMove)
      return false
    end
    return direction == brain.lastInput
  end
  if SWAP_MOVES[move] then
    return board.stack:swapQueued()
  end
  return false
end

-- Runs move 5/15 (a swap that clears the plan when refused) or 6 (a swap that retries until it goes through).
---@param board PplBoard
---@param brain PplBrain
---@param move integer
---@return string input
---@return boolean advance
local function swapMove(board, brain, move)
  local stack = board.stack
  if move == 6 and not board.cylinder then
    -- the retrying swap runs every frame in 2D
    brain.delay = 1
  end
  if canSwapAtCursor(stack) then
    if QUICK_MOVES[move] and not board.cylinder then
      brain.delay = 1
    end
    brain.swapMove = move
    brain.swapCountBefore = stack.swapCount
    return SWAP, true
  elseif move == 6 then
    -- it also counts as done when there is nothing to swap
    local row = board.cursorY
    local done = board:type(row, board.cursorX) == EMPTY and board:type(row, board.cursorX + 1) == EMPTY
    return IDLE, done
  else
    brain:clearQueues()
    return IDLE, false
  end
end

-- AI2DMove / AI3DMove: the input for one move, and if it is used up.
---@param board PplBoard
---@param brain PplBrain
---@param move integer
---@return string input
---@return boolean advance
local function runMove(board, brain, move)
  local cylinder = board.cylinder
  local direction = DIRECTION_OF_MOVE[move]
  if direction then
    if cylinder then
      if (direction == LEFT or direction == RIGHT) and board.stack.rotationTimer > 0 then
        -- PPL: a turn is refused while one runs but the move is used up anyway (AI-SPEC §5)
        return IDLE, true
      end
    elseif QUICK_MOVES[move] then
      -- one-frame moves are 2D only
      brain.delay = 1
    end
    return direction, true
  elseif SWAP_MOVES[move] then
    return swapMove(board, brain, move)
  elseif move == 7 then
    if board.raise then
      return IDLE, false
    end
    brain.raising = true
    return RAISE, true
  elseif move == 8 then
    if cylinder then
      -- 3D replaces it in place with a random move, run on the next turn (can be 6, rarely)
      brain.moves[brain.moveHead + 1] = brain:random(5) + 1
      return IDLE, false
    end
    brain:changeVision()
    return IDLE, true
  end
  -- unknown moves stall the queue, as in PPL
  return IDLE, false
end

-- Feeds back what the stack made of last frame's input, before planning: PPL learns these within the frame.
---@param board PplBoard
---@param brain PplBrain
function PplExecutor.observe(board, brain)
  local stack = board.stack
  if brain.swapMove ~= 0 then
    if stack.swapCount == brain.swapCountBefore then
      -- the stack denied the swap after all (the board changed during that frame)
      if brain.swapMove == 6 then
        brain.moveHead = brain.moveHead - 1
      else
        brain:clearQueues()
      end
    end
    brain.swapMove = 0
  end

  if brain.raising and not board.raise then
    -- PPL: a finished raise drops every plan (AIMove, AI-SPEC §1.7)
    brain.raising = false
    brain:clearQueues()
  end
end

-- AIMove: this frame's input.
---@param board PplBoard
---@param brain PplBrain
---@return string input
function PplExecutor.move(board, brain)
  local input = IDLE
  if brain.raising then
    -- well.raise > 0: nothing else happens until the raise is done
    input = RAISE
  else
    brain.delay = brain.delay - 1
    if brain.delay <= 0 and brain:hasMoves() then
      local move = brain:currentMove()
      if not handsBusy(board, brain, move) then
        if brain:random(375) % 3 == 0 then
          brain.delay = brain.speed + brain:random(2)
        else
          brain.delay = brain.speed - brain:random(2)
        end
        if board.death then
          brain.delay = brain.speed - brain:random(3)
        elseif brain.step ~= 0 then
          brain.delay = brain.delay - brain:random(3)
        end

        local advance
        input, advance = runMove(board, brain, move)
        if advance then
          brain.moveHead = brain.moveHead + 1
        end
      end
    end
  end
  brain.lastInput = input
  return input
end

return PplExecutor

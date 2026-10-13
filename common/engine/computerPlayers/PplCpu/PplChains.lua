-- Chain extension planners (AI-SPEC §2.1, §2.2): with a flash found by AIFlashCheck (brain.direction 11 or 22,
-- brain.where/from/to), arrange panels so that what falls after the pop makes the next chain link.
-- Each returns true when it queued commands (PPL's -1); planners that set up a chain also set brain.step = 1.
-- Columns are view columns (PplBoard); queue with brain:addCommand, read the board through board:type/state/isIdle.

-- STUBS: every planner here still returns false ("no plan"). Phase 2b fills them in.

local PplChains = {}

-- AIChainVert1 (lastPlan 11), AI-SPEC §2.1
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert1(board, brain)
  return false
end

-- AIChainVert2 (lastPlan 12), AI-SPEC §2.1
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert2(board, brain)
  return false
end

-- AIChainVert3 = func_8007ACAC_usa, called by AIChainVert1 with the colour and slide code 111 / 222, AI-SPEC §2.1
---@param board PplBoard
---@param brain PplBrain
---@param blockType integer
---@param slide integer
---@return boolean planned
function PplChains.chainVert3(board, brain, blockType, slide)
  return false
end

-- AIChainVert4 (lastPlan 14, character bit 0x08), AI-SPEC §2.1
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert4(board, brain)
  return false
end

-- AIChainVert5 (lastPlan 15, character bit 0x10, only during a chain), AI-SPEC §2.1
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainVert5(board, brain)
  return false
end

-- AIChainHori1 (lastPlan 0x15), AI-SPEC §2.2
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori1(board, brain)
  return false
end

-- AIChainHori2 (lastPlan 0x16), AI-SPEC §2.2
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori2(board, brain)
  return false
end

-- AIChainHori3 (lastPlan 0x17, character bit 0x04), AI-SPEC §2.2
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori3(board, brain)
  return false
end

-- AIChainHori4 (lastPlan 0x18, character bit 0x08), AI-SPEC §2.2
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori4(board, brain)
  return false
end

-- AIChainHori5 (lastPlan 0x19, character bit 0x08), AI-SPEC §2.2
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplChains.chainHori5(board, brain)
  return false
end

return PplChains

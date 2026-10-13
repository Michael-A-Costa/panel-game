-- Garbage and stack height planners (AI-SPEC §2.3, §2.5 AIVolumeCheck): clear the lowest garbage, chain off
-- garbage while it turns into panels, raise a low stack and flatten a tall one.
-- Each returns true when it queued commands (PPL's -1). Columns are view columns (PplBoard); queue with
-- brain:addCommand. AIStupidMove, the last fallback of §2.5, is in PplCombos (AI-SPEC §7.1).

-- STUBS: every planner here still returns false ("no plan"). Phase 2b fills them in.

local PplGarbage = {}

-- AIClearGarbage (lastPlan 0x20), AI-SPEC §2.3
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.clearGarbage(board, brain)
  return false
end

-- AIChainGarbage1 (lastPlan 0x1E, character bit 0x20), AI-SPEC §2.3
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.chainGarbage1(board, brain)
  return false
end

-- AIChainGarbage2, called by AIChainGarbage1 with the colour below and the column, AI-SPEC §2.3
---@param board PplBoard
---@param brain PplBrain
---@param below integer block type
---@param column integer
---@return boolean planned
function PplGarbage.chainGarbage2(board, brain, below, column)
  return false
end

-- AIChainPack (lastPlan 0x1F), AI-SPEC §2.3
---@param board PplBoard
---@param brain PplBrain
---@return boolean planned
function PplGarbage.chainPack(board, brain)
  return false
end

-- AIVolumeCheck (lastPlan 0x32 / 0x33 / 0x34), AI-SPEC §2.5. skipFlatten is PPL's `exit` argument:
-- true runs only the raise logic.
---@param board PplBoard
---@param brain PplBrain
---@param skipFlatten boolean
---@return boolean planned
function PplGarbage.volumeCheck(board, brain, skipFlatten)
  return false
end

return PplGarbage

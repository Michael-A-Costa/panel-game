---@class StackSetupModifications
---@field behaviours StackBehaviours?
---@field stopTime integer?
---@field shakeTime integer?
---@field startingRow integer?
---@field startingCol integer?
---@field cylinder boolean? if true the stack is Pokémon Puzzle League's 3D tower: an 18-column ring (docs/3d-mode/SPEC.md)
---@field pplVersus boolean? if true the stack keeps Pokémon Puzzle League's 2P VS pace: its speed schedule and rise
--- times, and a topout grace that shrinks with match time (docs/cpu-ai/STADIUM-SPEC.md §2)
---@field pplHelperPairs PplHelperPairs? how often a new row gets Pokémon Puzzle League's ready-made pair (STADIUM-SPEC §2)

---@alias PplHelperPairs
---| "every" # every new row, as PPL's Easy Stadium
---| "alternate" # every other new row, the first one included, as PPL's Normal and Hard Stadium

---@class MatchRules
---@field doCountdown boolean
---@field matchEndConditions table<MatchEndCondition, any>
---@field matchWinRuleset table<MatchWinCriteria, PlacementOrder>[]
---@field stackOverConditions table<StackOverCondition, any>
---@field stackWinConditions table<StackWinCondition, integer>
---@field stackSetupModifications StackSetupModifications

local MatchRules = {}

---@enum  MatchEndCondition
MatchRules.MatchEndConditions = { STACKS_ACTIVE = "STACKS_ACTIVE", TIME_LIMIT = "TIME_LIMIT" }

---@enum MatchWinCriteria
MatchRules.MatchWinCriterias = { GAME_OVER_CLOCK = "GAME_OVER_CLOCK", SCORE = "SCORE", TIME = "TIME" }

---@enum PlacementOrder
MatchRules.orders = { LOWEST = "LOWEST", HIGHEST = "HIGHEST" }

---@enum StackOverCondition
MatchRules.StackOverConditions = { HEALTH = "HEALTH", SWAPS = "SWAPS", CHAIN = "CHAIN" }

---@enum StackWinCondition
-- a stack wins once every condition it has holds: MATCHABLE_GARBAGE_PANELS once every block on the board is hit,
-- GARBAGE_BUFFER_EXCEEDED once a hit needs more garbage panels than the panel source's buffer holds;
-- clear puzzles no longer use MATCHABLE_GARBAGE_PANELS, it stays for the replays recorded with it
MatchRules.StackWinConditions = {
  MATCHABLE_PANELS = "MATCHABLE_PANELS",
  MATCHABLE_GARBAGE_PANELS = "MATCHABLE_GARBAGE_PANELS",
  GARBAGE_BUFFER_EXCEEDED = "GARBAGE_BUFFER_EXCEEDED",
  SCORE = "SCORE"
}

return MatchRules
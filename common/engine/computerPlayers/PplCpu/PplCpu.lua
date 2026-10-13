local class = require("common.lib.class")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplBrain = require("common.engine.computerPlayers.PplCpu.PplBrain")
local PplPlanner = require("common.engine.computerPlayers.PplCpu.PplPlanner")
local PplExecutor = require("common.engine.computerPlayers.PplCpu.PplExecutor")
local PplPresets = require("common.engine.computerPlayers.PplCpu.PplPresets")

-- A port of Pokémon Puzzle League's CPU opponent (docs/cpu-ai/AI-SPEC.md) as a Panel Attack input device:
-- it reads its stack and answers one controller input per frame, like a human's hands would.
-- It never writes to the stack and draws only from its own PPL generator, so for a seed it always plays the same.

---@class PplCpuOptions
---@field seed integer seeds the CPU's own random generator
---@field level integer? 1-10, the vs-CPU scale (PPL's DemoCPU, AI-SPEC §3.5)
---@field difficulty integer? 1 Easy .. 5 Super Hard, a Stadium opponent (AI-SPEC §3.4); needs stage
---@field stage integer? 1 .. the difficulty's ladder length

---@class PplCpu
---@field stack Stack the stack it plays; read only
---@field board PplBoard
---@field brain PplBrain
---@overload fun(stack: Stack, options: PplCpuOptions): PplCpu
local PplCpu = class(
---@param self PplCpu
---@param stack Stack
---@param options PplCpuOptions
function(self, stack, options)
  assert(options and options.seed, "PplCpu needs options with a seed")
  self.stack = stack
  self.board = PplBoard(stack)
  self.brain = PplBrain(self.board, options.seed)
  local settings
  if options.difficulty then
    settings = PplPresets.forStage(options.difficulty, options.stage)
  else
    settings = PplPresets.forLevel(options.level)
  end
  self.brain:applySettings(settings)
  self:initAI(options.difficulty ~= nil)
end)

-- InitAI (ai.c:24): a fresh brain, and in Stadium one of three openings: go to row 2, row 3, or stay.
---@param stadium boolean
function PplCpu:initAI(stadium)
  local brain = self.brain
  brain.lastPlan = 1
  brain.step = 0
  brain.garbageRow = -1
  brain.direction = 0
  brain.delay = brain.speed
  brain:clearQueues()
  for i = 1, #brain.moves do
    brain.moves[i] = 0
  end
  brain:setCursor()
  brain:changeVision()
  if stadium then
    if brain:random(317) % 2 == 0 then
      brain:addCommand(1, 2)
      brain:addCommand(10)
    elseif brain:random(66) % 2 == 0 then
      brain:addCommand(1, 3)
      brain:addCommand(10)
    end
  end
end

-- The input for the stack's next frame. Call once per frame, only when the stack is caught up
-- (#confirmedInput == clock), before that frame runs.
---@return string input one KeyDataEncoding character
function PplCpu:getInput()
  local stack = self.stack
  if stack.do_countdown or stack:game_ended() then
    return KeyDataEncoding.idle
  end
  local board = self.board
  local brain = self.brain
  board:refresh()
  PplExecutor.observe(board, brain)
  -- PPL plans at the end of a frame (UpdateAI) and moves at the start of the next (AIMove)
  PplPlanner.update(board, brain)
  brain.chainCheck = board.oldChain
  return PplExecutor.move(board, brain)
end

ComputerPlayer.register("PplCpu", PplCpu)

return PplCpu

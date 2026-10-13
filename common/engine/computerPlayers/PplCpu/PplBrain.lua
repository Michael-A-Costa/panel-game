local class = require("common.lib.class")
local PplRandom = require("common.engine.computerPlayers.PplCpu.PplRandom")
table.new = require("table.new")

-- PPL's ai_t (AI-SPEC §1.2): what the CPU keeps between frames, its command and move queues and the scratch
-- tables the planners share. Everything is allocated here once; planning and moving only overwrite it.

-- PPL has 15 commands and 25 moves without bounds checks; no plan comes close to these
local COMMAND_CAPACITY = 32
local MOVE_CAPACITY = 32
-- colour indices 0..7: PPL's 7 types plus Panel Attack's squares (AI-SPEC §7.1)
local COLOR_SLOTS = 8
-- slots per colour: PPL has 5, AIChainVert4/5 write a 6th (AI-SPEC §2.1)
local CHECK_SLOTS = 6
local SORT_CAPACITY = 12
-- AIdistance's "no reachable panel" value
local NO_DISTANCE = 18

-- commands whose first / second parameter is a column (§1.6); on the tower these are stored as board columns
local FIRST_PARAMETER_IS_COLUMN = {[2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true}
local SECOND_PARAMETER_IS_COLUMN = {[3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [13] = true,
                                    [20] = true}

-- AISpeedUpMove: plain moves to their one-frame variants
local QUICK_MOVE = {[1] = 11, [2] = 12, [3] = 13, [4] = 14, [5] = 15}

---@class PplBrainSettings
---@field speed integer frames between moves
---@field character integer technique bits (AI-SPEC §3.2)
---@field chainLimit integer longest chain to build as a negative old_chain threshold; 0 combo character, -99 unlimited
---@field think integer 0 = cool down after x2/x3 chains, -1 = never

---@class PplBrain
---@field board PplBoard the board planners read; converts the columns of queued commands on the tower
---@field rng PplRandom
---@field cursorX integer cursor_x copied from the board each planning frame (view column on the tower)
---@field cursorY integer cursor_y
---@field think integer chain cooldown: > 0 counts down, <= 0 chains allowed, -1 never cools down
---@field speed integer base frames between moves
---@field delay integer frames until the next move
---@field character integer technique bitmask (AI-SPEC §3.2)
---@field chainLimit integer see PplBrainSettings
---@field lastPlan integer id of the last planner that succeeded (AI-SPEC §6.4); written, never read
---@field step integer chain setup phase: 0 idle, 1 setting up, 2 set up and waiting for the chain
---@field garbageRow integer lowest garbage row in column 2 or 3, -1 none (refreshed by AISetGarbage)
---@field t integer vision top row
---@field b integer vision bottom row
---@field l integer vision left column (0)
---@field r integer vision right column (5)
---@field direction integer flash found by AIFlashCheck: 0 none, 11 vertical, 22 horizontal
---@field where integer vertical flash: its column; horizontal: its row
---@field from integer first flashing row (vertical) or column (horizontal)
---@field to integer last flashing row or column, inclusive
---@field chainCheck integer last frame's old_chain (PPL's chain_check[num])
---@field comHead integer 0-based index of the next command to expand
---@field comTail integer 0-based index after the last command
---@field totalCommand integer commands still queued
---@field commandCodes integer[] command.function per slot, stored at index slot + 1
---@field commandFirst integer[] command.para1 per slot (board column on the tower when it is a column)
---@field commandSecond integer[] command.para2 per slot
---@field moveHead integer 0-based index of the next move
---@field moveTail integer 0-based index after the last move
---@field moves integer[] queued moves, stored at index slot + 1
---@field rowCheck integer[][] AIrowCheck[colourIndex][slot], both 0-based like PPL: colourIndex = type - 1
---@field colCheck integer[][] AIcolCheck, same layout
---@field totCheck integer[] AItotCheck[colourIndex]; AIChainGarbage1/AIChainPack/AILowerRow use it per column (-1 locked)
---@field distance integer[] AIdistance[colourIndex] (0-based), 18 = invalid
---@field bestColor integer PPL's AIdistance[7]: colour index with the shortest distance, 18 if none
---@field sortArray integer[] 0-based scratch for AISortRows' array argument (callers copy their rows in)
---@field sortIndex integer[] 0-based scratch AISortRows uses internally
---@field raising boolean the executor is holding raise for a manual raise it started
---@field swapMove integer move code of the swap sent last frame, 0 if none
---@field swapCountBefore integer the stack's swapCount when that swap was sent
---@field lastInput string the input sent last frame
---@overload fun(board: PplBoard, seed: integer): PplBrain
local PplBrain = class(
---@param self PplBrain
---@param board PplBoard
---@param seed integer
function(self, board, seed)
  self.board = board
  self.rng = PplRandom(seed)

  self.cursorX = 0
  self.cursorY = 0
  self.think = 0
  self.speed = 20
  self.delay = 20
  self.character = 0
  self.chainLimit = -1
  self.lastPlan = 1
  self.step = 0
  self.garbageRow = -1
  self.t = 0
  self.b = 0
  self.l = 0
  self.r = 5
  self.direction = 0
  self.where = 0
  self.from = 0
  self.to = 0
  self.chainCheck = 0

  self.comHead = 0
  self.comTail = 0
  self.totalCommand = 0
  self.commandCodes = table.new(COMMAND_CAPACITY, 0)
  self.commandFirst = table.new(COMMAND_CAPACITY, 0)
  self.commandSecond = table.new(COMMAND_CAPACITY, 0)
  for i = 1, COMMAND_CAPACITY do
    self.commandCodes[i] = 0
    self.commandFirst[i] = 0
    self.commandSecond[i] = 0
  end
  self.moveHead = 0
  self.moveTail = 0
  self.moves = table.new(MOVE_CAPACITY, 0)
  for i = 1, MOVE_CAPACITY do
    self.moves[i] = 0
  end

  self.rowCheck = {}
  self.colCheck = {}
  self.totCheck = {}
  self.distance = {}
  for colorIndex = 0, COLOR_SLOTS - 1 do
    self.rowCheck[colorIndex] = {}
    self.colCheck[colorIndex] = {}
  end
  self:clearScratch()
  self:resetDistances()
  self.sortArray = {}
  self.sortIndex = {}
  for i = 0, SORT_CAPACITY - 1 do
    self.sortArray[i] = 0
    self.sortIndex[i] = 0
  end

  self.raising = false
  self.swapMove = 0
  self.swapCountBefore = 0
  self.lastInput = ""
end)

PplBrain.COLOR_SLOTS = COLOR_SLOTS
PplBrain.CHECK_SLOTS = CHECK_SLOTS
PplBrain.NO_DISTANCE = NO_DISTANCE

---@param settings PplBrainSettings
function PplBrain:applySettings(settings)
  self.speed = settings.speed
  self.character = settings.character
  self.chainLimit = settings.chainLimit
  self.think = settings.think
end

-- AnimationRandom(max): 0..max-1, rarely max (AI-SPEC §4.1)
---@param max integer
---@return integer
function PplBrain:random(max)
  return self.rng:next(max)
end

-- if any of the technique bits in mask is set (PPL's `brain->character & mask`)
---@param mask integer
---@return boolean
function PplBrain:hasCharacter(mask)
  return math.floor(self.character / mask) % 2 == 1
end

-- AISetCursor
function PplBrain:setCursor()
  self.cursorX = self.board.cursorX
  self.cursorY = self.board.cursorY
end

-- AIChangeVision: look at the cursor row +/- 2, all six columns
function PplBrain:changeVision()
  self.l = 0
  self.r = 5
  self.t = math.min(self.cursorY + 2, 11)
  self.b = math.max(self.cursorY - 2, 0)
end

-- AIAddCommand, with column parameters given in view columns (what planners see). On the tower they are stored as
-- board columns so the plan still points at the same panels after the tower turns (PLAN "Decisions taken").
---@param code integer command code (AI-SPEC §1.6)
---@param first integer?
---@param second integer?
function PplBrain:addCommand(code, first, second)
  first = first or 0
  second = second or 0
  local board = self.board
  if board.cylinder then
    if code == 2 then
      -- AIHoriMove's clamp to column 0, done in the view the planner saw
      first = math.max(first, 0)
    end
    if FIRST_PARAMETER_IS_COLUMN[code] then
      first = board:toBoardColumn(first)
    end
    if SECOND_PARAMETER_IS_COLUMN[code] then
      second = board:toBoardColumn(second)
    end
  end
  local slot = self.comTail + 1
  self.commandCodes[slot] = code
  self.commandFirst[slot] = first
  self.commandSecond[slot] = second
  self.totalCommand = self.totalCommand + 1
  self.comTail = self.comTail + 1
end

-- AIDelCommand: takes back the last count commands
---@param count integer
function PplBrain:delCommands(count)
  self.totalCommand = self.totalCommand - count
  self.comTail = self.comTail - count
end

-- AISetMove
---@param move integer
function PplBrain:setMove(move)
  self.moves[self.moveTail + 1] = move
  self.moveTail = self.moveTail + 1
end

-- AIFinishMove
function PplBrain:finishMoves()
  self.moveHead = 0
  self.moveTail = 0
end

-- AIClearCommand: drops the whole plan. The queues are linear and restart at 0, like PPL's.
function PplBrain:clearQueues()
  self.totalCommand = 0
  self.comHead = 0
  self.comTail = 0
  self.moveHead = 0
  self.moveTail = 0
end

-- if moves are still queued
---@return boolean
function PplBrain:hasMoves()
  return self.moveHead ~= self.moveTail
end

-- the next move to run
---@return integer
function PplBrain:currentMove()
  return self.moves[self.moveHead + 1]
end

-- AISpeedUpMove: every move not run yet becomes its one-frame variant (6 and 7 stay)
function PplBrain:speedUpMoves()
  for slot = self.moveHead + 1, self.moveTail do
    local quick = QUICK_MOVE[self.moves[slot]]
    if quick then
      self.moves[slot] = quick
    end
  end
end

-- bzero of AIrowCheck, AIcolCheck and AItotCheck
function PplBrain:clearScratch()
  local rowCheck = self.rowCheck
  local colCheck = self.colCheck
  local totCheck = self.totCheck
  for colorIndex = 0, COLOR_SLOTS - 1 do
    local rows = rowCheck[colorIndex]
    local columns = colCheck[colorIndex]
    for slot = 0, CHECK_SLOTS - 1 do
      rows[slot] = 0
      columns[slot] = 0
    end
    totCheck[colorIndex] = 0
  end
end

-- AIdistance[i] = 18 for every colour and the best colour slot
function PplBrain:resetDistances()
  for colorIndex = 0, COLOR_SLOTS - 1 do
    self.distance[colorIndex] = NO_DISTANCE
  end
  self.bestColor = NO_DISTANCE
end

return PplBrain

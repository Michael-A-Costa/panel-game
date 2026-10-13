local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")
local PplCpu = require("common.engine.computerPlayers.PplCpu.PplCpu")
local PplRandom = require("common.engine.computerPlayers.PplCpu.PplRandom")
local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplPlanner = require("common.engine.computerPlayers.PplCpu.PplPlanner")
local PplExecutor = require("common.engine.computerPlayers.PplCpu.PplExecutor")
local PplCombos = require("common.engine.computerPlayers.PplCpu.PplCombos")
local PplPresets = require("common.engine.computerPlayers.PplCpu.PplPresets")

-- Tests for the port of Pokémon Puzzle League's CPU (docs/stadium/AI-SPEC.md, phase 2a of docs/stadium/PLAN.md).

local IDLE = KeyDataEncoding.idle
local LEFT = KeyDataEncoding.left
local RIGHT = KeyDataEncoding.right
local UP = KeyDataEncoding.up
local DOWN = KeyDataEncoding.down
local SWAP = KeyDataEncoding.swap
local RAISE = KeyDataEncoding.raise

local INPUT_NAMES = {[IDLE] = "idle", [LEFT] = "left", [RIGHT] = "right", [UP] = "up", [DOWN] = "down", [SWAP] = "swap",
                     [RAISE] = "raise"}

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

---@param actual integer[]
---@param expected integer[]
---@param what string
local function expectList(actual, expected, what)
  local same = #actual == #expected
  for i = 1, #expected do
    same = same and actual[i] == expected[i]
  end
  if not same then
    local function show(list)
      local parts = {}
      for i, value in ipairs(list) do
        parts[i] = INPUT_NAMES[value] or tostring(value)
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    end
    error(what .. ": expected " .. show(expected) .. ", got " .. show(actual))
  end
end

---@param brain PplBrain
---@return integer[]
local function queuedMoves(brain)
  local moves = {}
  for slot = brain.moveHead + 1, brain.moveTail do
    moves[#moves + 1] = brain.moves[slot]
  end
  return moves
end

-- commands still queued, flattened as code, first, second, code, ...
---@param brain PplBrain
---@return integer[]
local function queuedCommands(brain)
  local commands = {}
  for slot = brain.comHead + 1, brain.comTail do
    commands[#commands + 1] = brain.commandCodes[slot]
    commands[#commands + 1] = brain.commandFirst[slot]
    commands[#commands + 1] = brain.commandSecond[slot]
  end
  return commands
end

-- a 2D endless match for fixed boards: no countdown and no rising
---@param options {seed: integer?, allowManualRaise: boolean?}?
---@return Match
---@return Stack
local function createMatch(options)
  options = options or {}
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules
  rules.doCountdown = false
  rules.stackSetupModifications.behaviours = {passiveRaise = false, allowManualRaise = options.allowManualRaise or false}
  local match = Match(GeneratorSource(options.seed or 1, false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(5), false, "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)
  return match, stack
end

-- empties the board and lays out rows bottom up: rows[i] holds the colours of PA row i (0 = empty) from firstColumn
---@param stack Stack
---@param rows integer[][]
---@param firstColumn integer?
local function setBoard(stack, rows, firstColumn)
  CylinderTestUtils.clearBoard(stack)
  for row, colors in ipairs(rows) do
    local columns = {}
    for i, color in ipairs(colors) do
      columns[(firstColumn or 1) + i - 1] = color
    end
    CylinderTestUtils.setColors(stack, row, columns)
  end
end

---@param match Match
---@param stack Stack
---@param count integer
local function idleFrames(match, stack, count)
  for _ = 1, count do
    stack:receiveConfirmedInput(IDLE)
    match:run()
  end
end

---@param stack Stack
---@param options PplCpuOptions?
---@return PplCpu
local function newCpu(stack, options)
  return PplCpu(stack, options or {seed = 1, level = 10})
end

-- runs only the executor on moves a test queued, one frame at a time
---@param match Match
---@param stack Stack
---@param cpu PplCpu
---@param frames integer
---@return string[] inputs
local function executeFrames(match, stack, cpu, frames)
  local inputs = {}
  for i = 1, frames do
    cpu.board:refresh()
    PplExecutor.observe(cpu.board, cpu.brain)
    inputs[i] = PplExecutor.move(cpu.board, cpu.brain)
    stack:receiveConfirmedInput(inputs[i])
    match:run()
  end
  return inputs
end

---@param brain PplBrain
---@param moves integer[]
local function queueMoves(brain, moves)
  brain:clearQueues()
  for _, move in ipairs(moves) do
    brain:setMove(move)
  end
end

---@param inputs string[]
---@return string[]
local function withoutIdle(inputs)
  local pressed = {}
  for _, input in ipairs(inputs) do
    if input ~= IDLE then
      pressed[#pressed + 1] = input
    end
  end
  return pressed
end

---------------------------------------------------------------------------------------------------------------------
-- PplRandom (AI-SPEC §4)

local function randomMatchesPplGenerator()
  -- by hand: seed 0 steps to 0 + 0x87C125 + 0 * 0x7B6E72 = 8896805, and 8896805 / 2^31 * 100 = 0.41 -> 0
  local random = PplRandom(0)
  expect(random:next(100), 0, "first draw from seed 0")
  expect(random.state, 8896805, "state after one step from seed 0")
  -- the rest from an independent float32 implementation of animation.c's AnimationRandom
  local draws = {{100, 74}, {100, 43}, {375, 100}, {2, 0}, {3, 1}}
  for i, draw in ipairs(draws) do
    expect(random:next(draw[1]), draw[2], "seed 0, draw " .. (i + 1))
  end
  expect(random.state, 1224814380, "state after six steps from seed 0")

  random = PplRandom(12345)
  draws = {{6, 3}, {111, 79}, {321, 277}, {1972, 240}, {5, 3}}
  for i, draw in ipairs(draws) do
    expect(random:next(draw[1]), draw[2], "seed 12345, draw " .. i)
  end
  expect(random.state, 1701566184, "state after five steps from seed 12345")

  -- the edge: low 31 bits of 2^31 - 64 and up round to 2^31 in f32, so the draw is max itself
  expect(PplRandom(299353406):next(5), 5, "a state stepping to 0x7FFFFFFF draws max")
  expect(PplRandom(915930425):next(2), 2, "a state stepping to 2^31 - 64 draws max")
  expect(PplRandom(1130239614):next(5), 4, "a state stepping to 2^31 - 65 stays below max")
end

randomMatchesPplGenerator()

---------------------------------------------------------------------------------------------------------------------
-- PplPresets (AI-SPEC §3.4, §3.5)

local function presetsMatchTheStageTable()
  -- AI-SPEC §3.4, column by column
  local table34 = {
    { -- Easy
      character = {0x00, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x07, 0x07, 0x07},
      speed = {35, 35, 34, 34, 33, 33, 32, 32, 31, 31, 30},
      chainLimit = {-1, -2, -3, -4, 0, -5, -6, -7, 0, -8, 0},
    },
    { -- Normal
      character = {0x01, 0x03, 0x03, 0x03, 0x03, 0x07, 0x07, 0x07, 0x07, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F},
      speed = {20, 20, 19, 19, 18, 18, 17, 17, 16, 16, 15, 15, 14, 14},
      chainLimit = {-1, -2, -3, -3, 0, -3, -3, -3, 0, -3, 0, -3, -3, -3},
    },
    { -- Hard
      character = {0x23, 0x27, 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xBF, 0xBF, 0xEF, 0xBF, 0xFF, 0xBF, 0xBF, 0xBF},
      speed = {16, 16, 15, 15, 14, 14, 13, 13, 12, 12, 11, 11, 10, 10, 9},
      chainLimit = {-2, -3, -4, -5, 0, -6, -7, -8, 0, -9, 0, -10, -11, -99, -99},
    },
    { -- Very Hard
      character = {0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF},
      speed = {11, 11, 10, 10, 9, 9, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7},
      chainLimit = {-3, -4, -5, -6, 0, -7, -8, -9, 0, -10, 0, -11, -12, -99, -99, -99},
    },
    { -- Super Hard
      character = {0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF},
      speed = {7, 7, 7, 7, 6, 6, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4},
      chainLimit = {-99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99, -99},
    },
  }
  for difficulty, column in ipairs(table34) do
    expect(PplPresets.stageCount(difficulty), #column.speed, "stages of difficulty " .. difficulty)
    for stage = 1, #column.speed do
      local settings = PplPresets.forStage(difficulty, stage)
      local where = "difficulty " .. difficulty .. " stage " .. stage
      expect(settings.character, column.character[stage], where .. " character")
      expect(settings.speed, column.speed[stage], where .. " speed")
      expect(settings.chainLimit, column.chainLimit[stage], where .. " chainLimit")
      local think = 0
      if difficulty == PplPresets.EASY or difficulty == PplPresets.SUPER_HARD
          or (difficulty == PplPresets.VERY_HARD and stage >= 9) then
        think = -1
      end
      expect(settings.think, think, where .. " think")
    end
  end

  -- DemoCPU: level 10 is Super Hard stage 15, level 1 Easy stage 1
  expect(PplPresets.forLevel(10).speed, 4, "level 10 speed")
  expect(PplPresets.forLevel(1).speed, 35, "level 1 speed")
  expect(PplPresets.forLevel(5).character, 0xAF, "level 5 is Hard stage 6")
  assert(not pcall(PplPresets.forStage, PplPresets.EASY, 12), "Easy has no stage 12")
end

presetsMatchTheStageTable()

---------------------------------------------------------------------------------------------------------------------
-- PplBoard (AI-SPEC §1.3, §7.2, §7.3)

local function boardReadsTwoDimensionalStack()
  local _, stack = createMatch()
  setBoard(stack, {
    {3, 0, 0, 0, 0, 8}, -- shock at PPL column 5
    {0, 7, 0, 0, 0, 0}, -- squares
  })
  local face = stack.levelData.frameConstants.FACE
  ---@param row integer
  ---@param column integer
  ---@param state string
  ---@param timer integer?
  ---@param chaining boolean?
  local function setPanel(row, column, color, state, timer, chaining)
    local panel = stack.panels[row][column]
    panel.color = color
    panel.state = state
    panel.timer = timer or 0
    panel.chaining = chaining
  end
  setPanel(4, 1, 2, "matched", face + 5)
  setPanel(4, 2, 2, "matched", 1)
  setPanel(4, 3, 2, "hovering", 3, true)
  setPanel(4, 4, 2, "hovering", 3)
  setPanel(4, 5, 2, "falling")
  setPanel(4, 6, 2, "landing", 2)
  setPanel(5, 1, 0, "swapping", 3)
  local garbage = stack.panels[6][3]
  garbage.isGarbage = true
  garbage.color = 9
  stack.cur_row = 4
  stack.cur_col = 3
  stack.chain_counter = 3

  local board = PplBoard(stack)
  expect(board:type(0, 0), 3, "PA row 1 column 1 is PPL row 0 column 0")
  expect(board:type(0, 5), PplBoard.SHOCK, "shock panels are PPL's ! type")
  expect(board:type(1, 1), PplBoard.SQUARE, "squares get a type of their own")
  expect(board:type(0, 1), PplBoard.EMPTY, "an empty cell")
  expect(board:type(-1, 0), PplBoard.EMPTY, "below the board reads empty")
  expect(board:type(12, 0), PplBoard.EMPTY, "above the board reads empty")
  expect(board:type(0, -1), PplBoard.EMPTY, "left of the board reads empty in 2D")
  expect(board:type(0, 6), PplBoard.EMPTY, "right of the board reads empty in 2D")
  expect(board:state(0, 6), PplBoard.IDLE, "out of range state")

  expect(board:state(3, 0), PplBoard.FLASHING, "matched and still flashing")
  expect(board:state(3, 1), PplBoard.POPPING, "matched and showing its face")
  expect(board:state(3, 2), PplBoard.HOVERING_CHAIN, "hovering with the chain flag")
  expect(board:state(3, 3), PplBoard.HOVERING, "hovering")
  expect(board:state(3, 4), PplBoard.FALLING, "falling")
  expect(board:state(3, 5), PplBoard.IDLE, "landing panels rest")
  expect(board:state(4, 0), PplBoard.SWAPPING, "an empty cell in a swap")
  assert(board:isIdle(3, 5, 2), "a landing panel is idle")
  assert(not board:isIdle(3, 4, 2), "a falling panel is not idle")

  expect(board:type(5, 2), PplBoard.GARBAGE, "garbage")
  expect(board.garbageRow, 5, "garbage row in PPL rows")
  expect(board.cursorX, 2, "cursor x")
  expect(board.cursorY, 3, "cursor y")
  expect(board.oldChain, -2, "a x3 chain is old_chain -2")
  assert(board.fieldActive, "falling panels make the field active")
  expect(board.cursorState, 1, "panels active")
  expect(board.waiting, 1, "panels still settling")
  expect(board.alert, false, "nothing near the top")
  expect(board:toBoardColumn(3), 3, "2D view and board columns are the same")
  expect(board:toViewColumn(3), 3, "2D view and board columns are the same")

  garbage.state = "matched"
  stack.panels[10][1].color = 1
  board:refresh()
  expect(board:state(5, 2), PplBoard.GARBAGE_TURNING, "matched garbage turns into panels")
  expect(board.cursorState, 2, "garbage turning into panels")
  assert(board.alert, "a panel in PPL row 9 is an alert")
end

boardReadsTwoDimensionalStack()

local function boardReadsTheTowerThroughTheViewWindow()
  local _, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  stack.cur_col = 10
  CylinderTestUtils.setColors(stack, 1, {[5] = 4, [6] = 1, [10] = 2, [11] = 3, [12] = 5})

  local board = PplBoard(stack)
  expect(board.cursorX, 4, "the cursor pair sits on view columns 4 and 5")
  expect(board:type(0, 0), 1, "view column 0 is board column 6")
  expect(board:type(0, 4), 2, "view column 4 is the cursor's board column")
  expect(board:type(0, 5), 3, "view column 5 is right of the cursor")
  expect(board:type(0, -1), 4, "left of the window is the real tower")
  expect(board:type(0, 6), 5, "right of the window is the real tower")
  expect(board:toBoardColumn(0), 5, "0-based board column of view column 0")
  expect(board:toViewColumn(5), 0, "and back")
  expect(board:toBoardColumn(-1), 4, "view column -1")
  expect(board:toViewColumn(4), -1, "and back")

  -- across the seam
  stack.cur_col = 1
  board:refresh()
  expect(board:toBoardColumn(4), 0, "the cursor on board column 1")
  expect(board:toBoardColumn(0), 14, "view column 0 is board column 15")
  expect(board:toViewColumn(14), 0, "board column 15 is view column 0")
  expect(board:toViewColumn(17), 3, "board column 18 is left of the cursor")
  expect(board:columnDelta(17, 0), 1, "one step right across the seam")
  expect(board:columnDelta(0, 17), -1, "one step left across the seam")

  -- garbageRow and alerts: garbage counts in view columns 2 and 3 only, alerts anywhere on the tower
  stack.cur_col = 10
  local garbage = stack.panels[3][8]
  garbage.isGarbage = true
  garbage.color = 9
  local behind = stack.panels[4][1]
  behind.isGarbage = true
  behind.color = 9
  board:refresh()
  expect(board:type(2, 2), PplBoard.GARBAGE, "garbage in view column 2")
  expect(board.garbageRow, 2, "garbage row from view column 2")
  stack.panels[11][18].color = 2
  board:refresh()
  assert(board.alert, "a high panel behind the tower is an alert")
end

boardReadsTheTowerThroughTheViewWindow()

---------------------------------------------------------------------------------------------------------------------
-- helpers (AI-SPEC §1.9)

local function moveHelpersQueueTheRightMoves()
  local _, stack = createMatch()
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board

  brain:clearQueues()
  brain.cursorY = 3
  assert(PplHelpers.vertMove(brain, 6), "AIVertMove up")
  assert(PplHelpers.vertMove(brain, 1), "AIVertMove down")
  assert(not PplHelpers.vertMove(brain, 3), "AIVertMove to the cursor row")
  expectList(queuedMoves(brain), {3, 3, 3, 4, 4}, "AIVertMove")

  brain:clearQueues()
  brain.cursorX = 2
  PplHelpers.horiMove(board, brain, 5)
  PplHelpers.horiMove(board, brain, -1)
  expectList(queuedMoves(brain), {2, 2, 1, 1}, "AIHoriMove: column 5 is the pair 4/5, -1 clamps to 0")

  brain:clearQueues()
  brain.cursorX = 0
  assert(PplHelpers.horiMoveBlock(brain, 3, 1), "slide left")
  expectList(queuedMoves(brain), {2, 2, 5, 1, 5}, "slide 3 -> 1 from column 0: right cell onto 3, then swap left twice")
  brain:clearQueues()
  PplHelpers.horiMoveBlock(brain, 1, 4)
  expectList(queuedMoves(brain), {2, 5, 2, 5, 2, 5}, "slide 1 -> 4 from column 0")
  brain:clearQueues()
  assert(not PplHelpers.horiMoveBlock(brain, 2, 2), "a slide to itself")
  brain.cursorX = 3
  PplHelpers.horiMoveBlock(brain, 3, 4)
  expectList(queuedMoves(brain), {5}, "slide with the cursor already on the panel")

  brain:clearQueues()
  brain.cursorX = 0
  assert(PplHelpers.rowPack(brain, 1, 4), "AIRowPack")
  expectList(queuedMoves(brain), {2, 5, 2, 5}, "AIRowPack carries the nearer panel 1 to column 3")
  brain:clearQueues()
  brain.cursorX = 4
  PplHelpers.rowPack(brain, 0, 3)
  expectList(queuedMoves(brain), {1, 1, 5, 1, 5}, "AIRowPack carries panel 3 to column 1")
  assert(not PplHelpers.rowPack(brain, 2, 3), "AIRowPack of neighbours")

  -- AISpeedUpMove
  brain:clearQueues()
  for _, move in ipairs({1, 2, 3, 4, 5, 6, 7, 8}) do
    brain:setMove(move)
  end
  brain.moveHead = 1
  brain:speedUpMoves()
  expectList(queuedMoves(brain), {12, 13, 14, 15, 6, 7, 8}, "AISpeedUpMove from the head on")
  expect(brain.moves[1], 1, "a move already run stays")
end

moveHelpersQueueTheRightMoves()

local function measureHelpers()
  local _, stack = createMatch()
  local cpu = newCpu(stack)
  local brain = cpu.brain

  brain.cursorX = 2
  assert(PplHelpers.searchClose(brain, 1, 5), "1 is as close as 4")
  assert(not PplHelpers.searchClose(brain, 0, 4), "0 is farther than 3")

  brain.cursorY = 5
  expect(PplHelpers.distance(brain, 5, 2), 0, "AIDistance under the left cell")
  expect(PplHelpers.distance(brain, 5, 3), 0, "AIDistance under the right cell")
  expect(PplHelpers.distance(brain, 5, 0), 2, "AIDistance to the left")
  expect(PplHelpers.distance(brain, 3, 5), 4, "AIDistance up and right")

  local array = brain.sortArray
  array[0], array[1], array[2], array[3] = 5, 2, 8, 3
  PplHelpers.sortRows(brain, 4, 4, array)
  expectList({array[0], array[1], array[2], array[3]}, {0, 3, 1, 2}, "AISortRows nearest first, from the last pick")
  array[0], array[1] = 3, 5
  PplHelpers.sortRows(brain, 4, 2, array)
  expectList({array[0], array[1]}, {0, 1}, "AISortRows ties go to the lower index")
end

measureHelpers()

local function boardHelpersReadTheBoard()
  local _, stack = createMatch()
  setBoard(stack, {
    {1, 2, 0, 4, 5, 6},
    {2, 0, 0, 3, 1, 0},
    {1, 0, 2, 0, 1, 1},
  })
  stack.panels[2][5].state = "falling"
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board
  board:refresh()

  -- AIMoveAcross on PPL row 1
  assert(PplHelpers.moveAcross(board, 1, 0, 1), "neighbours always pass")
  assert(PplHelpers.moveAcross(board, 1, 3, 3), "to itself")
  assert(not PplHelpers.moveAcross(board, 1, 0, 3), "column 2 is over a hole")
  assert(not PplHelpers.moveAcross(board, 1, 3, 5), "column 4 holds a falling panel")
  assert(PplHelpers.moveAcross(board, 0, 0, 5), "row 0 never drops")
  assert(PplHelpers.moveAcross(board, 2, 5, 3), "row 2 right to left over a resting panel")
  assert(not PplHelpers.moveAcross(board, 2, 4, 1), "row 2 column 2 rests over a hole")

  -- AIShortestD on PPL row 2: 1 0 2 0 1 1
  brain.cursorY = 2
  brain.l = 0
  brain.r = 5
  expect(PplHelpers.shortestDistance(board, brain, 0, 4), 4, "the target already has the colour")
  expect(PplHelpers.shortestDistance(board, brain, 4, 2), 0, "a tie goes left")
  expect(PplHelpers.shortestDistance(board, brain, 0, 3), 4, "the nearer one on the right")
  brain.cursorY = 1
  expect(PplHelpers.shortestDistance(board, brain, 4, 2), -1, "the only panel of the colour is falling")

  -- AIClearPosition
  brain:clearQueues()
  assert(PplHelpers.clearPosition(board, brain, 1, 1), "an empty cell is clear")
  expectList(queuedCommands(brain), {}, "nothing to do for an empty cell")
  assert(PplHelpers.clearPosition(board, brain, 1, 0), "column 0 into the hole on its right")
  assert(PplHelpers.clearPosition(board, brain, 1, 4), "column 4 into the hole on its right")
  assert(PplHelpers.clearPosition(board, brain, 1, 3), "column 3 into the hole on its left")
  assert(not PplHelpers.clearPosition(board, brain, 0, 5), "column 5 with a panel on its left")
  expectList(queuedCommands(brain), {1, 1, 0, 3, 0, 1, 1, 1, 0, 3, 4, 5, 1, 1, 0, 3, 3, 2}, "AIClearPosition commands")

  -- AILowerRow, with brain.totCheck as column locks
  brain:clearQueues()
  brain:clearScratch()
  assert(not PplHelpers.lowerRow(board, brain, 0, 3), "row 0 can't drop")
  assert(PplHelpers.lowerRow(board, brain, 1, 3), "PPL row 1 column 3 next to the hole at row 0 column 2")
  expectList(queuedCommands(brain), {1, 0, 0, 3, 3, 2}, "AILowerRow next to the hole waits a row lower")
  brain:clearQueues()
  assert(PplHelpers.lowerRow(board, brain, 2, 4), "PPL row 2 column 4 towards the hole at row 1 column 2")
  expectList(queuedCommands(brain), {1, 2, 0, 3, 4, 2}, "AILowerRow from a distance stays on the row")
  brain:clearQueues()
  assert(PplHelpers.lowerRow(board, brain, 2, 0), "column 0 next to a hole")
  expectList(queuedCommands(brain), {1, 1, 0, 3, 0, 1}, "the left side is empty, so to the right")
  brain:clearQueues()
  brain.totCheck[2] = -1
  brain.totCheck[5] = -1
  assert(not PplHelpers.lowerRow(board, brain, 2, 4), "locked columns block the way and their holes don't count")
  brain.totCheck[0] = -1
  assert(not PplHelpers.lowerRow(board, brain, 2, 0), "a locked column doesn't move")
  brain:clearScratch()
end

boardHelpersReadTheBoard()

local function horiMoveCheckCheckDetours()
  local _, stack = createMatch()
  -- a 1 slid from column 0 to 3 on PPL row 2 would cross two 1s stacked under it in column 2
  setBoard(stack, {
    {2, 3, 1, 4, 5, 6},
    {3, 4, 1, 5, 6, 2},
    {1, 2, 3, 4, 0, 0},
  })
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board
  board:refresh()
  brain:clearQueues()
  brain.cursorX = 0
  brain.cursorY = 2
  assert(PplHelpers.horiMoveCheckCheck(board, brain, 0, 3), "a detour around column 2")
  -- down 2, carry column 2's 1 to column 1 with the right cell (one right first), back up 2
  expectList(queuedMoves(brain), {4, 4, 2, 5, 3, 3}, "the detour's moves")
  expect(brain.cursorX, 1, "the cursor ends on the detour")

  brain:clearQueues()
  brain.cursorX = 0
  assert(not PplHelpers.horiMoveCheckCheck(board, brain, 0, 1), "column 1 has no pair")
  assert(not PplHelpers.horiMoveCheckCheck(board, brain, 4, 5), "an empty cell slides nothing")
end

horiMoveCheckCheckDetours()

---------------------------------------------------------------------------------------------------------------------
-- board scans (AI-SPEC §1.10)

local function boardScansFindFlashesHeightsAndStacks()
  local _, stack = createMatch()
  setBoard(stack, {
    {1, 2, 3, 4, 5, 6},
    {2, 3, 1, 0, 6, 0},
    {2, 0, 0, 0, 0, 0},
  })
  stack.panels[2][4].state = "swapping"
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board
  local face = stack.levelData.frameConstants.FACE
  board:refresh()
  brain.garbageRow = -1
  brain.l = 0
  brain.r = 5

  local heights = {}
  expect(PplHelpers.scrollCheck(board, brain, heights), 12, "AIScrollCheck total")
  expectList({heights[0], heights[1], heights[2], heights[3], heights[4], heights[5]}, {3, 2, 2, 2, 2, 1},
             "AIScrollCheck heights: a swapping empty cell counts")
  brain.garbageRow = 1
  expect(PplHelpers.scrollCheck(board, brain, nil), 6, "AIScrollCheck stops under the garbage")
  brain.garbageRow = -1

  -- AISetGarbage takes the board's row unless garbage is turning into panels
  board.garbageRow = 4
  PplHelpers.setGarbage(board, brain)
  expect(brain.garbageRow, 4, "AISetGarbage")
  board.garbageRow = -1
  board.cursorState = 2
  PplHelpers.setGarbage(board, brain)
  expect(brain.garbageRow, 4, "AISetGarbage frozen while garbage turns")
  brain.garbageRow = -1

  -- AIFlashCheck
  ---@param cells integer[][] PA {row, column} pairs to flash
  local function flash(cells)
    for row = 1, 3 do
      for column = 1, 6 do
        stack.panels[row][column].state = "normal"
      end
    end
    for _, cell in ipairs(cells) do
      local panel = stack.panels[cell[1]][cell[2]]
      panel.state = "matched"
      panel.timer = face + 10
    end
    board:refresh()
    return PplHelpers.flashCheck(board, brain)
  end
  assert(not flash({}), "no flash")
  expect(brain.direction, 0, "no flash direction")
  assert(flash({{1, 1}, {2, 1}, {3, 1}}), "a vertical flash")
  expectList({brain.direction, brain.where, brain.from, brain.to}, {11, 0, 0, 2}, "vertical flash fields")
  assert(flash({{2, 2}, {2, 3}, {2, 4}, {2, 5}}), "a horizontal flash")
  expectList({brain.direction, brain.where, brain.from, brain.to}, {22, 1, 1, 4}, "horizontal flash fields")
  assert(not flash({{2, 3}}), "a lone flashing cell ends the search")
  assert(flash({{1, 1}, {2, 1}, {3, 3}, {3, 4}, {3, 5}}), "a run of 2 is skipped")
  expectList({brain.direction, brain.where, brain.from, brain.to}, {22, 2, 2, 4}, "the flash after the run of 2")

  -- AIBoundaryCheck / AIVisionCheck: one panel per consecutive row
  flash({})
  setBoard(stack, {
    {1, 2, 0, 0, 0, 0},
    {0, 0, 0, 2, 0, 0},
    {2, 0, 0, 0, 0, 0},
  })
  board:refresh()
  brain.cursorY = 2
  brain:changeVision()
  expectList({brain.t, brain.b, brain.l, brain.r}, {4, 0, 0, 5}, "AIChangeVision")
  PplHelpers.visionCheck(board, brain)
  expect(brain.totCheck[1], 3, "colour 2 on three consecutive rows")
  expectList({brain.rowCheck[1][0], brain.rowCheck[1][1], brain.rowCheck[1][2]}, {0, 1, 2}, "colour 2 rows")
  expectList({brain.colCheck[1][0], brain.colCheck[1][1], brain.colCheck[1][2]}, {1, 3, 0}, "colour 2 columns")
  expect(brain.totCheck[0], 1, "colour 1 stops after one row")
  expect(brain.distance[0], 18, "AIVisionCheck resets the distances")
end

boardScansFindFlashesHeightsAndStacks()

---------------------------------------------------------------------------------------------------------------------
-- PplExecutor (AI-SPEC §1.6 moves, §1.7, INTEGRATION §A2)

local function executorTurnsMovesIntoInputs()
  local match, stack = createMatch()
  setBoard(stack, {{1, 2, 3, 4, 5, 6}})
  idleFrames(match, stack, 2)
  stack.cur_row = 1
  stack.cur_col = 3
  local cpu = newCpu(stack)
  local brain = cpu.brain
  brain.speed = 1

  queueMoves(brain, {1, 2, 3, 4})
  local inputs = executeFrames(match, stack, cpu, 16)
  expectList(withoutIdle(inputs), {LEFT, RIGHT, UP, DOWN}, "moves 1-4")
  expect(stack.cur_col, 3, "back on column 3")
  expect(stack.cur_row, 1, "back on row 1")

  queueMoves(brain, {5})
  inputs = executeFrames(match, stack, cpu, 8)
  expectList(withoutIdle(inputs), {SWAP}, "move 5 swaps")
  expect(stack.panels[1][3].color, 4, "the cursor pair swapped")
  expect(brain.moveHead, 1, "the swap was used up")

  -- a refused swap drops the plan
  stack.cur_row = 2
  queueMoves(brain, {5, 1})
  brain:addCommand(9)
  inputs = executeFrames(match, stack, cpu, 4)
  expectList(withoutIdle(inputs), {}, "two empty cells can't swap")
  expect(brain.totalCommand, 0, "the commands are dropped")
  assert(not brain:hasMoves(), "the moves are dropped")

  -- the retrying swap counts as done on two empty cells
  queueMoves(brain, {6})
  inputs = executeFrames(match, stack, cpu, 4)
  expectList(withoutIdle(inputs), {}, "nothing to swap")
  expect(brain.moveHead, 1, "move 6 on empty cells is done")

  -- move 8 re-centres the vision in 2D
  stack.cur_row = 9
  cpu.board:refresh()
  brain:setCursor()
  queueMoves(brain, {8})
  executeFrames(match, stack, cpu, 4)
  expectList({brain.t, brain.b}, {10, 6}, "move 8 is AIChangeVision")
end

executorTurnsMovesIntoInputs()

local function quickMovesPressEveryOtherFrame()
  local match, stack = createMatch()
  setBoard(stack, {{1, 2, 3, 4, 5, 6}})
  idleFrames(match, stack, 2)
  stack.cur_row = 1
  stack.cur_col = 5
  local cpu = newCpu(stack)
  local brain = cpu.brain

  queueMoves(brain, {11, 11, 11})
  brain.delay = 0
  local inputs = executeFrames(match, stack, cpu, 5)
  expectList(inputs, {LEFT, IDLE, LEFT, IDLE, LEFT}, "equal directions get an idle frame between them")
  expect(stack.cur_col, 2, "three columns in five frames")

  queueMoves(brain, {12, 11, 13})
  brain.delay = 0
  inputs = executeFrames(match, stack, cpu, 3)
  expectList(inputs, {RIGHT, LEFT, UP}, "different directions go every frame")

  -- a swap right after a swap waits while the first is queued
  stack.cur_row = 1
  queueMoves(brain, {15, 15})
  brain.delay = 0
  inputs = executeFrames(match, stack, cpu, 3)
  expectList(inputs, {SWAP, IDLE, SWAP}, "quick swaps wait for the queued one")

  -- what the idle frame avoids: a direction on two frames in a row is a hold, and moves only once
  local column = stack.cur_col
  stack:receiveConfirmedInput(RIGHT)
  match:run()
  stack:receiveConfirmedInput(RIGHT)
  match:run()
  expect(stack.cur_col, column + 1, "holding right moves once")
end

quickMovesPressEveryOtherFrame()

local function towerDropsTurnsWhileOneRuns()
  local match, stack = CylinderTestUtils.createMatch()
  idleFrames(match, stack, 2)
  stack.cur_col = 10
  local cpu = newCpu(stack)
  local brain = cpu.brain

  queueMoves(brain, {2, 2, 2})
  local inputs = {}
  for i = 1, 3 do
    -- every move comes due at once, faster than a turn
    brain.delay = 0
    inputs[i] = executeFrames(match, stack, cpu, 1)[1]
  end
  expectList(inputs, {RIGHT, IDLE, IDLE}, "turns pressed while the tower turns are dropped")
  assert(not brain:hasMoves(), "the dropped turns are used up anyway")
  idleFrames(match, stack, 4)
  expect(stack.cur_col, 11, "the tower turned once")

  -- quick moves have no delay of their own on the tower, and move 8 becomes a random move
  queueMoves(brain, {11})
  brain.delay = 0
  executeFrames(match, stack, cpu, 1)
  assert(brain.delay > 1, "quick moves keep the drawn delay on the tower")
  queueMoves(brain, {8})
  brain.delay = 0
  executeFrames(match, stack, cpu, 1)
  local randomMove = brain.moves[1]
  assert(randomMove >= 1 and randomMove <= 6, "move 8 is replaced by a random move, got " .. randomMove)
  expect(brain.moveHead, 0, "and runs on the next turn")
end

towerDropsTurnsWhileOneRuns()

local function raiseIsHeldUntilTheRaiseEnds()
  local match, stack = createMatch({allowManualRaise = true})
  setBoard(stack, {{1, 2, 3, 4, 5, 6}})
  idleFrames(match, stack, 2)
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local displacement = stack.displacement

  queueMoves(brain, {7, 1})
  brain:addCommand(9)
  brain.delay = 0
  local inputs = executeFrames(match, stack, cpu, 30)
  local held = 0
  while inputs[held + 1] == RAISE do
    held = held + 1
  end
  assert(held > 5, "raise is held while the stack raises, got " .. held .. " frames")
  for i = held + 1, #inputs do
    expect(inputs[i], IDLE, "frame " .. i .. " after the raise")
  end
  assert(stack.displacement < displacement, "the stack raised")
  expect(brain.totalCommand, 0, "a finished raise drops the plan")
  assert(not brain:hasMoves(), "and the moves")
end

raiseIsHeldUntilTheRaiseEnds()

---------------------------------------------------------------------------------------------------------------------
-- command expansion (AI-SPEC §1.6)

local function commandsExpandIntoMoves()
  local _, stack = createMatch()
  CylinderTestUtils.clearBoard(stack)
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board

  -- go to row 3, then slide the panel in column 0 to column 2
  brain:clearQueues()
  brain.cursorX = 2
  brain.cursorY = 5
  brain:addCommand(1, 3)
  brain:addCommand(3, 0, 2)
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {4, 4}, "command 1 first, alone")
  expect(brain.totalCommand, 1, "the slide waits")
  brain:finishMoves()
  brain.cursorY = 3
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {1, 1, 5, 2, 5}, "command 3 slides 0 -> 2")
  expect(brain.totalCommand, 0, "all expanded")

  -- PPL skips a row move before a slide that goes nowhere
  brain:clearQueues()
  brain:addCommand(1, 8)
  brain:addCommand(3, 2, 2)
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {}, "no moves")
  expect(brain.totalCommand, 0, "both used up")

  -- command 5: the last swap retries and the setup is done
  brain:clearQueues()
  brain.cursorX = 0
  brain.step = 1
  brain:addCommand(5, 4, 2)
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {2, 2, 2, 5, 1, 6}, "command 5")
  expect(brain.step, 2, "command 5 ends the setup")

  -- command 2, 9, 10, 11, 12
  brain:clearQueues()
  brain.cursorX = 1
  brain.step = 0
  brain:addCommand(2, 5)
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {2, 2, 2}, "command 2 to column 5 is the pair 4/5")
  brain:clearQueues()
  brain:addCommand(11)
  brain:addCommand(12)
  PplPlanner.expandCommands(board, brain)
  expect(brain.step, 2, "command 11")
  expectList(queuedMoves(brain), {7}, "command 12 raises")
  expect(brain.delay, 0, "right away")
  brain:clearQueues()
  brain:addCommand(9)
  PplPlanner.expandCommands(board, brain)
  brain:addCommand(10)
  brain:finishMoves()
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {8}, "command 10")

  -- command 14 waits n frames and stays queued meanwhile
  brain:clearQueues()
  brain:addCommand(14, 2)
  brain:addCommand(9)
  for i = 1, 2 do
    PplPlanner.expandCommands(board, brain)
    expect(brain.totalCommand, 2, "still waiting after " .. i)
  end
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {5}, "the wait is over")
end

commandsExpandIntoMoves()

local function towerCommandsKeepTheirPanelsWhenItTurns()
  local _, stack = CylinderTestUtils.createMatch()
  stack.cur_col = 10
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board
  board:refresh()

  brain:clearQueues()
  brain:addCommand(3, 0, 2)
  brain:addCommand(2, -2)
  expectList(queuedCommands(brain), {3, 5, 7, 2, 5, 0}, "board columns stored; command 2 clamped in the view first")

  -- the tower turned right one column since planning: the panels are now one view column further left
  stack.cur_col = 11
  board:refresh()
  brain:setCursor()
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {1, 1, 1, 1, 1, 5, 2, 5}, "the slide starts at view column -1")
  brain:finishMoves()
  PplPlanner.expandCommands(board, brain)
  expectList(queuedMoves(brain), {1, 1, 1, 1, 1}, "command 2 to view column -1")
end

towerCommandsKeepTheirPanelsWhenItTurns()

---------------------------------------------------------------------------------------------------------------------
-- planners

local function possibleRowPlansHorizontalThrees()
  local _, stack = createMatch()
  local cpu = newCpu(stack)
  local brain = cpu.brain
  local board = cpu.board
  brain.l = 0
  brain.r = 5

  ---@param colors integer[]
  ---@return integer[] commands
  local function plan(colors)
    setBoard(stack, {colors})
    board:refresh()
    brain:clearQueues()
    if PplCombos.possibleRow(board, brain, 0) then
      return queuedCommands(brain)
    end
    return {}
  end
  expectList(plan({1, 1, 2, 3, 1, 4}), {3, 4, 2}, "a pair on the left: slide the third next to it")
  expectList(plan({1, 2, 3, 1, 1, 4}), {3, 0, 2}, "a pair on the right: slide the first next to it")
  local pair = board.clock % 2 == 0 and {8, 0, 2} or {8, 2, 4}
  expectList(plan({1, 2, 1, 3, 1, 4}), pair, "no pair: pack two by the frame parity")
  expectList(plan({1, 2, 3, 4, 5, 6}), {}, "no three of a colour")
  setBoard(stack, {{1, 1, 2, 3, 1, 4}})
  stack.panels[1][3].isGarbage = true
  board:refresh()
  assert(not PplCombos.possibleRow(board, brain, 0), "garbage in column 2 blocks the row")
end

possibleRowPlansHorizontalThrees()

local function cpuFindsAndClearsARowThree()
  local match, stack = createMatch()
  setBoard(stack, {
    {1, 1, 2, 3, 1, 4},
    {2, 3, 4, 5, 6, 2},
  })
  local cpu = newCpu(stack, {seed = 7, level = 10})
  local matched = false
  for _ = 1, 300 do
    stack:receiveConfirmedInput(cpu:getInput())
    match:run()
    for column = 1, 3 do
      if stack.panels[1][column].state == "matched" then
        matched = true
      end
    end
    if matched then
      break
    end
  end
  assert(matched, "the CPU walked down to the row and slid the third 1 next to the pair")
  expect(stack.panels[1][1].color, 1, "the match is the three 1s")
end

cpuFindsAndClearsARowThree()

---------------------------------------------------------------------------------------------------------------------
-- whole games: endless stacks, the CPU alone, three minutes

local GAME_FRAMES = 3 * 60 * 60

---@class PlayOptions
---@field mutationCheckEvery integer? compare rollback copies around getInput on every n-th frame
---@field measureAllocationAfter integer? count memory allocated by getInput after this many frames

-- Plays until three minutes have passed or the stack topped out. Allocation is measured with the JIT off: compiling
-- traces allocates too (mostly for the engine's own code), which is not garbage the CPU makes every frame.
---@param match Match
---@param stack Stack
---@param cpu PplCpu
---@param options PlayOptions
---@return integer frames
---@return number allocatedKB by getInput after measureAllocationAfter
---@return boolean usedPossibleRow
local function play(match, stack, cpu, options)
  local allocated = 0
  local usedPossibleRow = false
  local measuring = false
  local frame = 0
  while frame < GAME_FRAMES and not stack:game_ended() do
    frame = frame + 1
    if options.measureAllocationAfter and frame == options.measureAllocationAfter then
      jit.off()
      collectgarbage("collect")
      collectgarbage("stop")
      measuring = true
    end
    local check = options.mutationCheckEvery and frame % options.mutationCheckEvery == 0
    local before
    if check then
      before = {}
      stack:saveIntoRollbackCopy(before)
    end

    local memory = measuring and collectgarbage("count")
    local input = cpu:getInput()
    if measuring then
      allocated = allocated + collectgarbage("count") - memory
    end

    if check then
      local after = {}
      stack:saveIntoRollbackCopy(after)
      assert(tableUtils.deep_content_equal(before, after), "getInput changed the stack on frame " .. frame)
    end
    if cpu.brain.lastPlan == 1 then
      usedPossibleRow = true
    end
    stack:receiveConfirmedInput(input)
    match:run()
  end
  if measuring then
    collectgarbage("restart")
    jit.on()
  end
  return frame, allocated, usedPossibleRow
end

local function cpuPlaysATwoDimensionalGame()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 1)
  local stack = match.stacks[1]
  ---@cast stack Stack
  local cpu = newCpu(stack, {seed = 3, level = 8})
  -- InitAI starts lastPlan at 1, PossibleRow's id
  cpu.brain.lastPlan = 0
  local frames, allocated, usedPossibleRow = play(match, stack, cpu, {mutationCheckEvery = 9, measureAllocationAfter = 1800})
  print(string.format("PPL CPU 2D: %d frames, %d panels cleared, game over: %s, %.2f KB allocated by getInput",
                      frames, stack.panels_cleared, tostring(stack:game_ended()), allocated))
  -- with only PossibleRow and the fallback the 2D CPU clears the threes PA's rows happen to hold and then tops out:
  -- PA's generator rarely puts three of a colour in one row
  assert(stack.panels_cleared >= 15, "the CPU should clear panels, cleared " .. stack.panels_cleared)
  assert(usedPossibleRow, "the CPU should find threes on its cursor row")
  assert(allocated == 0, string.format("getInput allocated %.2f KB over %d frames", allocated, frames - 1800))

  -- the same seeds play the same game
  local replayMatch = StackReplayTestingUtils.createEndlessMatch(nil, nil, 1)
  local replayStack = replayMatch.stacks[1]
  ---@cast replayStack Stack
  play(replayMatch, replayStack, newCpu(replayStack, {seed = 3, level = 8}), {})
  expect(#replayStack.confirmedInput, #stack.confirmedInput, "input count of the second run")
  for i = 1, #stack.confirmedInput do
    if replayStack.confirmedInput[i] ~= stack.confirmedInput[i] then
      error("the second run pressed something else on frame " .. i)
    end
  end
end

cpuPlaysATwoDimensionalGame()

local function cpuPlaysATowerGame()
  ---@return Match
  ---@return Stack
  local function start()
    return CylinderTestUtils.createMatch({passiveRaise = true, seed = 5})
  end
  local match, stack = start()
  local cpu = newCpu(stack, {seed = 11, level = 10})
  local frames, allocated = play(match, stack, cpu, {mutationCheckEvery = 9, measureAllocationAfter = 1800})
  print(string.format("PPL CPU 3D: %d frames, %d panels cleared, game over: %s, %.2f KB allocated by getInput",
                      frames, stack.panels_cleared, tostring(stack:game_ended()), allocated))
  assert(stack.panels_cleared >= 60, "the CPU should clear panels on the tower, cleared " .. stack.panels_cleared)
  assert(allocated == 0, string.format("getInput allocated %.2f KB over %d frames", allocated, frames - 1800))

  local replayMatch, replayStack = start()
  play(replayMatch, replayStack, newCpu(replayStack, {seed = 11, level = 10}), {})
  expect(#replayStack.confirmedInput, #stack.confirmedInput, "input count of the second tower run")
  for i = 1, #stack.confirmedInput do
    if replayStack.confirmedInput[i] ~= stack.confirmedInput[i] then
      error("the second tower run pressed something else on frame " .. i)
    end
  end
end

cpuPlaysATowerGame()

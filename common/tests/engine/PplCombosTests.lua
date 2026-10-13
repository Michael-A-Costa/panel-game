local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")
local PplCpu = require("common.engine.computerPlayers.PplCpu.PplCpu")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplCombos = require("common.engine.computerPlayers.PplCpu.PplCombos")
local PplPresets = require("common.engine.computerPlayers.PplCpu.PplPresets")

-- Tests for the PPL CPU's plain-match and combo planners (AI-SPEC §2.4, phase 2b "combos" of docs/stadium/PLAN.md):
-- AIPossibleCol, AIComboCheck, AICombo3a, AICombo3b, AIComboX and AICombo45 on fixed boards, then whole games.
-- Boards are given in PA rows bottom up (PA row 1 = PPL row 0) and PA colours; commands are read back as
-- code, first, second triples, columns 0-based (view columns in 2D, board columns on the tower).

-- Panel Attack's shock panel colour, and its colour index in the CPU's scratch tables (PPL's "!", type 7)
local SHOCK = 8
local SHOCK_INDEX = 6

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
    error(what .. ": expected {" .. table.concat(expected, ", ") .. "}, got {" .. table.concat(actual, ", ") .. "}")
  end
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
---@return Match
---@return Stack
local function createMatch()
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules
  rules.doCountdown = false
  rules.stackSetupModifications.behaviours = {passiveRaise = false, allowManualRaise = false}
  local match = Match(GeneratorSource(1, false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(5), false, "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)
  return match, stack
end

-- empties the board, lays out rows bottom up (rows[i] = colours of PA row i from firstColumn, 0 = empty) and puts
-- the cursor's left cell on PA (cursorRow, cursorColumn)
---@param stack Stack
---@param rows integer[][]
---@param cursorRow integer
---@param cursorColumn integer
---@param firstColumn integer?
local function setBoard(stack, rows, cursorRow, cursorColumn, firstColumn)
  CylinderTestUtils.clearBoard(stack)
  for row, colors in ipairs(rows) do
    local columns = {}
    for i, color in ipairs(colors) do
      if color ~= 0 then
        columns[(firstColumn or 1) + i - 1] = color
      end
    end
    CylinderTestUtils.setColors(stack, row, columns)
  end
  stack.cur_row = cursorRow
  stack.cur_col = cursorColumn
end

-- A CPU playing the full planner cascade with a Stadium opponent's settings, without the Stadium opening move.
---@param stack Stack
---@param difficulty integer
---@param stage integer
---@return PplCpu
local function newCpu(stack, difficulty, stage)
  local cpu = PplCpu(stack, {seed = 1, level = 1})
  cpu.brain:applySettings(PplPresets.forStage(difficulty, stage))
  return cpu
end

-- What UpdateAI does before the combo planners: snapshot, vision window, AIBoundaryCheck, AIComboCheck.
---@param cpu PplCpu
local function prepare(cpu)
  local board = cpu.board
  local brain = cpu.brain
  board:refresh()
  brain:setCursor()
  brain:clearQueues()
  brain:changeVision()
  PplHelpers.visionCheck(board, brain)
  PplCombos.comboCheck(board, brain)
end

---@class MatchLog
---@field sizes integer[] size of every match the stack made, in order

-- records the size of every match the stack makes
---@param stack Stack
---@return MatchLog
local function logMatches(stack)
  local log = {sizes = {}}
  stack:connectSignal("matched", log, function(subscriber, _, _, _, comboSize)
    subscriber.sizes[#subscriber.sizes + 1] = comboSize
  end)
  return log
end

-- Lets the CPU play (planning included) until the stack made its first match or frames ran out.
---@param match Match
---@param stack Stack
---@param cpu PplCpu
---@param log MatchLog
---@param frames integer
---@return integer? size of the first match
local function playUntilMatch(match, stack, cpu, log, frames)
  for _ = 1, frames do
    stack:receiveConfirmedInput(cpu:getInput())
    match:run()
    if #log.sizes > 0 then
      return log.sizes[1]
    end
  end
  return nil
end

---@param stack Stack
---@param column integer PA column
---@param fromRow integer PA row
---@param toRow integer PA row
---@return boolean
local function columnMatched(stack, column, fromRow, toRow)
  for row = fromRow, toRow do
    if stack.panels[row][column].state ~= "matched" then
      return false
    end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- AIPossibleCol

-- the cursor on PA row 2, columns 3/4: a 1 under the cursor's left cell, one in the row above at column 2, one two
-- rows up at column 4
local POSSIBLE_COL_BOARD = {
  {2, 3, 4, 5, 6, 2},
  {3, 4, 1, 5, 6, 3},
  {4, 1, 5, 6, 2, 4},
  {5, 6, 2, 1, 3, 5},
}

local function possibleColPlansAColumnThroughTheCursor()
  local match, stack = createMatch()
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain

  setBoard(stack, POSSIBLE_COL_BOARD, 2, 3)
  prepare(cpu)
  assert(PplCombos.possibleCol(cpu.board, brain), "a vertical 3 through the cursor's left cell")
  -- neither panel is above the cursor and the cursor's panel can slide under the lower one: move it there
  expectList(queuedCommands(brain), {3, 2, 1, 1, 3, 0, 4, 3, 1}, "slide the cursor's 1 left, then the top 1 over")
  expect(brain.rowCheck[0][0], 2, "PPL's scratch slot 0: the row above")
  expect(brain.colCheck[0][1], 3, "PPL's scratch slot 1: the column two rows up")

  -- one of them right above the cursor's panel: only the other moves
  setBoard(stack, {
    {2, 3, 4, 5, 6, 2},
    {3, 4, 1, 5, 6, 3},
    {4, 5, 1, 6, 2, 4},
    {5, 6, 2, 3, 1, 5},
  }, 2, 3)
  prepare(cpu)
  assert(PplCombos.possibleCol(cpu.board, brain), "a 1 above the cursor's 1")
  expectList(queuedCommands(brain), {1, 3, 0, 4, 4, 2}, "bring the top 1 over the stack")

  -- one above and one below the cursor row when two rows up has none
  setBoard(stack, {
    {2, 3, 1, 5, 6, 2},
    {3, 4, 6, 1, 5, 3},
    {4, 5, 2, 1, 2, 4},
  }, 2, 3)
  prepare(cpu)
  assert(PplCombos.possibleCol(cpu.board, brain), "one above and one below")
  -- the right cell (column 3) has the 1; the one above is in the same column, the one below moves under it
  expectList(queuedCommands(brain), {1, 0, 0, 4, 2, 3}, "slide the bottom 1 under the pair")

  setBoard(stack, POSSIBLE_COL_BOARD, 1, 3)
  prepare(cpu)
  assert(not PplCombos.possibleCol(cpu.board, brain), "never on the bottom row")

  -- the whole CPU: PossibleRow finds nothing on the cursor row, PossibleCol plans and the three 1s match in column 2
  setBoard(stack, POSSIBLE_COL_BOARD, 2, 3)
  brain:clearQueues()
  local log = logMatches(stack)
  stack:receiveConfirmedInput(cpu:getInput())
  match:run()
  expect(brain.lastPlan, 2, "the cascade picked AIPossibleCol")
  expect(playUntilMatch(match, stack, cpu, log, 300), 3, "the CPU made a 3")
  assert(columnMatched(stack, 2, 2, 4), "the three 1s in PA column 2")
end

possibleColPlansAColumnThroughTheCursor()

---------------------------------------------------------------------------------------------------------------------
-- AIComboCheck, AICombo3a, AICombo3b

-- the cursor on PA row 3 (PPL row 2), columns 3/4; 1s on PPL rows 0, 1, 2 in columns 4, 1, 5 and no other colour
-- in three rows in a row
local THREE_BOARD = {
  {2, 3, 2, 3, 1, 2},
  {4, 1, 5, 4, 5, 6},
  {3, 2, 4, 2, 3, 1},
}

local function comboCheckRanksReachableStacks()
  local _, stack = createMatch()
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain

  setBoard(stack, THREE_BOARD, 3, 3)
  prepare(cpu)
  expect(brain.totCheck[0], 3, "three 1s in consecutive rows")
  -- the cursor is on the top entry's row: distance to it, (2, 5) is two columns right of the cursor pair
  expect(brain.distance[0], 2, "distance of the 1s")
  expect(brain.distance[1], 18, "fewer than three 2s")
  expect(brain.bestColor, 0, "the 1s are the best colour")

  -- PPL: with the cursor row inside the list it measures sideways to the row number (AI-SPEC §2.4)
  setBoard(stack, {
    {2, 3, 2, 1, 3, 2},
    {4, 1, 5, 4, 5, 4},
    {3, 2, 3, 2, 3, 1},
    {5, 4, 1, 5, 4, 5},
  }, 3, 1)
  prepare(cpu)
  expect(brain.totCheck[0], 4, "four 1s")
  -- the 1 on the cursor row is 4 columns right of the pair at 0/1; PPL counts row 2 as column 2: 1 column
  expect(brain.distance[0], 1, "PPL's row-as-column distance")

  -- the 1 in row 1 can't slide over a hole: unreachable
  setBoard(stack, THREE_BOARD, 3, 3)
  stack.panels[1][3]:clear(true, true)
  prepare(cpu)
  expect(brain.distance[0], 18, "a hole in the way")
  expect(brain.bestColor, 18, "nothing reachable")
  assert(not PplCombos.combo3a(cpu.board, brain), "Combo3a needs a reachable colour")
  assert(PplCombos.combo3b(cpu.board, brain), "Combo3b takes any colour with three")
  expectList(queuedCommands(brain), {1, 2, 0, 4, 5, 4, 1, 1, 0, 4, 1, 4}, "Combo3b with command 4")
end

comboCheckRanksReachableStacks()

local function combo3aStacksTheNearestColour()
  local match, stack = createMatch()
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain

  setBoard(stack, THREE_BOARD, 3, 3)
  prepare(cpu)
  assert(PplCombos.combo3a(cpu.board, brain), "three 1s near the cursor")
  -- visiting order from the cursor row: rows 2, 1, 0; the column of the last visited (row 0, column 4) is the target
  expectList(queuedCommands(brain), {1, 2, 0, 3, 5, 4, 1, 1, 0, 3, 1, 4}, "slide rows 2 and 1 over row 0's 1")

  -- PPL: with four entries it sorts the rows of entries 1-3 but moves entries 0-2 (AI-SPEC §2.4)
  setBoard(stack, {
    {2, 3, 2, 1, 3, 2},
    {4, 1, 5, 4, 5, 4},
    {3, 2, 3, 2, 3, 1},
    {5, 4, 1, 5, 4, 5},
  }, 3, 1)
  prepare(cpu)
  assert(PplCombos.combo3a(cpu.board, brain), "four 1s")
  -- rows 1, 2, 3 sorted from row 2: copy indices 1, 0, 2; used on the list they are entries 1, 0, 2 and the target
  -- is entry 2's column 5 instead of the top three's
  expectList(queuedCommands(brain), {1, 1, 0, 3, 1, 5, 1, 0, 0, 3, 3, 5}, "PPL's index mix-up")

  -- the whole CPU makes the 3
  setBoard(stack, THREE_BOARD, 3, 3)
  brain:clearQueues()
  local log = logMatches(stack)
  stack:receiveConfirmedInput(cpu:getInput())
  match:run()
  expect(brain.lastPlan, 5, "the cascade picked AICombo3a")
  expect(playUntilMatch(match, stack, cpu, log, 400), 3, "the CPU made a 3")
  assert(columnMatched(stack, 5, 1, 3), "the three 1s in PA column 5")
end

combo3aStacksTheNearestColour()

local function combo3bPlanRuns()
  local match, stack = createMatch()
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain

  setBoard(stack, THREE_BOARD, 3, 3)
  prepare(cpu)
  assert(PplCombos.combo3b(cpu.board, brain), "exactly three 1s")
  expectList(queuedCommands(brain), {1, 2, 0, 4, 5, 4, 1, 1, 0, 4, 1, 4}, "the same stack, command 4")
  -- the CPU expands a queued plan before it plans anything new
  local log = logMatches(stack)
  expect(playUntilMatch(match, stack, cpu, log, 400), 3, "Combo3b's plan made a 3")
  assert(columnMatched(stack, 5, 1, 3), "the three 1s in PA column 5")

  setBoard(stack, {
    {2, 3, 2, 1, 3, 2},
    {4, 1, 5, 4, 5, 4},
    {3, 2, 3, 2, 3, 1},
    {5, 4, 1, 5, 4, 5},
  }, 3, 1)
  prepare(cpu)
  assert(not PplCombos.combo3b(cpu.board, brain), "four 1s are not exactly three")
end

combo3bPlanRuns()

---------------------------------------------------------------------------------------------------------------------
-- AIComboX

local function comboXStacksShockPanels()
  local _, stack = createMatch()
  local board = {}
  for row, colors in ipairs(THREE_BOARD) do
    board[row] = {}
    for column, color in ipairs(colors) do
      board[row][column] = color == 1 and SHOCK or color
    end
  end

  -- PossibleRow's and PossibleCol's colour loops see shock panels too, so the cursor sits away from them
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain
  setBoard(stack, board, 3, 3)
  prepare(cpu)
  expect(brain.totCheck[SHOCK_INDEX], 3, "three shock panels, colour index 6 like PPL's !")
  assert(PplCombos.comboX(cpu.board, brain), "three shock panels")
  expectList(queuedCommands(brain), {1, 2, 0, 4, 5, 4, 1, 1, 0, 4, 1, 4}, "ComboX is Combo3b for shock panels")
  setBoard(stack, THREE_BOARD, 3, 3)
  prepare(cpu)
  assert(not PplCombos.comboX(cpu.board, brain), "plain colours are not for ComboX")

  -- a combo character (chainLimit 0) plans with ComboX, the others with Combo3a
  setBoard(stack, board, 3, 3)
  brain:clearQueues()
  brain:applySettings({speed = 20, character = 0, chainLimit = -1, think = 0})
  stack:receiveConfirmedInput(cpu:getInput())
  expect(brain.lastPlan, 5, "chainLimit -1: Combo3a")

  local comboMatch, comboStack = createMatch()
  setBoard(comboStack, board, 3, 3)
  local comboCpu = newCpu(comboStack, 2, 1)
  comboCpu.brain:applySettings({speed = 20, character = 0, chainLimit = 0, think = 0})
  local log = logMatches(comboStack)
  comboStack:receiveConfirmedInput(comboCpu:getInput())
  comboMatch:run()
  expect(comboCpu.brain.lastPlan, 9, "chainLimit 0: ComboX")
  expect(playUntilMatch(comboMatch, comboStack, comboCpu, log, 400), 3, "the CPU matched the shock panels")
  assert(columnMatched(comboStack, 5, 1, 3), "the three shock panels in PA column 5")
  expect(comboStack.panels[1][5].color, SHOCK, "shock panels")
end

comboXStacksShockPanels()

---------------------------------------------------------------------------------------------------------------------
-- AICombo45

-- 1s on PPL rows 0-3 in columns 2, 3, 0, 4 (and row 4 column 5 for the 5); the cursor on PA row 3, columns 3/4
local FOUR_BOARD = {
  {3, 4, 1, 5, 6, 2},
  {4, 5, 6, 1, 2, 3},
  {1, 6, 2, 3, 4, 5},
  {5, 2, 3, 4, 1, 6},
}
local FIVE_BOARD = {
  {3, 4, 1, 5, 6, 2},
  {4, 5, 6, 1, 2, 3},
  {1, 6, 2, 3, 4, 5},
  {5, 2, 3, 4, 1, 6},
  {2, 3, 4, 6, 5, 1},
}

local function combo45StacksFourAndFive()
  local match, stack = createMatch()
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain

  setBoard(stack, FOUR_BOARD, 3, 3)
  prepare(cpu)
  expect(brain.totCheck[0], 4, "four 1s")
  assert(not PplCombos.combo45(cpu.board, brain, 5), "no colour with five")
  assert(PplCombos.combo45(cpu.board, brain, 4), "four 1s")
  -- target: row 0's column 2 (the cursor's left cell is as near to it as its right cell to row 1's column 3);
  -- visiting order rows 2, 1, 0, 3 without entry 2, then entry 2 (the middle) last
  expectList(queuedCommands(brain), {1, 1, 0, 4, 3, 2, 1, 3, 0, 4, 4, 2, 1, 2, 0, 4, 0, 2}, "four into column 2")
  local log = logMatches(stack)
  expect(playUntilMatch(match, stack, cpu, log, 600), 4, "one match of four")
  assert(columnMatched(stack, 3, 1, 4), "the four 1s in PA column 3")

  local fiveMatch, fiveStack = createMatch()
  local fiveCpu = newCpu(fiveStack, 2, 1)
  setBoard(fiveStack, FIVE_BOARD, 3, 3)
  prepare(fiveCpu)
  expect(fiveCpu.brain.totCheck[0], 5, "five 1s")
  assert(PplCombos.combo45(fiveCpu.board, fiveCpu.brain, 5), "five 1s")
  expectList(queuedCommands(fiveCpu.brain), {1, 1, 0, 4, 3, 2, 1, 3, 0, 4, 4, 2, 1, 4, 0, 4, 5, 2, 1, 2, 0, 4, 0, 2},
             "five into column 2, the middle last")
  local fiveLog = logMatches(fiveStack)
  expect(playUntilMatch(fiveMatch, fiveStack, fiveCpu, fiveLog, 800), 5, "one match of five")
  assert(columnMatched(fiveStack, 3, 1, 5), "the five 1s in PA column 3")
end

combo45StacksFourAndFive()

-- With bit 0x01 the cascade rolls for a 5 (1 in 7), else for a 4 (1 in 5), before Combo3a; seeds where the roll hits
-- plan the 4. The cursor on PA row 2, columns 1/2, where PossibleRow and PossibleCol find nothing.
local function cascadeRollsForTheFour()
  local found = false
  for seed = 1, 40 do
    local _, stack = createMatch()
    setBoard(stack, FOUR_BOARD, 2, 1)
    local cpu = PplCpu(stack, {seed = seed, level = 1})
    cpu.brain:applySettings(PplPresets.forStage(2, 1))
    stack:receiveConfirmedInput(cpu:getInput())
    if cpu.brain.lastPlan == 4 then
      found = true
      break
    end
    expect(cpu.brain.lastPlan, 5, "a missed roll falls through to Combo3a, seed " .. seed)
  end
  assert(found, "some seed rolls the 4")

  -- without bit 0x01 never
  local _, stack = createMatch()
  setBoard(stack, FOUR_BOARD, 2, 1)
  local cpu = PplCpu(stack, {seed = 1, level = 1})
  cpu.brain:applySettings({speed = 20, character = 0, chainLimit = -1, think = 0})
  stack:receiveConfirmedInput(cpu:getInput())
  expect(cpu.brain.lastPlan, 5, "no bit 0x01: Combo3a")
end

cascadeRollsForTheFour()

---------------------------------------------------------------------------------------------------------------------
-- the tower

local function towerCombo3aStacksLeftOfTheCursor()
  local match, stack = CylinderTestUtils.createMatch()
  -- the cursor on board columns 10/11 (view 4/5); view columns 0-3 are board columns 6-9
  setBoard(stack, {
    {2, 1, 2, 3},
    {4, 5, 4, 1},
    {1, 3, 5, 3},
  }, 3, 10, 6)
  local cpu = newCpu(stack, 2, 1)
  local brain = cpu.brain
  prepare(cpu)
  expect(brain.bestColor, 0, "the 1s")
  -- the cursor's left cell is view column 4, the bottom 1 in view column 1: 4 sideways on the top row
  expect(brain.distance[0], 4, "distance on the tower")
  assert(PplCombos.combo3a(cpu.board, brain), "three 1s left of the cursor")
  -- view columns 0 -> 1 and 3 -> 1, stored as 0-based board columns 5 -> 6 and 8 -> 6
  expectList(queuedCommands(brain), {1, 2, 0, 3, 5, 6, 1, 1, 0, 3, 8, 6}, "stack into view column 1")

  brain:clearQueues()
  local log = logMatches(stack)
  stack:receiveConfirmedInput(cpu:getInput())
  match:run()
  expect(brain.lastPlan, 5, "the cascade picked AICombo3a on the tower")
  expect(playUntilMatch(match, stack, cpu, log, 600), 3, "the CPU turned the tower and made the 3")
  assert(columnMatched(stack, 7, 1, 3), "the three 1s in board column 7")
end

towerCombo3aStacksLeftOfTheCursor()

---------------------------------------------------------------------------------------------------------------------
-- whole games: 2D endless, three minutes

local GAME_FRAMES = 3 * 60 * 60
-- what the CPU cleared in this game with only AIPossibleRow and the fallback (phase 2a)
local CLEARED_WITHOUT_COMBOS = 21

---@class ComboGameResult
---@field frames integer
---@field allocated number KB allocated by getInput after the warm-up
---@field biggestMatch integer

-- Plays until three minutes have passed or the stack topped out, checking now and then that getInput leaves the
-- stack alone and, after a warm-up, that it allocates nothing (with the JIT off: compiling traces allocates too).
---@param match Match
---@param stack Stack
---@param cpu PplCpu
---@return ComboGameResult
local function play(match, stack, cpu)
  local log = logMatches(stack)
  local warmUp = 1800
  local allocated = 0
  local measuring = false
  local frame = 0
  while frame < GAME_FRAMES and not stack:game_ended() do
    frame = frame + 1
    if frame == warmUp then
      jit.off()
      collectgarbage("collect")
      collectgarbage("stop")
      measuring = true
    end
    local check = frame % 9 == 0
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
    stack:receiveConfirmedInput(input)
    match:run()
  end
  if measuring then
    collectgarbage("restart")
    jit.on()
  end
  local biggest = 0
  for _, size in ipairs(log.sizes) do
    biggest = math.max(biggest, size)
  end
  return {frames = frame, allocated = allocated, biggestMatch = biggest}
end

local function normalStageFivePlaysATwoDimensionalGame()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 1)
  local stack = match.stacks[1]
  ---@cast stack Stack
  -- Normal stage 5: character 0x03 (4/5 combos, raising), speed 18, chainLimit 0 (a combo character)
  local cpu = PplCpu(stack, {seed = 3, difficulty = 2, stage = 5})
  local result = play(match, stack, cpu)
  print(string.format("PPL CPU 2D with combos (Normal 5): %d frames, %d panels cleared, biggest match %d, game over: %s,"
                      .. " %.2f KB allocated by getInput", result.frames, stack.panels_cleared, result.biggestMatch,
                      tostring(stack:game_ended()), result.allocated))
  assert(stack.panels_cleared >= 2 * CLEARED_WITHOUT_COMBOS,
         "with the combo planners the CPU should clear clearly more than " .. CLEARED_WITHOUT_COMBOS .. ", cleared "
         .. stack.panels_cleared)
  assert(result.biggestMatch >= 4, "a bit 0x01 CPU should make a 4+ combo, biggest was " .. result.biggestMatch)
  assert(result.allocated == 0, string.format("getInput allocated %.2f KB", result.allocated))
end

normalStageFivePlaysATwoDimensionalGame()

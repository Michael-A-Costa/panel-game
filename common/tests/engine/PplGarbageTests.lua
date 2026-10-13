local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")
local PplCpu = require("common.engine.computerPlayers.PplCpu.PplCpu")
local PplBoard = require("common.engine.computerPlayers.PplCpu.PplBoard")
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplGarbage = require("common.engine.computerPlayers.PplCpu.PplGarbage")

-- Tests for the garbage and stack height planners of the PPL CPU (AI-SPEC §2.3, §2.5 AIVolumeCheck): each on a fixed
-- board where PPL would fire it, then the CPU driving its stack, and a whole game against an attack engine.

local IDLE = KeyDataEncoding.idle

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

-- commands still queued, flattened as code, first, second, code, ...; columns as the view columns they are now
---@param board PplBoard
---@param brain PplBrain
---@return integer[]
local function queuedCommands(board, brain)
  local columnFirst = {[2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true}
  local columnSecond = {[3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true}
  local commands = {}
  for slot = brain.comHead + 1, brain.comTail do
    local code = brain.commandCodes[slot]
    local first = brain.commandFirst[slot]
    local second = brain.commandSecond[slot]
    if columnFirst[code] then
      first = board:toViewColumn(first)
    end
    if columnSecond[code] then
      second = board:toViewColumn(second)
    end
    commands[#commands + 1] = code
    commands[#commands + 1] = first
    commands[#commands + 1] = second
  end
  return commands
end

-- a 2D endless match for fixed boards: no countdown and no rising
---@param options {allowManualRaise: boolean?}?
---@return Match
---@return Stack
local function createMatch(options)
  options = options or {}
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS).matchRules
  rules.doCountdown = false
  rules.stackSetupModifications.behaviours = {passiveRaise = false, allowManualRaise = options.allowManualRaise or false}
  local match = Match(GeneratorSource(1, false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(5), false, "controller")
  ---@cast stack Stack
  match:start()
  stack:setMaxRunsPerFrame(1)
  return match, stack
end

-- empties the board and lays out rows bottom up: rows[i] holds the colours of PA row i (0 = empty) from firstColumn
---@param stack Stack
---@param rows integer[][]
local function setBoard(stack, rows)
  CylinderTestUtils.clearBoard(stack)
  for row, colors in ipairs(rows) do
    local columns = {}
    for i, color in ipairs(colors) do
      columns[i] = color
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
---@return boolean
local function garbageSettled(stack)
  if stack.shake_time > 0 then
    return false
  end
  for row = 1, #stack.panels do
    for column = 1, stack.width do
      local panel = stack.panels[row][column]
      if panel.isGarbage and panel.state ~= "normal" then
        return false
      end
    end
  end
  return true
end

-- drops a block of garbage onto the board and lets it land and stop shaking
---@param match Match
---@param stack Stack
---@param width integer
---@param column integer board column (1-based) of its left edge
local function dropGarbage(match, stack, width, column)
  stack:dropGarbage(width, 1, false, column)
  for _ = 1, 300 do
    idleFrames(match, stack, 1)
    if garbageSettled(stack) then
      return
    end
  end
  error("the garbage did not settle")
end

---@param stack Stack
---@return boolean
local function anyGarbageMatched(stack)
  for row = 1, #stack.panels do
    for column = 1, stack.width do
      local panel = stack.panels[row][column]
      if panel.isGarbage and panel.state == "matched" then
        return true
      end
    end
  end
  return false
end

-- the CPU plays until done() holds; returns the frames it took, or nil after frameCap
---@param match Match
---@param stack Stack
---@param cpu PplCpu
---@param frameCap integer
---@param done fun(): boolean
---@param onFrame fun()?
---@return integer?
local function drive(match, stack, cpu, frameCap, done, onFrame)
  for frame = 1, frameCap do
    stack:receiveConfirmedInput(cpu:getInput())
    match:run()
    if onFrame then
      onFrame()
    end
    if done() then
      return frame
    end
  end
  return nil
end

-- a fresh CPU whose brain sees the board now, as the planner does at the start of a planning frame
---@param stack Stack
---@param options PplCpuOptions?
---@return PplCpu
local function newCpu(stack, options)
  local cpu = PplCpu(stack, options or {seed = 1, level = 10})
  cpu.board:refresh()
  cpu.brain:setCursor()
  PplHelpers.setGarbage(cpu.board, cpu.brain)
  return cpu
end

-- SPEC §9: board column (1-based) under view column v with the cursor on board column curCol
---@param curCol integer
---@param viewColumn integer
---@return integer
local function boardColumnOfView(curCol, viewColumn)
  return ((curCol - 1) + (viewColumn - 4)) % 18 + 1
end

---------------------------------------------------------------------------------------------------------------------
-- AIClearGarbage (§2.3)

local function clearGarbageMakesARowUnderTheGarbage()
  local match, stack = createMatch()
  setBoard(stack, {
    {2, 3, 4, 5, 6, 2},
    {1, 1, 2, 3, 1, 4},
  })
  dropGarbage(match, stack, 6, 1)
  stack.cur_row = 1
  stack.cur_col = 1
  local cpu = newCpu(stack)
  expect(cpu.brain.garbageRow, 2, "garbage row")

  assert(PplGarbage.clearGarbage(cpu.board, cpu.brain), "a 3 of 1s fits in the row under the garbage")
  expectList(queuedCommands(cpu.board, cpu.brain), {1, 1, 0, 3, 4, 2}, "go to the row, slide the third 1 next to the pair")

  cpu.brain:clearQueues()
  local frames = drive(match, stack, cpu, 300, function()
    return anyGarbageMatched(stack)
  end)
  assert(frames, "the CPU matched the 1s under the garbage")
end

clearGarbageMakesARowUnderTheGarbage()

local function clearGarbageBuildsAColumnUnderTheGarbage()
  local match, stack = createMatch()
  setBoard(stack, {
    {3, 4, 5, 6, 2, 1},
    {2, 3, 4, 1, 5, 6},
    {1, 2, 3, 4, 5, 6},
  })
  dropGarbage(match, stack, 6, 1)
  stack.cur_row = 1
  stack.cur_col = 3
  local cpu = newCpu(stack)
  local brain = cpu.brain
  expect(brain.garbageRow, 3, "garbage row")

  assert(PplGarbage.clearGarbage(cpu.board, brain), "no row 3, but three 1s that can slide under column 0")
  -- nearest row to the cursor first; the 1 in row 2 is in column 0 already
  expectList(queuedCommands(cpu.board, brain), {1, 0, 0, 4, 5, 0, 1, 1, 0, 4, 3, 0}, "two slides into column 0")
  expect(brain.totCheck[0], 3, "three 1s listed")

  brain:clearQueues()
  local frames = drive(match, stack, cpu, 600, function()
    return anyGarbageMatched(stack)
  end)
  assert(frames, "the CPU built the column of 1s under the garbage")
  for row = 1, 3 do
    expect(stack.panels[row][1].color, 1, "the 1s matched in column 1, PA row " .. row)
  end

  -- something already matching under the garbage: leave it
  local _, stackFlashing = createMatch()
  setBoard(stackFlashing, {
    {3, 4, 5, 6, 2, 1},
    {2, 3, 4, 1, 5, 6},
    {1, 2, 3, 4, 5, 6},
  })
  local flashing = stackFlashing.panels[3][4]
  flashing.state = "matched"
  flashing.timer = stackFlashing.levelData.frameConstants.FACE + 10
  local cpuFlashing = newCpu(stackFlashing)
  cpuFlashing.brain.garbageRow = 3
  assert(not PplGarbage.clearGarbage(cpuFlashing.board, cpuFlashing.brain), "a flash in the row under the garbage")
end

clearGarbageBuildsAColumnUnderTheGarbage()

local function clearGarbageOnTheTower()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  local curCol = 7
  stack.cur_col = curCol
  stack.cur_row = 1
  local colors = {1, 1, 2, 3, 1, 4}
  local row = {}
  for viewColumn = 0, 5 do
    row[boardColumnOfView(curCol, viewColumn)] = colors[viewColumn + 1]
  end
  CylinderTestUtils.setColors(stack, 1, row)
  dropGarbage(match, stack, 6, boardColumnOfView(curCol, 0))
  local cpu = newCpu(stack)
  expect(cpu.brain.garbageRow, 1, "garbage row in view columns 2 and 3")

  assert(PplGarbage.clearGarbage(cpu.board, cpu.brain), "a 3 of 1s under the garbage on the tower")
  expectList(queuedCommands(cpu.board, cpu.brain), {1, 0, 0, 3, 4, 2}, "the same plan in view columns")
  expect(cpu.brain.commandFirst[2], boardColumnOfView(curCol, 4) - 1, "the slide is stored as a board column")

  cpu.brain:clearQueues()
  local frames = drive(match, stack, cpu, 300, function()
    return anyGarbageMatched(stack)
  end)
  assert(frames, "the CPU matched the 1s under the garbage on the tower")
end

clearGarbageOnTheTower()

---------------------------------------------------------------------------------------------------------------------
-- AIChainGarbage1 / AIChainGarbage2 (§2.3)

-- Board for the garbage chains (PPL rows): rows 0-2 hold the stack, a 6 wide block rests on them in row 3, and a
-- 3 of 6s under its left half turns it into panels. The revealed colours are set by hand: a 1 on the right
-- (it pops first), the rest colours that appear nowhere below.
local REVEALED = {5, 7, 5, 7, 5, 1}

---@param onTop integer? colour of a panel resting on the garbage over column 5
---@return Match
---@return Stack
local function convertingGarbageBoard(onTop)
  local match, stack = createMatch()
  setBoard(stack, {
    {2, 3, 4, 2, 3, 4},
    {3, 4, 1, 3, 4, 2},
    {4, 2, 6, 1, 2, 3},
  })
  dropGarbage(match, stack, 6, 1)
  if onTop then
    CylinderTestUtils.setColors(stack, 5, {[6] = onTop})
  end
  CylinderTestUtils.setColors(stack, 3, {[1] = 6, [2] = 6, [3] = 6})
  stack.cur_row = 2
  stack.cur_col = 3
  return match, stack
end

-- after the frame that matched the garbage: give its bottom row the test's colours
---@param stack Stack
local function setRevealedColors(stack)
  for column = 1, 6 do
    local panel = stack.panels[4][column]
    assert(panel.isGarbage and panel.state == "matched" and panel.y_offset == -1, "garbage converting at " .. column)
    panel.color = REVEALED[column]
  end
end

---@param match Match
---@param stack Stack
---@param cpu PplCpu
local function runUntilRevealed(match, stack, cpu)
  for _ = 1, 300 do
    idleFrames(match, stack, 1)
    cpu.board:refresh()
    if cpu.board:type(3, 5) == 1 then
      return
    end
  end
  error("the 1 on the right never showed")
end

local function chainGarbage1LinesUpAChain()
  local match, stack = convertingGarbageBoard()
  local cpu = newCpu(stack)
  expect(cpu.brain.garbageRow, 3, "garbage row before the match")
  idleFrames(match, stack, 1)
  setRevealedColors(stack)
  cpu.board:refresh()
  expect(cpu.board.cursorState, 2, "garbage turning into panels")
  expect(cpu.board:type(3, 5), PplBoard.GARBAGE, "nothing has popped yet")
  assert(not PplGarbage.chainGarbage1(cpu.board, cpu.brain), "no colour to chain onto yet")

  runUntilRevealed(match, stack, cpu)
  expect(cpu.board:state(3, 5), PplBoard.GARBAGE_TURNING, "the revealed panel is still turning")
  expect(cpu.board:type(3, 0), PplBoard.GARBAGE, "the left end pops last")
  local brain = cpu.brain
  brain:setCursor()
  brain:clearQueues()
  assert(PplGarbage.chainGarbage1(cpu.board, brain), "two 1s can slide under the revealed 1")
  -- nearest row first: the 1 in PPL row 1, then the one in row 2
  expectList(queuedCommands(cpu.board, brain), {1, 1, 0, 4, 2, 5, 1, 2, 0, 4, 3, 5}, "two slides into column 5")
  expect(brain.totCheck[5], -1, "column 5 is locked now")
  expect(brain.totCheck[4], 0, "column 4 has not popped yet")

  -- the CPU does it in time: the revealed 1 lands on the two 1s as a chain link
  local playMatch, playStack = convertingGarbageBoard()
  local playCpu = newCpu(playStack)
  local chained = false
  local plannedGarbageChain = false
  local first = true
  local frames = drive(playMatch, playStack, playCpu, 600, function()
    return chained
  end, function()
    if first then
      setRevealedColors(playStack)
      first = false
    end
    if playCpu.brain.lastPlan == 0x1E then
      plannedGarbageChain = true
    end
    if playStack.chain_counter >= 2 then
      chained = true
    end
  end)
  assert(plannedGarbageChain, "the CPU planned with AIChainGarbage1")
  assert(frames, "the revealed 1 made a chain")
  for row = 2, 4 do
    expect(playStack.panels[row][6].color, 1, "the chain is the column of 1s, PA row " .. row)
  end
end

chainGarbage1LinesUpAChain()

local function chainGarbage2AddsOneUnderAPair()
  -- a 1 resting on the garbage over the revealed 1: one more 1 under them is enough
  local match, stack = convertingGarbageBoard(1)
  local cpu = newCpu(stack)
  idleFrames(match, stack, 1)
  setRevealedColors(stack)
  runUntilRevealed(match, stack, cpu)
  local brain = cpu.brain
  brain:setCursor()
  brain:clearQueues()
  assert(PplGarbage.chainGarbage1(cpu.board, brain), "AIChainGarbage2 plans for the first 1 found")
  expectList(queuedCommands(cpu.board, brain), {1, 2, 0, 4, 3, 5}, "one slide into column 5, from row 2")
  expect(brain.totCheck[5], -1, "column 5 is locked now")

  brain:clearQueues()
  assert(not PplGarbage.chainGarbage2(cpu.board, brain, 2, 5), "the colour above has to be the revealed one")
end

chainGarbage2AddsOneUnderAPair()

local function chainGarbageRespectsTheChainLimit()
  local match, stack = convertingGarbageBoard()
  local cpu = newCpu(stack)
  idleFrames(match, stack, 1)
  setRevealedColors(stack)
  runUntilRevealed(match, stack, cpu)
  local brain = cpu.brain
  brain:setCursor()
  brain.chainLimit = -1
  cpu.board.oldChain = -1
  assert(not PplGarbage.chainGarbage1(cpu.board, brain), "a x2 limit builds nothing during a x2")
  brain.chainLimit = 0
  cpu.board.oldChain = -4
  assert(not PplGarbage.chainGarbage1(cpu.board, brain), "a combo character stops at x5")
  brain.garbageRow = 1
  cpu.board.oldChain = 0
  assert(not PplGarbage.chainGarbage1(cpu.board, brain), "garbage below row 2")
end

chainGarbageRespectsTheChainLimit()

---------------------------------------------------------------------------------------------------------------------
-- AIChainPack (§2.3)

local function chainPackLowersPanels()
  local _, stack = createMatch()
  setBoard(stack, {
    {1, 2, 3, 4, 5, 6},
    {2, 3, 4, 5, 6, 0},
    {0, 0, 0, 0, 1, 0},
  })
  local cpu = newCpu(stack)
  local brain = cpu.brain
  brain.garbageRow = 3
  brain:clearScratch()
  assert(PplGarbage.chainPack(cpu.board, brain), "the 1 in row 2 is not right above the 1 in row 0")
  expectList(queuedCommands(cpu.board, brain), {1, 1, 0, 3, 4, 5}, "slide it into the hole beside it, one row down")

  -- the hole is in a locked column: only the locked columns' holes are filled, and nothing else drops into them
  brain:clearQueues()
  brain.totCheck[5] = -1
  assert(not PplGarbage.chainPack(cpu.board, brain), "the only hole is in a locked column")

  -- two of a colour in one row, nothing else to do
  setBoard(stack, {
    {1, 2, 3, 4, 5, 0},
    {0, 0, 2, 6, 2, 0},
  })
  cpu.board:refresh()
  brain:clearQueues()
  brain:clearScratch()
  brain.garbageRow = 3
  assert(PplGarbage.chainPack(cpu.board, brain), "a pair of 2s in row 1")
  expectList(queuedCommands(cpu.board, brain), {1, 1, 0, 3, 2, 5}, "lower the left 2: along row 1 to the hole in column 5")
end

chainPackLowersPanels()

---------------------------------------------------------------------------------------------------------------------
-- AIVolumeCheck (§2.5)

local function volumeCheckRaisesALowStack()
  local match, stack = createMatch({allowManualRaise = true})
  setBoard(stack, {
    {1, 2, 3, 4, 5, 6},
    {2, 3, 4, 5, 6, 1},
  })
  local cpu = newCpu(stack)
  local brain = cpu.brain
  assert(brain:hasCharacter(0x02), "level 10 raises")
  assert(PplGarbage.volumeCheck(cpu.board, brain, true), "12 panels, 2 high: raise")
  local commands = queuedCommands(cpu.board, brain)
  expect(#commands, 15, "three raises, a row, re-centre")
  expectList({commands[1], commands[4], commands[7], commands[10], commands[13]}, {12, 12, 12, 1, 10}, "command codes")
  assert(commands[11] >= 2 and commands[11] <= 6, "a random row 2..5 after raising, got " .. commands[11])

  brain:clearQueues()
  brain.character = 0
  assert(not PplGarbage.volumeCheck(cpu.board, brain, true), "without bit 0x02 and with skipFlatten: nothing")
  expect(brain.totalCommand, 0, "nothing queued")

  -- driven: the CPU raises the stack through PA's manual raise (without passive rise PA leaves the last step of the
  -- row to it, so the displacement shows the raise)
  local playCpu = newCpu(stack)
  local displacement = stack.displacement
  local pressedRaise = false
  local frames = drive(match, stack, playCpu, 600, function()
    return pressedRaise and stack.displacement < displacement
  end, function()
    pressedRaise = pressedRaise or playCpu.brain.lastInput == KeyDataEncoding.raise
  end)
  assert(frames, "the CPU raised its stack")
end

volumeCheckRaisesALowStack()

local function volumeCheckRaisesUnderLowGarbage()
  local match, stack = createMatch()
  setBoard(stack, {
    {1, 2, 3, 4, 5, 6},
    {2, 3, 4, 5, 6, 1},
  })
  dropGarbage(match, stack, 6, 1)
  stack.cur_row = 3
  local cpu = newCpu(stack)
  expect(cpu.brain.garbageRow, 2, "garbage row")
  assert(PplGarbage.volumeCheck(cpu.board, cpu.brain, true), "low garbage: raise")
  expectList(queuedCommands(cpu.board, cpu.brain), {12, 0, 0, 1, 1, 0, 10, 0, 0}, "raise, a row down, re-centre")
end

volumeCheckRaisesUnderLowGarbage()

local function volumeCheckFlattensTheTallestColumn()
  local _, stack = createMatch()
  setBoard(stack, {
    {1, 2, 3, 4, 5, 6},
    {0, 0, 4, 0, 0, 0},
    {0, 0, 5, 0, 0, 0},
    {0, 0, 4, 0, 0, 0},
    {0, 0, 5, 0, 0, 0},
  })
  stack.cur_row = 1
  stack.cur_col = 1
  local cpu = newCpu(stack)
  local brain = cpu.brain
  brain.character = 0
  assert(PplGarbage.volumeCheck(cpu.board, brain, false), "a tower in column 2")
  expectList(queuedCommands(cpu.board, brain), {1, 3, 0, 3, 2, 1}, "push the panel under the top one into the hole")

  -- no holes beside it: drop the top panel a row on the far side instead (AILowerRow)
  local rows = {}
  for row = 1, 4 do
    rows[row] = {}
    for column = 1, 5 do
      rows[row][column] = (2 * (row - 1) + column - 1) % 6 + 1
    end
    rows[row][6] = 0
  end
  rows[5] = {0, 0, 5, 0, 0, 0}
  setBoard(stack, rows)
  cpu.board:refresh()
  brain:clearQueues()
  brain:clearScratch()
  assert(PplGarbage.volumeCheck(cpu.board, brain, false), "the top panel can drop into column 5")
  expectList(queuedCommands(cpu.board, brain), {1, 4, 0, 3, 2, 5}, "slide it to column 5 on its own row")
end

volumeCheckFlattensTheTallestColumn()

---------------------------------------------------------------------------------------------------------------------
-- a whole game against an attack engine: Hard stage 8 (AI-SPEC §3.4) under a 3 and a 4 wide combo every 11 seconds or
-- so, two minutes. The chain and combo planners are filled in elsewhere; without them the CPU keeps PPL's stack of
-- about 42 panels and clears little on its own, so the garbage planners are what keeps it alive here.

local GAME_FRAMES = 2 * 60 * 60
-- allocation is measured with the JIT off and flushed (compiling and leaving traces allocate too) and the collector
-- stopped, for 30 seconds
-- after a 30 second warm-up; the rollback copies of the mutation check stay out of that window
local MEASURE_FROM = 1800
local MEASURE_TO = 3600

---@class GarbageGameResult
---@field frames integer frames the CPU's stack survived (capped at two minutes)
---@field garbageMatches integer times the CPU's matches hit garbage
---@field allocated number KB allocated by getInput between MEASURE_FROM and MEASURE_TO

---@param measure boolean check that getInput leaves the stack alone and allocates nothing after warm-up
---@return GarbageGameResult
local function playUnderGarbage(measure)
  local rules = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_TRAINING).matchRules
  local match = Match(GeneratorSource(13, false), rules)
  local stack = match:createStackWithSettings(LevelPresets.getModern(4), false, "controller")
  ---@cast stack Stack
  local attacker = match:createSimulatedStackWithSettings({
    delayBeforeStart = 0,
    delayBeforeRepeat = 400,
    countdownAdjusted = true,
    attackPatterns = {
      {width = 3, height = 1, startTime = 300},
      {width = 4, height = 1, startTime = 700},
    }
  })
  match:addTarget(attacker, stack)
  match:start()
  stack:setMaxRunsPerFrame(1)
  attacker:setMaxRunsPerFrame(1)

  local result = {frames = 0, garbageMatches = 0, allocated = 0}
  stack:connectSignal("garbageMatched", result, function(self)
    self.garbageMatches = self.garbageMatches + 1
  end)

  local cpu = PplCpu(stack, {seed = 1, difficulty = 3, stage = 8})
  local measuring = false
  local frame = 0
  while frame < GAME_FRAMES and not stack:game_ended() do
    frame = frame + 1
    if measure and frame == MEASURE_FROM then
      jit.off()
      jit.flush()
      collectgarbage("collect")
      collectgarbage("stop")
      measuring = true
    elseif measuring and frame == MEASURE_TO then
      collectgarbage("restart")
      jit.on()
      measuring = false
    end
    local check = measure and not measuring and frame % 7 == 0
    local before
    if check then
      before = {}
      stack:saveIntoRollbackCopy(before)
    end
    local memory = measuring and collectgarbage("count")
    local input = cpu:getInput()
    if measuring then
      result.allocated = result.allocated + collectgarbage("count") - memory
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
  result.frames = frame
  return result
end

local function cpuClearsGarbageInAGame()
  local withPlanners = playUnderGarbage(true)

  -- the same CPU with the garbage planners switched off (volume and the fallbacks stay)
  local clearGarbage = PplGarbage.clearGarbage
  local chainGarbage1 = PplGarbage.chainGarbage1
  local chainPack = PplGarbage.chainPack
  local function never()
    return false
  end
  PplGarbage.clearGarbage = never
  PplGarbage.chainGarbage1 = never
  PplGarbage.chainPack = never
  local ok, without = pcall(playUnderGarbage, false)
  PplGarbage.clearGarbage = clearGarbage
  PplGarbage.chainGarbage1 = chainGarbage1
  PplGarbage.chainPack = chainPack
  assert(ok, without)

  print(string.format("PPL CPU under garbage: %d frames, %d garbage matches, %.2f KB allocated by getInput; "
                      .. "without garbage planners: %d frames, %d garbage matches",
                      withPlanners.frames, withPlanners.garbageMatches, withPlanners.allocated, without.frames,
                      without.garbageMatches))
  assert(withPlanners.garbageMatches >= 3, "the CPU should clear garbage, cleared " .. withPlanners.garbageMatches)
  assert(withPlanners.garbageMatches > without.garbageMatches, "the garbage planners should clear more garbage")
  -- the other planners keep a CPU alive for a while too, so only ask for the whole game and more than without
  assert(withPlanners.frames == GAME_FRAMES, "the CPU should survive the whole game, topped out at " .. withPlanners.frames)
  assert(withPlanners.frames > without.frames, "the garbage planners should keep the CPU alive longer")
  assert(withPlanners.frames > MEASURE_TO, "the allocation check needs the game to last past its window")
  assert(withPlanners.allocated == 0, string.format("getInput allocated %.2f KB", withPlanners.allocated))
end

cpuClearsGarbageInAGame()

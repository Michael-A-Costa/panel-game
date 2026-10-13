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
local PplHelpers = require("common.engine.computerPlayers.PplCpu.PplHelpers")
local PplChains = require("common.engine.computerPlayers.PplCpu.PplChains")

-- Tests for the chain extension planners of the PPL CPU (AI-SPEC §2.1, §2.2; phase 2b of docs/cpu-ai/PLAN.md).
-- Boards are written bottom up as PA rows; comments and expected commands use PPL's 0-based rows and columns
-- (PPL row r is PA row r + 1, column c is PA column c + 1). Expected commands are flat: code, first, second, ...

local IDLE = KeyDataEncoding.idle

-- the chain extension character bits (AI-SPEC §3.2)
local SLIDE_IN = 0x04
local ADVANCED_SETUPS = 0x08

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

-- makes the PA cells {row, column, row, column, ...} a match that is still flashing, without running a frame
---@param stack Stack
---@param cells integer[]
local function flash(stack, cells)
  local frames = stack.levelData.frameConstants
  for i = 1, #cells, 2 do
    local panel = stack.panels[cells[i]][cells[i + 1]]
    panel.state = "matched"
    panel.timer = frames.FACE + 10
  end
end

-- A CPU looking at the flash on its stack, as UpdateAI does before the chain planners run: cursor at PA (row,
-- column), vision around it, empty queues, AIFlashCheck done.
---@param stack Stack
---@param cursorRow integer PA row
---@param cursorColumn integer PA column
---@param character integer technique bits
---@return PplCpu
local function lookAtFlash(stack, cursorRow, cursorColumn, character)
  stack.cur_row = cursorRow
  stack.cur_col = cursorColumn
  local cpu = PplCpu(stack, {seed = 1, level = 10})
  local brain = cpu.brain
  brain.character = character
  cpu.board:refresh()
  brain:setCursor()
  brain:changeVision()
  brain:clearQueues()
  brain.step = 0
  assert(PplHelpers.flashCheck(cpu.board, brain), "the test board has a flash")
  return cpu
end

---@param cpu PplCpu
---@param planner fun(board: PplBoard, brain: PplBrain): boolean
---@param expected integer[] commands, empty if the planner must not plan
---@param what string
local function expectPlan(cpu, planner, expected, what)
  local planned = planner(cpu.board, cpu.brain)
  expect(planned, #expected > 0, what .. " plans")
  expectList(queuedCommands(cpu.brain), expected, what .. " commands")
  if planned then
    expect(cpu.brain.step, 1, what .. " starts a chain setup")
  end
end

-- PA cells that are matched right now, as {row, column, ...} bottom up, left to right
---@param stack Stack
---@return integer[]
local function matchedCells(stack)
  local cells = {}
  for row = 1, 12 do
    for column = 1, stack.width do
      if stack.panels[row][column].state == "matched" then
        cells[#cells + 1] = row
        cells[#cells + 1] = column
      end
    end
  end
  return cells
end

-- Lays out a board whose first frame makes the match in matchCells, checks that nothing else matched, then lets a
-- CPU play until the stack's chain counter reaches 2 (a x2 chain). Returns the frames it took.
---@param match Match
---@param stack Stack
---@param rows integer[][]
---@param matchCells integer[] PA cells
---@param cursorRow integer PA row
---@param cursorColumn integer PA column
---@param firstColumn integer?
---@param options PplCpuOptions? the CPU, level 10 by default
---@return integer? frames nil when no chain happened
local function playForChain(match, stack, rows, matchCells, cursorRow, cursorColumn, firstColumn, options)
  setBoard(stack, rows, firstColumn)
  stack.cur_row = cursorRow
  stack.cur_col = cursorColumn
  stack:receiveConfirmedInput(IDLE)
  match:run()
  expectList(matchedCells(stack), matchCells, "the board's first match")

  local cpu = PplCpu(stack, options or {seed = 1, level = 10})
  for frame = 1, 600 do
    stack:receiveConfirmedInput(cpu:getInput())
    match:run()
    if stack.chain_counter >= 2 then
      return frame
    end
  end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- vertical flash (AI-SPEC §2.1)

-- column 2, rows 1..3 flash (colour 1). Colour 2 sits under the flash at (0, 2), above it at (4, 1) and two above
-- at (5, 3): three panels to stack in column 2.
local VERT1_BOARD = {
  {3, 4, 2, 5, 6, 3},
  {4, 5, 1, 6, 3, 4},
  {5, 6, 1, 3, 4, 5},
  {6, 3, 1, 4, 5, 6},
  {0, 2, 6, 5, 0, 0},
  {0, 0, 3, 2, 0, 0},
}
local VERT1_FLASH = {2, 3, 3, 3, 4, 3}

-- the same, but only a pair (under and above) and a colour 2 beside the flash at (2, 4) to slide in
local VERT1_SLIDE_BOARD = {
  {3, 4, 2, 5, 6, 3},
  {4, 5, 1, 6, 3, 4},
  {5, 6, 1, 3, 2, 5},
  {6, 3, 1, 4, 5, 6},
  {0, 2, 6, 5, 0, 0},
  {0, 0, 3, 4, 0, 0},
}

local function chainVert1StacksTheColourUnderTheFlash()
  local _, stack = createMatch()
  setBoard(stack, VERT1_BOARD)
  flash(stack, VERT1_FLASH)
  -- cursor on row 5: the nearest candidate (5, 3) first, then (4, 1); (0, 2) is in the column already
  local cpu = lookAtFlash(stack, 6, 3, 0)
  local probe = PplRandom(0)
  probe.state = cpu.brain.rng.state
  expectPlan(cpu, PplChains.chainVert1, {1, 5, 0, 4, 3, 2, 1, 4, 0, 4, 1, 2, 11, 0, 0}, "AIChainVert1, three panels")
  -- one draw: trim to three (a no-op here); no slide-in draw without bit 4
  probe:next(516)
  expect(cpu.brain.rng.state, probe.state, "AIChainVert1 draws once without the slide-in")

  setBoard(stack, VERT1_SLIDE_BOARD)
  flash(stack, VERT1_FLASH)
  cpu = lookAtFlash(stack, 6, 3, 0)
  expectPlan(cpu, PplChains.chainVert1, {}, "AIChainVert1, a pair without bit 4")
  cpu = lookAtFlash(stack, 6, 3, SLIDE_IN)
  -- the pair, then AIChainVert3 slides (2, 4) into the column at row 2 when that cell pops (command 5)
  expectPlan(cpu, PplChains.chainVert1, {1, 4, 0, 4, 1, 2, 1, 2, 0, 5, 4, 2}, "AIChainVert1, a pair and a slide-in")
end

chainVert1StacksTheColourUnderTheFlash()

local function chainVert3PicksTheNearerSide()
  local _, stack = createMatch()
  -- column 2, rows 0..3 flash; colour 2 at (2, 0) and (2, 4) is equally far: the right one wins ties
  setBoard(stack, {
    {3, 4, 1, 6, 5, 3},
    {4, 5, 1, 3, 2, 4},
    {2, 3, 1, 5, 2, 4},
    {6, 3, 1, 4, 5, 6},
  })
  flash(stack, {1, 3, 2, 3, 3, 3, 4, 3})
  local cpu = lookAtFlash(stack, 6, 3, SLIDE_IN)
  -- the caller (AIChainVert1) marks the setup, not AIChainVert3
  expect(PplChains.chainVert3(cpu.board, cpu.brain, 2, 111), true, "AIChainVert3 plans")
  expectList(queuedCommands(cpu.brain), {1, 2, 0, 5, 4, 2}, "AIChainVert3 slides the right one on a tie")
  cpu.brain:clearQueues()
  expect(PplChains.chainVert3(cpu.board, cpu.brain, 3, 111), true, "colour 3 at (2, 1) is next to the column")
  expectList(queuedCommands(cpu.brain), {1, 2, 0, 5, 1, 2}, "AIChainVert3 with colour 3")
  -- 111 only tries rows from + 1 .. to - 1; 222 tries the flash's bottom row too, where colour 6 is
  cpu.brain:clearQueues()
  expect(PplChains.chainVert3(cpu.board, cpu.brain, 6, 111), false, "colour 6 is only on row 0")
  expect(PplChains.chainVert3(cpu.board, cpu.brain, 6, 222), true, "222 also tries the flash's bottom row")
  expectList(queuedCommands(cpu.brain), {1, 0, 0, 5, 3, 2}, "AIChainVert3 222 on row 0")
end

chainVert3PicksTheNearerSide()

-- column 2, rows 1..3 flash. Colour 2 on the flash's bottom row at (1, 0) and (1, 4), and one above at (4, 3):
-- park the two beside the column and drop the third between them.
local VERT2_BOARD = {
  {3, 4, 5, 6, 3, 4},
  {2, 6, 1, 3, 2, 5},
  {4, 3, 1, 5, 6, 3},
  {5, 4, 1, 6, 3, 4},
  {0, 3, 3, 2, 0, 0},
}

local function chainVert2BuildsARowUnderTheColumn()
  local _, stack = createMatch()
  setBoard(stack, VERT2_BOARD)
  flash(stack, VERT1_FLASH)
  local cpu = lookAtFlash(stack, 3, 3, 0xFF)
  expectPlan(cpu, PplChains.chainVert1, {}, "AIChainVert1 on the Vert2 board")
  -- cursor on row 2: (1, 0) and (1, 4) tie at distance 1, the lower slot first; then (4, 3)
  expectPlan(cpu, PplChains.chainVert2, {1, 1, 0, 3, 0, 1, 1, 1, 0, 3, 4, 3, 1, 4, 0, 4, 3, 2, 11, 0, 0},
             "AIChainVert2")

  -- PPL's distance typo: any top panel right of the column counts, while one 4 to the left does not. Column 4
  -- flashes; (4, 0) is skipped, (4, 5) is taken. The pair on row 1 is parked already.
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {6, 5, 2, 2, 1, 3},
    {4, 3, 5, 6, 1, 4},
    {5, 4, 6, 3, 1, 6},
    {2, 6, 4, 5, 3, 2},
  })
  flash(stack, {2, 5, 3, 5, 4, 5})
  cpu = lookAtFlash(stack, 3, 3, 0xFF)
  expectPlan(cpu, PplChains.chainVert2, {1, 4, 0, 4, 5, 4, 11, 0, 0}, "AIChainVert2 with the top panel right")
end

chainVert2BuildsARowUnderTheColumn()

-- column 3, rows 1..3 flash. Colour 2 above it at (4, 3), a pair at (2, 1), (2, 2) and a plug at (2, 4).
local VERT4_BOARD = {
  {3, 4, 5, 6, 3, 4},
  {5, 6, 3, 1, 4, 6},
  {3, 2, 2, 1, 5, 3},
  {4, 5, 4, 1, 6, 5},
  {0, 0, 4, 2, 0, 0},
}
local VERT4_FLASH = {2, 4, 3, 4, 4, 4}

local function chainVert4And5UseThePairBesideTheFlash()
  local _, stack = createMatch()
  setBoard(stack, VERT4_BOARD)
  flash(stack, VERT4_FLASH)
  local cpu = lookAtFlash(stack, 3, 3, 0xFF)
  expectPlan(cpu, PplChains.chainVert1, {}, "AIChainVert1 on the Vert4 board")
  expectPlan(cpu, PplChains.chainVert2, {}, "AIChainVert2 on the Vert4 board")
  -- PPL queues slides that go nowhere when panels are in place already
  expectPlan(cpu, PplChains.chainVert4, {1, 4, 0, 3, 3, 3, 1, 2, 0, 3, 2, 2, 1, 2, 0, 3, 1, 1, 1, 2, 0, 5, 4, 3},
             "AIChainVert4")

  cpu = lookAtFlash(stack, 3, 3, 0xFF)
  expectPlan(cpu, PplChains.chainVert5,
             {1, 4, 0, 3, 3, 3, 1, 2, 0, 3, 2, 2, 1, 2, 0, 3, 1, 1, 1, 1, 0, 2, 2, 0, 13, 3, 3, 9, 0, 0, 11, 0, 0},
             "AIChainVert5 with a pair on the left")

  -- one on each side and a colour 2 two above the flash: knock it aside, then two coin flips
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {5, 6, 3, 1, 4, 6},
    {3, 5, 2, 1, 2, 3},
    {4, 5, 4, 1, 6, 5},
    {0, 0, 4, 2, 0, 0},
    {0, 0, 0, 2, 0, 0},
  })
  flash(stack, VERT4_FLASH)
  cpu = lookAtFlash(stack, 3, 3, 0xFF)
  local probe = PplRandom(0)
  probe.state = cpu.brain.rng.state
  local aside = probe:next(100) % 2 == 0 and 2 or 4
  local park = probe:next(100) % 2 == 0 and 2 or 3
  expectPlan(cpu, PplChains.chainVert5,
             {1, 5, 0, 6, 3, aside, 1, 4, 0, 3, 3, 3, 1, 2, 0, 3, 2, 2, 1, 2, 0, 3, 4, 4, 1, 1, 0, 2, park, 0,
              13, 3, 3, 9, 0, 0, 11, 0, 0},
             "AIChainVert5 with one on each side")
  expect(cpu.brain.rng.state, probe.state, "AIChainVert5 draws twice")
  expectPlan(lookAtFlash(stack, 3, 3, 0xFF), PplChains.chainVert4, {}, "AIChainVert4 without a pair or a fetch")

  -- a flash on the window's edge column: AIChainVert4 never plans there
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {1, 6, 3, 5, 4, 6},
    {1, 2, 2, 5, 5, 3},
    {1, 5, 4, 6, 6, 5},
    {2, 0, 4, 2, 0, 0},
  })
  flash(stack, {2, 1, 3, 1, 4, 1})
  expectPlan(lookAtFlash(stack, 3, 3, 0xFF), PplChains.chainVert4, {}, "AIChainVert4 on column 0")
end

chainVert4And5UseThePairBesideTheFlash()

---------------------------------------------------------------------------------------------------------------------
-- horizontal flash (AI-SPEC §2.2)

-- row 2, columns 1..3 flash. Colour 2 under it at (1, 2), above it at (3, 1) and at (4, 3): stack them in column 2.
local HORI1_BOARD = {
  {3, 6, 5, 6, 3, 4},
  {4, 5, 2, 4, 5, 3},
  {5, 1, 1, 1, 4, 6},
  {6, 2, 3, 6, 3, 0},
  {0, 6, 3, 2, 0, 0},
}
local HORI1_FLASH = {3, 2, 3, 3, 3, 4}

local function chainHori1StacksAColumnThroughTheFlash()
  local _, stack = createMatch()
  setBoard(stack, HORI1_BOARD)
  flash(stack, HORI1_FLASH)
  -- cursor on row 3, column 2: (3, 1) first, (4, 3) next, (1, 2) last and in the target column already
  local cpu = lookAtFlash(stack, 4, 3, 0)
  expectPlan(cpu, PplChains.chainHori1, {1, 3, 0, 4, 1, 2, 1, 4, 0, 4, 3, 2, 11, 0, 0}, "AIChainHori1")

  -- PPL's guard tests the first flash column: a flash starting at column 0 never plans, whatever its row
  setBoard(stack, {
    {3, 6, 2, 6, 3, 4},
    {1, 1, 1, 4, 5, 3},
    {6, 2, 3, 6, 3, 0},
    {0, 6, 2, 5, 0, 0},
  })
  flash(stack, {2, 1, 2, 2, 2, 3})
  expectPlan(lookAtFlash(stack, 4, 3, 0), PplChains.chainHori1, {}, "AIChainHori1 with from == 0")
end

chainHori1StacksAColumnThroughTheFlash()

-- row 1, columns 2..4 flash. Colour 2 once above the flash row at (2, 3), twice on it at (1, 0), (1, 1).
local HORI2_BOARD = {
  {3, 4, 5, 6, 3, 4},
  {2, 2, 1, 1, 1, 5},
  {6, 3, 4, 2, 6, 3},
}
local HORI2_FLASH = {2, 3, 2, 4, 2, 5}

local function chainHori2DropsOntoAPair()
  local _, stack = createMatch()
  setBoard(stack, HORI2_BOARD)
  flash(stack, HORI2_FLASH)
  local cpu = lookAtFlash(stack, 3, 3, 0)
  expectPlan(cpu, PplChains.chainHori1, {}, "AIChainHori1 on the Hori2 board")
  -- the upper one goes onto the flash end next to the pair, which is parked already
  expectPlan(cpu, PplChains.chainHori2, {1, 2, 0, 4, 3, 2, 11, 0, 0}, "AIChainHori2, one above")

  -- two above (one over the flash), one beside on the right: both upper ones onto the right end
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {5, 1, 1, 1, 6, 2},
    {6, 2, 3, 2, 4, 3},
  })
  flash(stack, {2, 2, 2, 3, 2, 4})
  cpu = lookAtFlash(stack, 3, 3, 0)
  -- order from row 2: the upper ones (slots 0, 1) are planned together on the first, then (1, 5) to column 4
  expectPlan(cpu, PplChains.chainHori2, {1, 2, 0, 3, 3, 3, 1, 2, 0, 5, 1, 2, 1, 1, 0, 5, 5, 4, 11, 0, 0},
             "AIChainHori2, two above")
end

chainHori2DropsOntoAPair()

local function chainHori3SlidesIntoTheOpeningFlash()
  local _, stack = createMatch()
  -- row 1, columns 1..3 flash; colour 2 on both sides at (1, 0), (1, 5) and a third at (2, 0)
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {2, 1, 1, 1, 6, 2},
    {2, 0, 0, 0, 0, 0},
  })
  flash(stack, {2, 2, 2, 3, 2, 4})
  local cpu = lookAtFlash(stack, 3, 3, SLIDE_IN)
  expectPlan(cpu, PplChains.chainHori3,
             {1, 1, 0, 3, 0, 0, 1, 2, 0, 3, 0, 1, 1, 1, 0, 7, 5, 4, 5, 4, 3, 6, 3, 2, 11, 0, 0}, "AIChainHori3")

  -- PPL's unreset row: colour 2 has both side panels but two panels on the flash, and moves the search up a row.
  -- Colour 3 is then found beside the flash on row 2 with a third on row 3, and planned a row too high.
  setBoard(stack, {
    {4, 4, 5, 6, 5, 4},
    {2, 1, 1, 1, 6, 2},
    {3, 5, 6, 0, 3, 0},
    {3, 0, 0, 0, 0, 0},
  })
  flash(stack, {2, 2, 2, 3, 2, 4})
  expectPlan(lookAtFlash(stack, 3, 3, SLIDE_IN), PplChains.chainHori3,
             {1, 2, 0, 3, 0, 0, 1, 3, 0, 3, 0, 1, 1, 2, 0, 7, 4, 4, 5, 4, 3, 6, 3, 2, 11, 0, 0},
             "AIChainHori3 after a colour moved the row")
end

chainHori3SlidesIntoTheOpeningFlash()

local function chainHori4And5DropAPanelIntoAGap()
  local _, stack = createMatch()
  -- row 1, columns 2..4 flash; colour 2 at (1, 0), one on the row above at (2, 1) and one to drop in at (3, 1)
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {2, 3, 1, 1, 1, 4},
    {5, 2, 0, 0, 0, 6},
    {0, 2, 0, 0, 0, 0},
  })
  local hori45Flash = {2, 3, 2, 4, 2, 5}
  flash(stack, hori45Flash)
  local cpu = lookAtFlash(stack, 3, 3, ADVANCED_SETUPS)
  expectPlan(cpu, PplChains.chainHori4,
             {1, 1, 0, 3, 0, 1, 1, 3, 0, 3, 1, 2, 1, 2, 0, 20, 2, 2, 6, 2, 3, 6, 1, 2, 11, 0, 0}, "AIChainHori4")

  -- two of colour 2 left of the flash and one to drop in
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {2, 2, 1, 1, 1, 4},
    {5, 6, 0, 0, 0, 3},
    {6, 2, 0, 0, 0, 0},
  })
  flash(stack, hori45Flash)
  cpu = lookAtFlash(stack, 3, 3, ADVANCED_SETUPS)
  expectPlan(cpu, PplChains.chainHori5, {1, 1, 0, 3, 1, 1, 1, 1, 0, 3, 0, 0, 1, 3, 0, 3, 1, 2, 1, 2, 0, 20, 2, 2,
                                         6, 2, 2, 11, 0, 0}, "AIChainHori5")

  -- PPL tests "any on the left", so one on the left and two on the right park column 0 (a cleared slot) at -1
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {2, 1, 1, 1, 2, 2},
    {5, 0, 0, 0, 6, 3},
    {6, 0, 0, 0, 0, 0},
    {2, 0, 0, 0, 0, 0},
  })
  flash(stack, {2, 2, 2, 3, 2, 4})
  cpu = lookAtFlash(stack, 3, 3, ADVANCED_SETUPS)
  expectPlan(cpu, PplChains.chainHori5, {1, 1, 0, 3, 0, 0, 1, 1, 0, 3, 0, -1, 1, 4, 0, 3, 0, 1, 1, 2, 0, 20, 2, 1,
                                         6, 1, 1, 11, 0, 0}, "AIChainHori5 with one on the left")

  -- no gap over the flash: neither plans
  setBoard(stack, {
    {3, 4, 5, 6, 3, 4},
    {2, 2, 1, 1, 1, 4},
    {5, 6, 3, 4, 5, 3},
    {6, 2, 0, 0, 0, 0},
  })
  flash(stack, hori45Flash)
  cpu = lookAtFlash(stack, 3, 3, ADVANCED_SETUPS)
  expectPlan(cpu, PplChains.chainHori4, {}, "AIChainHori4 without a gap")
  expectPlan(cpu, PplChains.chainHori5, {}, "AIChainHori5 without a gap")
end

chainHori4And5DropAPanelIntoAGap()

---------------------------------------------------------------------------------------------------------------------
-- the CPU playing the setups out

local function cpuPlaysChainSetupsOut()
  -- the boards above with real matches: the first frame matches them, the CPU sees the flash and builds the link
  local match, stack = createMatch()
  local frames = playForChain(match, stack, VERT1_BOARD, VERT1_FLASH, 6, 3)
  assert(frames, "AIChainVert1's setup makes a x2 chain")

  match, stack = createMatch()
  frames = playForChain(match, stack, VERT1_SLIDE_BOARD, VERT1_FLASH, 6, 3)
  assert(frames, "AIChainVert1 with the slide-in makes a x2 chain")

  match, stack = createMatch()
  frames = playForChain(match, stack, VERT2_BOARD, VERT1_FLASH, 3, 3)
  assert(frames, "AIChainVert2's setup makes a x2 chain")

  match, stack = createMatch()
  frames = playForChain(match, stack, VERT4_BOARD, VERT4_FLASH, 3, 3)
  assert(frames, "AIChainVert4's setup makes a x2 chain")

  match, stack = createMatch()
  frames = playForChain(match, stack, HORI1_BOARD, HORI1_FLASH, 4, 3)
  assert(frames, "AIChainHori1's setup makes a x2 chain")

  match, stack = createMatch()
  frames = playForChain(match, stack, HORI2_BOARD, HORI2_FLASH, 3, 3)
  assert(frames, "AIChainHori2's setup makes a x2 chain")
end

cpuPlaysChainSetupsOut()

local function cpuBuildsAChainOnTheTower()
  -- AIShortestD (command 4) follows the planned panel when an earlier slide turned it out of the view window
  local _, tower = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(tower)
  tower.cur_row = 2
  tower.cur_col = 9
  -- view column 6 is board column 11
  CylinderTestUtils.setColors(tower, 2, {[10] = 3, [11] = 2})
  local cpu = PplCpu(tower, {seed = 1, level = 10})
  cpu.board:refresh()
  cpu.brain:setCursor()
  cpu.brain:changeVision()
  expect(PplHelpers.shortestDistance(cpu.board, cpu.brain, 6, 5), 6, "AIShortestD outside the window on the tower")

  -- the Hori1 board on board columns 8..13 with the cursor on column 12: the CPU sees it as view columns 0..5 and
  -- has to turn the tower to stack view column 2 (board column 10), and back for the second panel
  local match, stack = CylinderTestUtils.createMatch()
  local towerFlash = {}
  for i = 1, #HORI1_FLASH, 2 do
    towerFlash[i] = HORI1_FLASH[i]
    towerFlash[i + 1] = HORI1_FLASH[i + 1] + 7
  end
  local frames = playForChain(match, stack, HORI1_BOARD, towerFlash, 4, 12, 8)
  assert(frames, "AIChainHori1's setup makes a x2 chain on the tower")
end

cpuBuildsAChainOnTheTower()

---------------------------------------------------------------------------------------------------------------------
-- a whole game

local GAME_FRAMES = 3 * 60 * 60
local MEASURE_AFTER = 1800

-- A Hard stage 10 opponent (chainLimit -9, all chain techniques but the timed swap) plays three minutes of 2D
-- endless alone: it chains, never writes to its stack, and allocates nothing per frame once warmed up.
-- Allocation is measured with the JIT off and its traces flushed, as in PplCpuTests' play().
local function chainHeavyCpuPlaysAGame()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 1)
  local stack = match.stacks[1]
  ---@cast stack Stack
  local cpu = PplCpu(stack, {seed = 3, difficulty = 3, stage = 10})
  local longestChain = 0
  local chainPlans = 0
  local allocated = 0
  local measuring = false
  local frame = 0
  while frame < GAME_FRAMES and not stack:game_ended() do
    frame = frame + 1
    if frame == MEASURE_AFTER then
      jit.off()
      jit.flush()
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
    local lastPlan = cpu.brain.lastPlan

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
    if cpu.brain.lastPlan ~= lastPlan and cpu.brain.lastPlan >= 11 and cpu.brain.lastPlan <= 0x19 then
      chainPlans = chainPlans + 1
    end
    stack:receiveConfirmedInput(input)
    match:run()
    longestChain = math.max(longestChain, stack.chain_counter)
  end
  if measuring then
    collectgarbage("restart")
    jit.on()
  end

  print(string.format("PPL CPU chains: %d frames, %d panels cleared, %d chain plans, longest chain x%d, "
                      .. "%.2f KB allocated by getInput", frame, stack.panels_cleared, chainPlans, longestChain,
                      allocated))
  assert(chainPlans > 0, "the CPU should plan chain links")
  assert(longestChain >= 2, "the CPU should chain at least once")
  assert(allocated == 0, string.format("getInput allocated %.2f KB over %d frames", allocated, frame - MEASURE_AFTER))
end

chainHeavyCpuPlaysAGame()

local consts = require("common.engine.consts")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local TouchDataEncoding = require("common.data.TouchDataEncoding")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestingUtils = require("common.tests.engine.CylinderTestingUtils")

local idle = KeyDataEncoding.idle
local left = KeyDataEncoding.left
local right = KeyDataEncoding.right
local up = KeyDataEncoding.up
local swap = KeyDataEncoding.swap

local function cylinderStackRunsTest()
  local match, stack = CylinderTestingUtils.createMatch({doCountdown = true, passiveRaise = true})
  assertEqual(stack.width, consts.CYLINDER_WIDTH)
  stack:receiveConfirmedInput(string.rep(idle, 600))
  StackReplayTestingUtils:simulateMatchUntil(match, 600)
  StackReplayTestingUtils:cleanup(match)
end

cylinderStackRunsTest()

local function turnTakesFourFramesTest()
  local match, stack = CylinderTestingUtils.createMatch()
  stack.cur_col = 10
  stack:receiveConfirmedInput(idle .. idle .. idle .. left .. string.rep(idle, 10))

  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  assertEqual(stack.rotationTimer, 0, "before the press")
  for timer = 3, 1, -1 do
    StackReplayTestingUtils:simulateMatchUntil(match, 7 - timer)
    assertEqual(stack.rotationTimer, timer)
    assertEqual(stack.rotationDirection, -1)
    assertEqual(stack.cur_col, 10, "cur_col while turning")
  end
  StackReplayTestingUtils:simulateMatchUntil(match, 7)
  assertEqual(stack.rotationDirection, 0, "after the turn")
  assertEqual(stack.cur_col, 9, "after the turn")
  StackReplayTestingUtils:simulateMatchUntil(match, 12)
  assertEqual(stack.cur_col, 9, "one press turns one column")
  StackReplayTestingUtils:cleanup(match)
end

turnTakesFourFramesTest()

local function pressesDuringATurnAreDroppedTest()
  local match, stack = CylinderTestingUtils.createMatch()
  stack.cur_col = 10
  stack:receiveConfirmedInput(idle .. left .. right .. idle .. idle .. right .. string.rep(idle, 10))

  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  assertEqual(stack.cur_col, 9, "the first turn landed")
  assertEqual(stack.rotationTimer, 0, "Right during the turn was dropped")
  StackReplayTestingUtils:simulateMatchUntil(match, 9)
  assertEqual(stack.cur_col, 10, "Right after the turn turns back")
  StackReplayTestingUtils:cleanup(match)
end

pressesDuringATurnAreDroppedTest()

local function cursorWrapsAroundTheSeamTest()
  local match, stack = CylinderTestingUtils.createMatch()
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. right .. string.rep(idle, 5) .. left .. string.rep(idle, 5))

  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  assertEqual(stack.cur_col, 1, "Right from column 18")
  StackReplayTestingUtils:simulateMatchUntil(match, 11)
  assertEqual(stack.cur_col, 18, "Left from column 1")
  StackReplayTestingUtils:cleanup(match)
end

cursorWrapsAroundTheSeamTest()

-- Pokémon Puzzle League repeats a held direction after 10 frames and then every 3 frames (controller.c);
-- every other repeat of Left or Right comes during a turn and is dropped, so the tower turns a column every 6 frames
local function heldDirectionsRepeatEveryThreeFramesTest()
  ---@param input string
  ---@param frames integer
  ---@param property string
  ---@return integer[] clock times on which the property changed
  local function changesWhileHolding(input, frames, property)
    local match, stack = CylinderTestingUtils.createMatch()
    stack.cur_col = 10
    stack.cur_row = 1
    stack:receiveConfirmedInput(idle .. string.rep(input, frames) .. idle)
    local changes = {}
    local previous = stack[property]
    for clock = 1, frames + 1 do
      StackReplayTestingUtils:simulateMatchUntil(match, clock)
      if stack[property] ~= previous then
        changes[#changes + 1] = clock
        previous = stack[property]
      end
      if input == up then
        assertEqual(stack.rotationTimer, 0, "Up doesn't turn the tower")
      end
    end
    StackReplayTestingUtils:cleanup(match)
    return changes
  end

  assertEqual(table.concat(changesWhileHolding(left, 30, "cur_col"), ","), "5,15,21,27", "turns landing")
  assertEqual(table.concat(changesWhileHolding(up, 20, "cur_row"), ","), "2,12,15,18,21", "rows moved")
end

heldDirectionsRepeatEveryThreeFramesTest()

local function swapAcrossTheSeamTest()
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  CylinderTestingUtils.setColors(stack, 1, {[18] = 1, [1] = 2})
  stack.cur_row = 1
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. idle .. swap .. string.rep(idle, 8))

  StackReplayTestingUtils:simulateMatchUntil(match, 2)
  assert(stack:canSwap(stack.panels[1][18], stack.panels[1][1]), "columns 18 and 1 are neighbours")
  assert(not stack:canSwap(stack.panels[1][18], stack.panels[1][2]), "columns 18 and 2 are not")
  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  assertEqual(stack.queuedSwapColumn, 18, "the left panel of a swap across the seam")

  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  assertEqual(stack.panels[1][18].color, 2)
  assertEqual(stack.panels[1][1].color, 1)
  assert(stack.panels[1][1].isSwappingFromLeft, "the panel moving onto column 1 comes from the left")
  assert(not stack.panels[1][18].isSwappingFromLeft, "the panel moving onto column 18 comes from the right")
  StackReplayTestingUtils:simulateMatchUntil(match, 10)
  assertEqual(stack.panels[1][1].state, "normal", "after the swap")

  -- whichever panel is passed first
  stack.queuedSwapColumn = 0
  stack.queuedSwapRow = 0
  assert(stack:tryQueueSwap(stack.panels[1][1], stack.panels[1][18]))
  assertEqual(stack.queuedSwapColumn, 18, "the left panel of a swap across the seam")
  StackReplayTestingUtils:cleanup(match)
end

swapAcrossTheSeamTest()

-- as in Pokémon Puzzle League a swap during a turn finishes the turn and swaps the pair the tower turned to
local function swapDuringATurnTest()
  local match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  CylinderTestingUtils.setColors(stack, 1, {[17] = 3, [18] = 4, [1] = 1, [2] = 2})
  stack.cur_row = 1
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. idle .. right .. swap .. string.rep(idle, 8))

  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  assertEqual(stack.rotationTimer, 0, "the swap finished the turn")
  assertEqual(stack.cur_col, 1)
  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  assertEqual(stack.panels[1][1].color, 2, "the pair the tower turned to swapped")
  assertEqual(stack.panels[1][18].color, 4, "the pair it turned from didn't")
  StackReplayTestingUtils:cleanup(match)

  -- Left and swap on the same frame
  match, stack = CylinderTestingUtils.createMatch()
  CylinderTestingUtils.clearBoard(stack)
  CylinderTestingUtils.setColors(stack, 1, {[17] = 3, [18] = 4, [1] = 1})
  stack.cur_row = 1
  stack.cur_col = 18
  local swapAndLeft = KeyDataEncoding.base64encode[16 + 2 + 1]
  stack:receiveConfirmedInput(idle .. idle .. swapAndLeft .. string.rep(idle, 8))
  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  assertEqual(stack.cur_col, 17)
  assertEqual(stack.queuedSwapColumn, 17)
  StackReplayTestingUtils:cleanup(match)
end

swapDuringATurnTest()

local function rollbackDuringATurnTest()
  local match, stack = CylinderTestingUtils.createMatch()
  match:setAlwaysSaveRollbacks(true)
  stack.cur_col = 2
  -- the second Left comes right after the first turn lands
  stack:receiveConfirmedInput(string.rep(idle, 4) .. left .. idle .. idle .. idle .. left .. string.rep(idle, 30))

  -- Match errors if the state after the rollback diverges from the state before
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  match:debugRollbackAndCaptureState(3)
  assertEqual(stack.rotationTimer, 0, "rolled back to before the press")
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  assertEqual(stack.rotationTimer, 2, "mid turn after the rollback")

  StackReplayTestingUtils:simulateMatchUntil(match, 14)
  assertEqual(stack.cur_col, 18, "two turns left from column 2")
  match:debugRollbackAndCaptureState(9)
  assertEqual(stack.rotationTimer, 3, "rolled back into the second turn")
  assertEqual(stack.cur_col, 1, "rolled back into the second turn")
  StackReplayTestingUtils:simulateMatchUntil(match, 14)
  assertEqual(stack.cur_col, 18, "after the rollback")
  StackReplayTestingUtils:cleanup(match)
end

rollbackDuringATurnTest()

-- Pokémon Puzzle League turns the tower left a column at a time while it rises into place (DoCountDown.s)
local function countdownTurnsTheTowerTest()
  local match, stack = CylinderTestingUtils.createMatch({doCountdown = true})
  local startColumn = stack.cur_col
  local columnAfterIntro = stack:wrapColumn(startColumn - consts.CYLINDER_INTRO_FRAMES / consts.CYLINDER_ROTATION_FRAMES)
  stack:receiveConfirmedInput(string.rep(idle, 200))

  StackReplayTestingUtils:simulateMatchUntil(match, consts.COUNTDOWN_START + consts.CYLINDER_INTRO_FRAMES)
  assertEqual(stack.rotationTimer, 0, "after the intro")
  assertEqual(stack.cur_col, columnAfterIntro, "after the intro")
  StackReplayTestingUtils:simulateMatchUntil(match, consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH + 1)
  assertEqual(stack.cur_row, 7, "after the countdown")
  assertEqual(stack.cur_col, columnAfterIntro, "after the countdown")
  StackReplayTestingUtils:cleanup(match)
end

countdownTurnsTheTowerTest()

-- touch can't turn a cylinder, so it only raises
local function touchDoesNotMoveTheCursorTest()
  local match, stack = CylinderTestingUtils.createMatch({inputMethod = "touch"})
  stack.cur_row = 3
  stack.cur_col = 10
  local touchPanel = TouchDataEncoding.touchDataToLatinString(false, 5, 2, stack.width)
  local touchNeighbour = TouchDataEncoding.touchDataToLatinString(false, 5, 3, stack.width)
  stack:receiveConfirmedInput(stack:idleInput() .. touchPanel .. touchNeighbour .. stack:idleInput())
  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  assertEqual(stack.cur_row, 3)
  assertEqual(stack.cur_col, 10)
  assertEqual(stack.queuedSwapColumn, 0)
  StackReplayTestingUtils:cleanup(match)
end

touchDoesNotMoveTheCursorTest()

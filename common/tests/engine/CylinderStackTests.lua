local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local TouchDataEncoding = require("common.data.TouchDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")

local idle = KeyDataEncoding.idle
local left = KeyDataEncoding.left
local right = KeyDataEncoding.right
local swap = KeyDataEncoding.swap

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

---@return Match
local function createCylinderEndlessMatch()
  local gameMode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local match = Match(GeneratorSource(1, false), gameMode.matchRules)
  match:createStackWithSettings(LevelPresets.getModern(5), false, "controller")
  match:start()
  match.stacks[1]:setMaxRunsPerFrame(1)
  return match
end

local function cylinderStackIsEighteenWide()
  local match = createCylinderEndlessMatch()
  local stack = match.stacks[1]
  ---@cast stack Stack

  assert(stack.cylinder, "the 3D preset should build a cylinder stack")
  assert(stack.width == consts.CYLINDER_WIDTH, "expected width " .. consts.CYLINDER_WIDTH .. ", got " .. stack.width)
  for row = 0, stack.height do
    for column = 1, stack.width do
      assert(stack.panels[row][column], "missing panel at row " .. row .. " column " .. column)
    end
  end
  assert(stack.rotationTimer == 0 and stack.rotationDirection == 0, "a new tower should not be rotating")
  assert(stack:getCylinderViewCenter() == stack.cur_col, "a resting tower is centred on the cursor")

  stack:receiveConfirmedInput(string.rep("A", 600))
  StackReplayTestingUtils:simulateMatchUntil(match, 600)
  assert(stack.clock == 600, "the cylinder stack should run")
  StackReplayTestingUtils:cleanup(match)
end

cylinderStackIsEighteenWide()

local function twoDimensionalStackIsUnchanged()
  local match = StackReplayTestingUtils.createEndlessMatch(nil, nil, 5)
  local stack = match.stacks[1]
  ---@cast stack Stack

  assert(not stack.cylinder, "2D presets must not build a cylinder")
  assert(stack.width == 6, "2D stacks stay 6 wide")
  assert(match.engineVersion == consts.ENGINE_VERSION, "2D matches keep the regular engine version")
  StackReplayTestingUtils:cleanup(match)
end

twoDimensionalStackIsUnchanged()

-- SPEC §2: the press starts a 4 frame step that is drawn at 1/4, 2/4 and 3/4 of the turn, then lands on the new column
local function rotationStepTimingTest()
  local match, stack = CylinderTestUtils.createMatch()
  stack.cur_col = 10
  stack:receiveConfirmedInput(idle .. idle .. idle .. left .. string.rep(idle, 10))

  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  expect(stack.rotationTimer, 0, "timer before the press")

  local frames = {
    {timer = 3, direction = -1, column = 10, center = 9.75},
    {timer = 2, direction = -1, column = 10, center = 9.5},
    {timer = 1, direction = -1, column = 10, center = 9.25},
    {timer = 0, direction = 0, column = 9, center = 9},
  }
  for i, frame in ipairs(frames) do
    StackReplayTestingUtils:simulateMatchUntil(match, 3 + i)
    expect(stack.rotationTimer, frame.timer, "rotation timer on step frame " .. i)
    expect(stack.rotationDirection, frame.direction, "rotation direction on step frame " .. i)
    expect(stack.cur_col, frame.column, "cur_col on step frame " .. i)
    expect(stack:getCylinderViewCenter(), frame.center, "view centre on step frame " .. i)
  end

  StackReplayTestingUtils:simulateMatchUntil(match, 12)
  expect(stack.cur_col, 9, "one press turns the tower by exactly one column")
  StackReplayTestingUtils:cleanup(match)
end

rotationStepTimingTest()

local function pressesDuringAStepAreDroppedTest()
  local match, stack = CylinderTestUtils.createMatch()
  stack.cur_col = 10
  -- Right while the Left step runs is dropped, the Right after it lands starts a new step
  stack:receiveConfirmedInput(idle .. left .. right .. idle .. idle .. right .. string.rep(idle, 10))

  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  expect(stack.rotationDirection, -1, "the running step keeps its direction")
  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  expect(stack.cur_col, 9, "the first step landed")
  expect(stack.rotationTimer, 0, "the dropped press did not queue another step")
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  expect(stack.rotationDirection, 1, "a press after the step lands starts a new one")
  StackReplayTestingUtils:simulateMatchUntil(match, 9)
  expect(stack.cur_col, 10, "and turns back")
  StackReplayTestingUtils:cleanup(match)
end

pressesDuringAStepAreDroppedTest()

local function cursorWrapsAroundTheRingTest()
  local match, stack = CylinderTestUtils.createMatch()
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. right .. string.rep(idle, 5) .. left .. string.rep(idle, 5))

  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  expect(stack.cur_col, 1, "Right from column 18 wraps to column 1")
  expect(stack:getCylinderViewCenter(), 1, "and the view centre with it")
  StackReplayTestingUtils:simulateMatchUntil(match, 8)
  expect(stack.rotationDirection, -1, "Left starts a step back")
  expect(stack:getCylinderViewCenter(), 0.75, "the view centre runs below 1 while turning across the seam")
  StackReplayTestingUtils:simulateMatchUntil(match, 11)
  expect(stack.cur_col, 18, "Left from column 1 wraps to column 18")
  StackReplayTestingUtils:cleanup(match)
end

cursorWrapsAroundTheRingTest()

-- Panel Attack's own key repeat stays: one step on the press, the next once the repeat delay is over,
-- then one per step as repeats that land mid step are dropped
local function holdingADirectionKeepsTurningTest()
  local match, stack = CylinderTestUtils.createMatch()
  stack.cur_col = 10
  stack:receiveConfirmedInput(idle .. string.rep(left, 30) .. string.rep(idle, 10))

  local landings = {}
  local previousColumn = stack.cur_col
  for clock = 1, 31 do
    StackReplayTestingUtils:simulateMatchUntil(match, clock)
    if stack.cur_col ~= previousColumn then
      landings[#landings + 1] = clock
      previousColumn = stack.cur_col
    end
  end

  local expected = {5, 15, 19, 23, 27, 31}
  expect(#landings, #expected, "steps completed while holding Left for 30 frames")
  for i, clock in ipairs(expected) do
    expect(landings[i], clock, "landing of step " .. i)
  end
  expect(stack.cur_col, 4, "six columns turned")
  StackReplayTestingUtils:cleanup(match)
end

holdingADirectionKeepsTurningTest()

local function upAndDownAreUnchangedTest()
  local match, stack = CylinderTestUtils.createMatch()
  stack.cur_row = 5
  local down = KeyDataEncoding.down
  stack:receiveConfirmedInput(idle .. KeyDataEncoding.up .. idle .. down .. idle .. down .. idle)
  StackReplayTestingUtils:simulateMatchUntil(match, 2)
  expect(stack.cur_row, 6, "Up moves the cursor a row up")
  expect(stack.rotationTimer, 0, "Up doesn't turn the tower")
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  expect(stack.cur_row, 4, "Down moves it down")
  StackReplayTestingUtils:cleanup(match)
end

upAndDownAreUnchangedTest()

local function swapAcrossTheSeamTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  CylinderTestUtils.setColors(stack, 1, {[18] = 1, [1] = 2})
  stack.cur_row = 1
  stack.cur_col = 18

  assert(stack:canSwap(stack.panels[1][18], stack.panels[1][1]) == false, "no swapping on the first frames")
  stack:receiveConfirmedInput(idle .. idle .. swap .. string.rep(idle, 8))
  StackReplayTestingUtils:simulateMatchUntil(match, 2)
  assert(stack:canSwap(stack.panels[1][18], stack.panels[1][1]), "columns 18 and 1 are neighbours")
  assert(not stack:canSwap(stack.panels[1][18], stack.panels[1][2]), "columns 18 and 2 are not")

  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  expect(stack.queuedSwapColumn, 18, "the queued swap's left panel is the one on column 18")
  expect(stack.queuedSwapRow, 1, "queued row")

  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  expect(stack.panels[1][18].color, 2, "the right panel moved onto column 18")
  expect(stack.panels[1][1].color, 1, "the left panel moved onto column 1")
  expect(stack.panels[1][1].state, "swapping", "state of the panel that crossed to the right")
  assert(stack.panels[1][1].isSwappingFromLeft, "the panel now on column 1 came from the left")
  assert(not stack.panels[1][18].isSwappingFromLeft, "the panel now on column 18 came from the right")

  StackReplayTestingUtils:simulateMatchUntil(match, 10)
  expect(stack.panels[1][1].state, "normal", "the swap finished")
  expect(stack.panels[1][18].column, 18, "panels know their new column")

  -- the convention holds whichever panel is passed first
  stack.queuedSwapColumn = 0
  stack.queuedSwapRow = 0
  assert(stack:tryQueueSwap(stack.panels[1][1], stack.panels[1][18]), "the swap back is possible")
  expect(stack.queuedSwapColumn, 18, "left panel of a seam swap passed right panel first")
  StackReplayTestingUtils:cleanup(match)
end

swapAcrossTheSeamTest()

-- SPEC §2: a swap during a rotation goes to the pair the tower turns to, so the turn finishes first
local function swapDuringARotationTest()
  local match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  CylinderTestUtils.setColors(stack, 1, {[17] = 3, [18] = 4, [1] = 1, [2] = 2})
  stack.cur_row = 1
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. idle .. right .. swap .. string.rep(idle, 8))

  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  expect(stack.rotationTimer, 3, "the turn to column 1 is running")
  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  expect(stack.rotationTimer, 0, "the swap finished the turn")
  expect(stack.cur_col, 1, "the cursor is on the pair it turned to")
  expect(stack.queuedSwapColumn, 1, "and the swap is queued there")
  StackReplayTestingUtils:simulateMatchUntil(match, 5)
  expect(stack.panels[1][1].color, 2, "columns 1 and 2 swapped")
  expect(stack.panels[1][2].color, 1, "columns 1 and 2 swapped")
  expect(stack.panels[1][18].color, 4, "the pair the turn started from is untouched")
  StackReplayTestingUtils:cleanup(match)

  -- a press and a swap on the same frame behave the same: turn, then swap at the new position
  match, stack = CylinderTestUtils.createMatch()
  CylinderTestUtils.clearBoard(stack)
  CylinderTestUtils.setColors(stack, 1, {[17] = 3, [18] = 4, [1] = 1})
  stack.cur_row = 1
  stack.cur_col = 18
  stack:receiveConfirmedInput(idle .. idle .. CylinderTestUtils.inputFor("swap", "left") .. string.rep(idle, 8))
  StackReplayTestingUtils:simulateMatchUntil(match, 3)
  expect(stack.cur_col, 17, "the turn finished on the swap frame")
  expect(stack.queuedSwapColumn, 17, "the swap went to columns 17 and 18")
  StackReplayTestingUtils:cleanup(match)
end

swapDuringARotationTest()

-- the tower's rotation is engine state and has to survive rollback mid step
local function rollbackAcrossARotationTest()
  local match, stack = CylinderTestUtils.createMatch()
  match:setAlwaysSaveRollbacks(true)
  stack.cur_col = 2
  -- the second press comes on the frame after the first step lands; one on its landing frame would be dropped
  stack:receiveConfirmedInput(string.rep(idle, 4) .. left .. idle .. idle .. idle .. left .. string.rep(idle, 30))

  -- mid step: roll back to before the press and run again; Match errors if the state diverges
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  expect(stack.rotationTimer, 2, "mid step before the rollback")
  match:debugRollbackAndCaptureState(3)
  expect(stack.rotationTimer, 0, "rolled back to before the press")
  expect(stack.cur_col, 2, "rolled back cur_col")
  StackReplayTestingUtils:simulateMatchUntil(match, 6)
  expect(stack.rotationTimer, 2, "mid step after the rollback")
  expect(stack.rotationDirection, -1, "direction after the rollback")

  -- from after the second step crossed the seam back into the middle of it
  StackReplayTestingUtils:simulateMatchUntil(match, 14)
  expect(stack.cur_col, 18, "two steps left from column 2 cross the seam")
  match:debugRollbackAndCaptureState(9)
  expect(stack.rotationTimer, 3, "rolled back into the second step")
  expect(stack.cur_col, 1, "before it crossed the seam")
  StackReplayTestingUtils:simulateMatchUntil(match, 14)
  expect(stack.cur_col, 18, "the step lands again")
  expect(stack.rotationTimer, 0, "and is done")
  StackReplayTestingUtils:cleanup(match)
end

rollbackAcrossARotationTest()

-- PPL's 3D countdown turns the tower left one column at a time while it rises (DoCountDown.s);
-- the cursor itself only slides down
local function countdownIntroTurnsTheTowerTest()
  local match, stack = CylinderTestUtils.createMatch({doCountdown = true})
  local startColumn = stack.cur_col
  stack:receiveConfirmedInput(string.rep(idle, 200))

  StackReplayTestingUtils:simulateMatchUntil(match, consts.COUNTDOWN_START + 1)
  expect(stack.rotationDirection, -1, "the intro turns left")
  StackReplayTestingUtils:simulateMatchUntil(match, consts.COUNTDOWN_START + consts.CYLINDER_INTRO_FRAMES)
  expect(stack.rotationTimer, 0, "the intro is over")
  local steps = consts.CYLINDER_INTRO_FRAMES / consts.CYLINDER_ROTATION_FRAMES
  expect(stack.cur_col, stack:wrapColumn(startColumn - steps), "one column per step for the whole intro")
  StackReplayTestingUtils:simulateMatchUntil(match, consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH + 1)
  expect(stack.cur_row, 7, "the cursor ends the countdown on the same row as in 2D")
  expect(stack.cur_col, stack:wrapColumn(startColumn - steps), "and keeps its column")
  StackReplayTestingUtils:cleanup(match)
end

countdownIntroTurnsTheTowerTest()

-- touching panels can't turn a tower, so touch input on a cylinder only raises
local function touchInputIsIgnoredTest()
  local match, stack = CylinderTestUtils.createMatch({inputMethod = "touch"})
  stack.cur_row = 3
  stack.cur_col = 10
  local touchPanel = TouchDataEncoding.touchDataToLatinString(false, 5, 2, stack.width)
  local touchOther = TouchDataEncoding.touchDataToLatinString(false, 5, 3, stack.width)
  stack:receiveConfirmedInput(stack:idleInput() .. touchPanel .. touchOther .. stack:idleInput())
  StackReplayTestingUtils:simulateMatchUntil(match, 4)
  expect(stack.cur_row, 3, "touch doesn't move the cursor row")
  expect(stack.cur_col, 10, "touch doesn't move the cursor column")
  expect(stack.queuedSwapColumn, 0, "touch doesn't queue swaps")
  StackReplayTestingUtils:cleanup(match)
end

touchInputIsIgnoredTest()

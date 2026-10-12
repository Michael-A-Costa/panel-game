local PanelGenerator = require("common.engine.PanelGenerator")
local GeneratorSource = require("common.engine.GeneratorSource")
local Stack = require("common.engine.Stack")
local LevelPresets = require("common.data.LevelPresets")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestUtils = require("common.tests.engine.CylinderTestUtils")

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

---@param row string
---@param column integer
---@return integer
local function colorAt(row, column)
  return PanelGenerator.PANEL_COLOR_TO_NUMBER[row:sub(column, column)]
end

-- runs rows through the generator; check is called with each row and the one generated before it
---@param adjacentDenialFrequency number
---@param isRing boolean
---@param check fun(row: string, previousRow: string)
local function generateRows(adjacentDenialFrequency, isRing, check)
  for seed = 1, 20 do
    local generator = PanelGenerator(seed * 31, adjacentDenialFrequency)
    local previousRow = ""
    for _ = 1, 50 do
      local row = generator:generatePanels(18, 5, previousRow, isRing)
      check(row, previousRow)
      previousRow = row
    end
  end
end

-- PPL init3d.c:89: the generator checks column 1 against column 18 like any other pair of neighbours
local function seamNeighboursFollowTheGeneratorRulesTest()
  -- levels that deny every repeated neighbour get none at the seam either
  generateRows(1, true, function(row)
    assert(colorAt(row, 18) ~= colorAt(row, 1), "same colour on both sides of the seam in " .. row)
  end)

  -- three in a row is never generated, around the seam neither, even where repeated neighbours are allowed
  local seamRepeats = 0
  generateRows(0, true, function(row, previousRow)
    local first, second, secondLast, last = colorAt(row, 1), colorAt(row, 2), colorAt(row, 17), colorAt(row, 18)
    assert(not (last == first and first == second), "three in a row over columns 18, 1, 2 in " .. row)
    assert(not (secondLast == last and last == first), "three in a row over columns 17, 18, 1 in " .. row)
    for column = 1, 18 do
      if previousRow ~= "" then
        assert(colorAt(row, column) ~= colorAt(previousRow, column), "same colour as above in " .. row)
      end
    end
    if last == first then
      seamRepeats = seamRepeats + 1
    end
  end)
  assert(seamRepeats > 0, "where the level allows repeated neighbours the seam may have them too")

  -- without the ring rule the seam isn't checked, which these rows would show
  local unchecked = 0
  generateRows(1, false, function(row)
    if colorAt(row, 18) == colorAt(row, 1) then
      unchecked = unchecked + 1
    end
  end)
  assert(unchecked > 0, "flat rows don't know about the seam")
end

seamNeighboursFollowTheGeneratorRulesTest()

-- the generator has to give 2D stacks the very same rows as before the cylinder existed, or every replay breaks;
-- the fingerprint was taken from the engine before the cylinder changes (commit 704f1ae4)
local function flatRowsAreUnchangedTest()
  local parts = {}
  for seed = 1, 12 do
    for _, level in ipairs({1, 3, 5, 8, 10}) do
      local source = GeneratorSource(seed * 7919, true)
      local stack = Stack({levelData = LevelPresets.getModern(level), stackSetupModifications = {}, panelSource = source,
                           inputMethod = "controller", is_local = false, stackOverConditions = {}, stackWinConditions = {}})
      local stackSource = stack.panelSource
      ---@cast stackSource GeneratorSource
      for _ = 1, 40 do
        stackSource:growPanelBuffer(stack)
      end
      parts[#parts + 1] = stackSource.panelBuffer
      for _ = 1, 40 do
        parts[#parts + 1] = stackSource:getGarbagePanelRowString(stack)
      end
    end
  end
  local all = table.concat(parts)
  expect(#all, 31320, "length of the 2D generator output")
  expect(love.data.encode("string", "hex", love.data.hash("string", "md5", all)), "5371c1f89721b45d51de92dd61b3effa",
         "fingerprint of the 2D generator output")
end

flatRowsAreUnchangedTest()

-- cylinder rows come out of the generator source closed around the seam, garbage rows included
local function cylinderSourceRowsCloseTheRingTest()
  local match, stack = CylinderTestUtils.createMatch({shockEnabled = true})
  local source = stack.panelSource
  ---@cast source GeneratorSource
  for _ = 1, 30 do
    source:growPanelBuffer(stack)
  end
  -- levels deny repeated neighbours at different rates, so only three in a row is ruled out for sure
  for start = 1, source.panelBuffer:len() - 17, 18 do
    local row = source.panelBuffer:sub(start, start + 17)
    local first, second, secondLast, last = colorAt(row, 1), colorAt(row, 2), colorAt(row, 17), colorAt(row, 18)
    if first ~= 0 then
      assert(not (last == first and first == second), "three in a row over the seam in buffered row " .. row)
      assert(not (secondLast == last and last == first), "three in a row over the seam in buffered row " .. row)
    end
  end
  for _ = 1, 30 do
    local row = source:getGarbagePanelRowString(stack)
    expect(row:len(), 18, "garbage rows are as wide as the tower")
    -- garbage rows deny every repeated neighbour
    assert(colorAt(row, 18) ~= colorAt(row, 1), "same colour across the seam in garbage row " .. row)
  end
  StackReplayTestingUtils:cleanup(match)
end

cylinderSourceRowsCloseTheRingTest()

-- PPL puts the shock panels of a new 3D row in view columns 1-5 (init3d.c:22), in front of the player
local function shockPanelsEnterInFrontTest()
  local match, stack = CylinderTestUtils.createMatch({shockEnabled = true})
  for i = 1, 40 do
    stack.cur_col = (i * 7) % 18 + 1
    stack.metalPanelsQueued = 4
    stack:new_row()
    local shockColumns = {}
    for column = 1, stack.width do
      if stack.panels[0][column].color == 8 then
        shockColumns[#shockColumns + 1] = column
      end
    end
    expect(#shockColumns, 2, "shock panels in incoming row " .. i)
    for _, column in ipairs(shockColumns) do
      local viewColumn = stack:boardToViewColumn(column)
      assert(viewColumn >= 1 and viewColumn <= 5, "shock panel on view column " .. viewColumn .. " in incoming row " .. i
             .. " with the cursor on column " .. stack.cur_col)
    end
  end
  StackReplayTestingUtils:cleanup(match)
end

shockPanelsEnterInFrontTest()

local PanelGenerator = require("common.engine.PanelGenerator")
local GeneratorSource = require("common.engine.GeneratorSource")
local Stack = require("common.engine.Stack")
require("common.engine.cylinder")
local LevelPresets = require("common.data.LevelPresets")
local StackReplayTestingUtils = require("common.tests.engine.StackReplayTestingUtils")
local CylinderTestingUtils = require("common.tests.engine.CylinderTestingUtils")

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

-- columns 1 and 18 are neighbours to the generator like any others (init3d.c)
local function seamNeighboursFollowTheGeneratorRulesTest()
  -- levels that deny every repeated neighbour
  generateRows(1, true, function(row)
    assert(colorAt(row, 18) ~= colorAt(row, 1), "same color on both sides of the seam in " .. row)
  end)

  -- levels that allow them still get no three in a row
  local seamRepeats = 0
  generateRows(0, true, function(row, previousRow)
    local first, second, secondLast, last = colorAt(row, 1), colorAt(row, 2), colorAt(row, 17), colorAt(row, 18)
    assert(not (last == first and first == second), "three in a row over columns 18, 1, 2 in " .. row)
    assert(not (secondLast == last and last == first), "three in a row over columns 17, 18, 1 in " .. row)
    for column = 1, 18 do
      if previousRow ~= "" then
        assert(colorAt(row, column) ~= colorAt(previousRow, column), "same color as above in " .. row)
      end
    end
    if last == first then
      seamRepeats = seamRepeats + 1
    end
  end)
  assert(seamRepeats > 0, "the seam may have repeated neighbours where the level allows them")

  -- flat rows don't check the seam
  local unchecked = 0
  generateRows(1, false, function(row)
    if colorAt(row, 18) == colorAt(row, 1) then
      unchecked = unchecked + 1
    end
  end)
  assert(unchecked > 0, "flat rows don't know about the seam")
end

seamNeighboursFollowTheGeneratorRulesTest()

-- flat stacks have to get the very same rows as before cylinders existed or replays break;
-- the fingerprint was taken before the generator learned about cylinders
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
  assertEqual(#all, 31320, "length of the 2D generator output")
  assertEqual(love.data.encode("string", "hex", love.data.hash("string", "md5", all)), "5371c1f89721b45d51de92dd61b3effa",
         "fingerprint of the 2D generator output")
end

flatRowsAreUnchangedTest()

local function cylinderSourceRowsCloseTheRingTest()
  local match, stack = CylinderTestingUtils.createMatch({shockEnabled = true})
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
    assertEqual(row:len(), 18, "garbage rows are as wide as the tower")
    -- garbage rows deny every repeated neighbour
    assert(colorAt(row, 18) ~= colorAt(row, 1), "same color across the seam in garbage row " .. row)
  end
  StackReplayTestingUtils:cleanup(match)
end

cylinderSourceRowsCloseTheRingTest()

-- shock panels enter in view columns 1-5, in front of the player (init3d.c)
local function shockPanelsEnterInFrontTest()
  local match, stack = CylinderTestingUtils.createMatch({shockEnabled = true})
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
    assertEqual(#shockColumns, 2, "shock panels in incoming row " .. i)
    for _, column in ipairs(shockColumns) do
      local viewColumn = stack:boardToViewColumn(column)
      assert(viewColumn >= 1 and viewColumn <= 5, "shock panel on view column " .. viewColumn .. " in incoming row " .. i
             .. " with the cursor on column " .. stack.cur_col)
    end
  end
  StackReplayTestingUtils:cleanup(match)
end

shockPanelsEnterInFrontTest()

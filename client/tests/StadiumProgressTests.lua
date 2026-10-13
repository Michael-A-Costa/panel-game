local json = require("common.lib.dkjson")
local StadiumLadder = require("common.data.StadiumLadder")
local StadiumProgress = require("client.src.StadiumProgress")

-- StadiumProgress whose saving is counted instead of writing stadium.json
---@return UnsavedStadiumProgress
local function createUnsavedProgress()
  ---@class UnsavedStadiumProgress : StadiumProgress
  ---@field saveCount integer
  local progress = StadiumProgress()
  progress.saveCount = 0
  progress.saveToFile = function(self)
    self.saveCount = self.saveCount + 1
  end
  return progress
end

-- what saveToFile writes, read back
---@param progress StadiumProgress
---@return table
local function roundTrip(progress)
  return json.decode(json.encode({version = progress.version, stadium = progress.stadium}))
end

-- no file or an unreadable one: fresh progress everywhere, nothing to rewrite
local function missingFileGivesFreshProgress()
  for _, data in ipairs({false, {}, {version = "1"}}) do
    local progress, upgraded = StadiumProgress.createFromData(data or nil)
    assert(not upgraded, "nothing to upgrade")
    assert(progress.version == StadiumProgress.CURRENT_VERSION)
    for _, dimension in ipairs({"2d", "3d"}) do
      for difficulty = 1, StadiumLadder.DIFFICULTY_COUNT do
        local difficultyProgress = progress:get(dimension, difficulty)
        assert(difficultyProgress.lastStageBeaten == 0 and difficultyProgress.continues == 0
               and difficultyProgress.clears == 0, "fresh progress for " .. dimension .. " difficulty " .. difficulty)
      end
    end
  end
end

-- runs, clears and their bests are kept per dimension and difficulty and survive the trip through the file
local function progressSurvivesSaving()
  local progress = createUnsavedProgress()
  progress:saveRun("2d", 2, 6, 3, 5000)
  progress:saveClear("3d", 4, 7, 90000)
  progress:saveClear("3d", 4, 2, 95000)
  progress:saveRun("3d", 4, 9, 1, 400)
  assert(progress.saveCount == 4, "every change is saved")

  local loaded, upgraded = StadiumProgress.createFromData(roundTrip(progress))

  assert(not upgraded, "a current file is not rewritten")
  local run = loaded:get("2d", 2)
  assert(run.lastStageBeaten == 6 and run.continues == 3 and run.time == 5000 and run.clears == 0)
  local cleared = loaded:get("3d", 4)
  assert(cleared.clears == 2, "both clears count")
  assert(cleared.bestContinues == 2 and cleared.bestTime == 90000, "the bests are kept apart")
  assert(cleared.lastStageBeaten == 9 and cleared.continues == 1, "with the run started after them")
  assert(loaded:get("2d", 4).clears == 0, "2D and 3D are separate")
end

-- a clear ends the run, so the next game of the difficulty starts at its first stage
local function clearResetsTheRun()
  local progress = createUnsavedProgress()
  progress:saveRun("2d", 1, 10, 4, 3000)
  progress:saveClear("2d", 1, 4, 3600)

  local difficultyProgress = progress:get("2d", 1)
  assert(difficultyProgress.lastStageBeaten == 0 and difficultyProgress.continues == 0 and difficultyProgress.time == 0)
  assert(difficultyProgress.clears == 1 and difficultyProgress.bestContinues == 4 and difficultyProgress.bestTime == 3600)
end

-- odd values in a hand edited file are skipped field by field instead of breaking the run
local function malformedDataIsIgnored()
  local data = roundTrip(StadiumProgress())
  data.stadium = {["2d"] = {{lastStageBeaten = "five", continues = 2}, "nonsense"}, ["3d"] = 7}

  local progress = StadiumProgress.createFromData(data)

  local difficultyProgress = progress:get("2d", 1)
  assert(difficultyProgress.lastStageBeaten == 0 and difficultyProgress.continues == 2)
  assert(progress:get("2d", 2).lastStageBeaten == 0)
  assert(progress:get("3d", 1).lastStageBeaten == 0)
end

-- a file from a newer build is neither read as this version nor overwritten
local function newerFileIsLeftAlone()
  local data = roundTrip(StadiumProgress())
  data.version = StadiumProgress.CURRENT_VERSION + 1
  data.stadium["2d"][1].clears = 5

  local progress, upgraded = StadiumProgress.createFromData(data)

  assert(not upgraded)
  assert(progress:get("2d", 1).clears == 0, "fields of an unknown format are not taken over")
  local written = false
  local write = love.filesystem.write
  love.filesystem.write = function()
    written = true
  end
  progress:saveToFile()
  love.filesystem.write = write
  assert(not written, "the newer file stays as it is")
end

missingFileGivesFreshProgress()
progressSurvivesSaving()
clearResetsTheRun()
malformedDataIsIgnored()
newerFileIsLeftAlone()

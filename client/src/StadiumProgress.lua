local class = require("common.lib.class")
local json = require("common.lib.dkjson")
local fileUtils = require("client.src.FileUtils")
local StadiumLadder = require("common.data.StadiumLadder")

-- Stadium progress lives in a file of its own: scores.json is shared with upstream builds through the same save
-- identity, and they stop writing it once its version is one they don't know.
local FILE_NAME = "stadium.json"

-- 1 has per dimension and difficulty the run in progress, the clears and their bests
local CURRENT_VERSION = 1

---@alias StadiumDimension "2d" | "3d"

-- One difficulty of 1P Stadium in one dimension: the run in progress, which "resume" continues, and its clears
---@class StadiumDifficultyProgress
---@field lastStageBeaten integer the run's last beaten stage, 0 if none; a resumed run starts at the next one
---@field continues integer continues the run used so far
---@field time integer frames the run played so far, lost matches included
---@field clears integer how often the difficulty was finished
---@field bestContinues integer fewest continues of a finished run; meaningless while clears is 0
---@field bestTime integer fewest frames of a finished run; meaningless while clears is 0

local PROGRESS_FIELDS = {"lastStageBeaten", "continues", "time", "clears", "bestContinues", "bestTime"}
local DIMENSIONS = {"2d", "3d"}

---@return StadiumDifficultyProgress
local function newDifficultyProgress()
  return {lastStageBeaten = 0, continues = 0, time = 0, clears = 0, bestContinues = 0, bestTime = 0}
end

-- The saved 1P Stadium progress, per dimension and difficulty
---@class StadiumProgress
---@field version integer the file version; a newer one than this build knows is never overwritten
---@field stadium table<StadiumDimension, StadiumDifficultyProgress[]>
---@overload fun(): StadiumProgress
local StadiumProgress = class(
---@param self StadiumProgress
function(self)
  self.version = CURRENT_VERSION
  self.stadium = {}
  for _, dimension in ipairs(DIMENSIONS) do
    self.stadium[dimension] = {}
    for difficulty = 1, StadiumLadder.DIFFICULTY_COUNT do
      self.stadium[dimension][difficulty] = newDifficultyProgress()
    end
  end
end)

StadiumProgress.CURRENT_VERSION = CURRENT_VERSION
StadiumProgress.FILE_NAME = FILE_NAME

-- Builds the progress from the decoded contents of the file.
---@param data table? nil if there is no file
---@return StadiumProgress progress
---@return boolean upgraded true if the data was of an older version, so the file needs rewriting
function StadiumProgress.createFromData(data)
  local progress = StadiumProgress()
  if type(data) ~= "table" or type(data.version) ~= "number" then
    return progress, false
  end

  if data.version > CURRENT_VERSION then
    -- written by a newer build: keep its file intact rather than guess at its format
    progress.version = data.version
    return progress, false
  end

  -- version 1 is the only one so far; older versions would be upgraded here
  if type(data.stadium) == "table" then
    progress:loadFields(data.stadium)
  end
  return progress, data.version < CURRENT_VERSION
end

---@return StadiumProgress
function StadiumProgress.createFromFile()
  local data = nil
  pcall(function()
    data = fileUtils.readJsonFile(FILE_NAME)
  end)
  local progress, upgraded = StadiumProgress.createFromData(data)
  if upgraded then
    progress:saveToFile()
  end
  return progress
end

---@type StadiumProgress?
local loaded = nil

-- the player's progress, read from the file on first use
---@return StadiumProgress
function StadiumProgress.load()
  if not loaded then
    loaded = StadiumProgress.createFromFile()
  end
  return loaded
end

-- Takes over the saved progress field by field, so a hand edited or partial file can't break a run
---@param stadiumData table
function StadiumProgress:loadFields(stadiumData)
  for _, dimension in ipairs(DIMENSIONS) do
    local savedDifficulties = stadiumData[dimension]
    if type(savedDifficulties) == "table" then
      for difficulty, progress in ipairs(self.stadium[dimension]) do
        local saved = savedDifficulties[difficulty]
        if type(saved) == "table" then
          for _, field in ipairs(PROGRESS_FIELDS) do
            if type(saved[field]) == "number" then
              progress[field] = saved[field]
            end
          end
        end
      end
    end
  end
end

function StadiumProgress:saveToFile()
  if self.version == CURRENT_VERSION then
    love.filesystem.write(FILE_NAME, json.encode({version = self.version, stadium = self.stadium}))
  end
end

---@param dimension StadiumDimension
---@param difficulty integer
---@return StadiumDifficultyProgress progress the saved progress; change it only through the functions below
function StadiumProgress:get(dimension, difficulty)
  local progress = self.stadium[dimension] and self.stadium[dimension][difficulty]
  assert(progress, "No Stadium progress for " .. tostring(dimension) .. " difficulty " .. tostring(difficulty))
  return progress
end

-- Saves where the run of a difficulty stands, after every match
---@param dimension StadiumDimension
---@param difficulty integer
---@param lastStageBeaten integer
---@param continues integer
---@param time integer frames
function StadiumProgress:saveRun(dimension, difficulty, lastStageBeaten, continues, time)
  local progress = self:get(dimension, difficulty)
  progress.lastStageBeaten = lastStageBeaten
  progress.continues = continues
  progress.time = time
  self:saveToFile()
end

-- Forgets the run of a difficulty, as starting a new game does; its clears stay
---@param dimension StadiumDimension
---@param difficulty integer
function StadiumProgress:resetRun(dimension, difficulty)
  self:saveRun(dimension, difficulty, 0, 0, 0)
end

-- Records a finished run; the next game of the difficulty starts from its first stage again
---@param dimension StadiumDimension
---@param difficulty integer
---@param continues integer
---@param time integer frames
function StadiumProgress:saveClear(dimension, difficulty, continues, time)
  local progress = self:get(dimension, difficulty)
  if progress.clears == 0 or continues < progress.bestContinues then
    progress.bestContinues = continues
  end
  if progress.clears == 0 or time < progress.bestTime then
    progress.bestTime = time
  end
  progress.clears = progress.clears + 1
  self:resetRun(dimension, difficulty)
end

return StadiumProgress

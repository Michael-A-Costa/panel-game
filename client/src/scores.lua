local levelPresets = require("common.data.LevelPresets")
local fileUtils = require("client.src.FileUtils")
local PuzzleLibrary = require("client.src.PuzzleLibrary")
local tableUtils = require("common.lib.tableUtils")
local class = require("common.lib.class")
local logger = require("common.lib.logger")
local StadiumLadder = require("common.data.StadiumLadder")

-- 1 had only vs scores in an incompatible format
-- 2 has vs self, time attack, endless
-- 3 has vs self, time attack, endless, puzzles
-- 4 has vs self, time attack, endless, puzzles UUIDv2 (original)
-- 5 has vs self, time attack, endless, puzzles UUIDv2 (with cursor/buffers)
-- 6 adds 1P Stadium progress; older files get fresh progress
local currentVersion = 6

---@alias StadiumDimension "2d" | "3d"

-- One difficulty of 1P Stadium in one dimension: the run in progress, which "resume" continues, and its clears
---@class StadiumProgress
---@field lastStageBeaten integer the run's last beaten stage, 0 if none; a resumed run starts at the next one
---@field continues integer continues the run used so far
---@field time integer frames the run played so far, lost matches included
---@field clears integer how often the difficulty was finished
---@field bestContinues integer fewest continues of a finished run; meaningless while clears is 0
---@field bestTime integer fewest frames of a finished run; meaningless while clears is 0

local STADIUM_PROGRESS_FIELDS = {"lastStageBeaten", "continues", "time", "clears", "bestContinues", "bestTime"}
local STADIUM_DIMENSIONS = {"2d", "3d"}

---@return StadiumProgress
local function newStadiumProgress()
  return {lastStageBeaten = 0, continues = 0, time = 0, clears = 0, bestContinues = 0, bestTime = 0}
end

-- Holds on the current scores and records for game modes
---@class Scores
---@field version number
---@field vsSelf table
---@field timeAttack1P table
---@field endless table
---@field puzzleRecords table
---@field stadium table<StadiumDimension, StadiumProgress[]> progress per dimension and difficulty
Scores =
    class(
      function(self)
        -- The lastly used version
        self.version = currentVersion

        self.vsSelf = {}
        for i = 1, levelPresets.modernPresetCount do
          self.vsSelf[i] = {}
          self.vsSelf[i]["record"] = 0
          self.vsSelf[i]["last"] = 0
        end

        self.timeAttack1P = {}
        for i = 1, levelPresets.classicPresetCount do
          self.timeAttack1P[i] = {}
          self.timeAttack1P[i]["record"] = 0
          self.timeAttack1P[i]["last"] = 0
        end

        self.endless = {}
        for i = 1, levelPresets.classicPresetCount do
          self.endless[i] = {}
          self.endless[i]["record"] = 0
          self.endless[i]["last"] = 0
        end

        self.puzzleRecords = {}

        self.stadium = {}
        for _, dimension in ipairs(STADIUM_DIMENSIONS) do
          self.stadium[dimension] = {}
          for difficulty = 1, StadiumLadder.DIFFICULTY_COUNT do
            self.stadium[dimension][difficulty] = newStadiumProgress()
          end
        end
      end
    )

-- Saves the given puzzle record to the scores file
function Scores:savePuzzleRecord(puzzle, inputs, timestamp, success)
  assert(puzzle.UUID ~= nil)
  local puzzleRecord = {}
  puzzleRecord.inputs = inputs
  puzzleRecord.timestamp = timestamp
  puzzleRecord.success = success

  if self.puzzleRecords[puzzle.UUID] == nil then
    self.puzzleRecords[puzzle.UUID] = {}
  end
  self.puzzleRecords[puzzle.UUID][#self.puzzleRecords[puzzle.UUID] + 1] = puzzleRecord

  self:saveToFile()
end

-- Returns all records for the given puzzle UUID
function Scores:getRecordsForPuzzleUUID(puzzleUUID)
  return self.puzzleRecords[puzzleUUID] or {}
end

-- Returns up to the given number of records for a given puzzle UUID, only counting using the filter if one is given.
---@param n integer the number of records to return
---@param filter function? an optional filter function run on a record, return true if the record should be included
---@param puzzleUUID string the puzzle UUID to search
function Scores:getNRecordsMatchingFilterForPuzzleUUID(n, filter, puzzleUUID)
  local filteredTable = {}
  local records = self:getRecordsForPuzzleUUID(puzzleUUID)
  for i = #records, 1, -1 do
    local value = records[i]
    if filter(value) then
      filteredTable[#filteredTable + 1] = value
      if #filteredTable >= n then
        break
      end
    end
  end

  return filteredTable
end

-- Returns the latest record that succeed at this puzzle or nil if none
function Scores:getLatestSuccessForPuzzleUUID(puzzleUUID)
  local records = self:getNRecordsMatchingFilterForPuzzleUUID(1, function(record) return record.success == true end,
    puzzleUUID)
  if #records == 0 then
    return nil
  end
  return records[#records]
end

-- Returns the number of times this puzzle has been won in a row
function Scores:puzzleUUIDWinStreak(puzzleUUID)
  local records = self:getRecordsForPuzzleUUID(puzzleUUID)

  local winStreak = 0
  for i = #records, 1, -1 do
    local currentRecord = records[i]
    if currentRecord.success == false then
      break
    end
    winStreak = winStreak + 1
  end

  return winStreak
end

-- returns true if the puzzle has ever been beaten
function Scores:puzzleEverBeaten(puzzleUUID)
  return self:getLatestSuccessForPuzzleUUID(puzzleUUID) ~= nil
end

-- Returns 0 if the puzzle has never been played, otherwise, the percentage of wins
function Scores:puzzleSuccessRateForUUID(puzzleUUID)
  local records = self:getNRecordsMatchingFilterForPuzzleUUID(5, function(record) return true end, puzzleUUID)

  if #records == 0 then
    return 0
  end

  local winRecords = tableUtils.filter(records, function(record) return record.success end)

  local result = #winRecords / #records
  return result
end

function Scores.saveVsSelfScoreForLevel(self, score, level)
  self.vsSelf[level]["last"] = score
  if self.vsSelf[level]["record"] < score then
    self.vsSelf[level]["record"] = score
  end
  self:saveToFile()
end

function Scores.lastVsScoreForLevel(self, level)
  if #self.vsSelf < level then
    return 0
  end
  return self.vsSelf[level]["last"]
end

function Scores.recordVsScoreForLevel(self, level)
  if #self.vsSelf < level then
    return 0
  end
  return self.vsSelf[level]["record"]
end

function Scores.saveTimeAttack1PScoreForLevel(self, score, level)
  self.timeAttack1P[level]["last"] = score
  if self.timeAttack1P[level]["record"] < score then
    self.timeAttack1P[level]["record"] = score
  end
  self:saveToFile()
end

function Scores.lastTimeAttack1PForLevel(self, level)
  if #self.timeAttack1P < level then
    return 0
  end
  return self.timeAttack1P[level]["last"]
end

function Scores.recordTimeAttack1PForLevel(self, level)
  if #self.timeAttack1P < level then
    return 0
  end
  return self.timeAttack1P[level]["record"]
end

function Scores.saveEndlessScoreForLevel(self, score, level)
  self.endless[level]["last"] = score
  if self.endless[level]["record"] < score then
    self.endless[level]["record"] = score
  end
  self:saveToFile()
end

function Scores.lastEndlessForLevel(self, level)
  if #self.endless < level then
    return 0
  end
  return self.endless[level]["last"]
end

function Scores.recordEndlessForLevel(self, level)
  if #self.endless < level then
    return 0
  end
  return self.endless[level]["record"]
end

function Scores.createFromScoreFile()
  local scoreData = nil
  pcall(
    function()
      scoreData = fileUtils.readJsonFile("scores.json")
    end
  )
  local scores, upgraded = Scores.createFromScoreData(scoreData)
  if upgraded then
    scores:saveToFile()
  end

  return scores
end

-- Builds the scores from the decoded contents of a scores file, upgrading older versions
---@param scoreData table? nil if there is no file
---@return Scores scores
---@return boolean upgraded true if the data was of an older version, so the file needs rewriting
function Scores.createFromScoreData(scoreData)
  local scores = Scores()
  local upgraded = false
  if scoreData then
    if scoreData.version and type(scoreData.version) == "number" then
      scores.version = scoreData.version
    elseif scoreData.vsSelf["last"] then
      scores.version = 1
    end

    -- Ignore the scores save file if its the original incompatible format
    if scores.version > 1 then
      if scoreData.vsSelf then
        scores.vsSelf = scoreData.vsSelf
      end
      if scoreData.timeAttack1P then
        scores.timeAttack1P = scoreData.timeAttack1P
      end
      if scoreData.endless then
        scores.endless = scoreData.endless
      end
      if scoreData.puzzleRecords then
        local puzzleRecords = scoreData.puzzleRecords
        scores.puzzleRecords = puzzleRecords
        if scores.version == 3 then
          scores:upgradeFromScoreData(scoreData)
        elseif scores.version == 4 then
          scores:upgradeFromV4ToV5(scoreData)
        end
      end
      -- before 6 there is no Stadium progress, so the constructor's empty progress stands
      if scoreData.stadium then
        scores:loadStadiumProgress(scoreData.stadium)
      end

      if scores.version < currentVersion then
        scores.version = currentVersion
        upgraded = true
      end
    end
  end

  return scores, upgraded
end

-- Takes over the saved Stadium progress field by field, so a hand edited or partial file can't break a run
---@param stadiumData table
function Scores:loadStadiumProgress(stadiumData)
  for _, dimension in ipairs(STADIUM_DIMENSIONS) do
    local savedDifficulties = stadiumData[dimension]
    if type(savedDifficulties) == "table" then
      for difficulty, progress in ipairs(self.stadium[dimension]) do
        local saved = savedDifficulties[difficulty]
        if type(saved) == "table" then
          for _, field in ipairs(STADIUM_PROGRESS_FIELDS) do
            if type(saved[field]) == "number" then
              progress[field] = saved[field]
            end
          end
        end
      end
    end
  end
end

function Scores:upgradeFromScoreData(scoreData)
  local puzzleLibrary = PuzzleLibrary(Scores())
  local defaultPuzzleSet = puzzleLibrary:getDefaultPuzzleSet()
  local flattenedPuzzleSet = puzzleLibrary:flattenedPuzzleSetForPuzzleSet(defaultPuzzleSet)
  for _, puzzle in ipairs(flattenedPuzzleSet.puzzles) do
    local oldUUID = puzzle:getV1UUID()
    local newUUID = puzzle:getV2UUID()
    if self.puzzleRecords[oldUUID] then
      local oldRecords = self.puzzleRecords[oldUUID]
      for _, record in ipairs(oldRecords) do
        record.UUID = nil
      end
      self.puzzleRecords[newUUID] = oldRecords
      self.puzzleRecords[oldUUID] = nil
    end
  end
end

function Scores:upgradeFromV4ToV5(scoreData)
  local puzzleLibrary = PuzzleLibrary(Scores())
  local defaultPuzzleSet = puzzleLibrary:getDefaultPuzzleSet()
  local flattenedPuzzleSet = puzzleLibrary:flattenedPuzzleSetForPuzzleSet(defaultPuzzleSet)
  for _, puzzle in ipairs(flattenedPuzzleSet.puzzles) do
    local oldUUID = puzzle:getV2UUIDOld()
    local newUUID = puzzle:getV2UUID()
    if self.puzzleRecords[oldUUID] then
      local oldRecords = self.puzzleRecords[oldUUID]
      for _, record in ipairs(oldRecords) do
        record.UUID = nil
      end
      self.puzzleRecords[newUUID] = oldRecords
      self.puzzleRecords[oldUUID] = nil
    end
  end
end

-- Moves the records saved under the puzzle's old UUIDs to its current one, in the order the UUIDs are listed;
-- records already under the current UUID stay after the carried ones
---@param puzzle Puzzle
---@return boolean moved whether any record moved, so the scores need saving
function Scores:carryRecordsToPuzzle(puzzle)
  local carried = {}
  for _, oldUUID in ipairs(puzzle.oldUUIDs or {}) do
    for _, record in ipairs(self.puzzleRecords[oldUUID] or {}) do
      carried[#carried + 1] = record
    end
    self.puzzleRecords[oldUUID] = nil
  end
  if #carried == 0 then
    return false
  end

  for _, record in ipairs(self.puzzleRecords[puzzle.UUID] or {}) do
    carried[#carried + 1] = record
  end
  self.puzzleRecords[puzzle.UUID] = carried
  return true
end

---@param dimension StadiumDimension
---@param difficulty integer
---@return StadiumProgress progress the saved progress; change it only through the Scores functions below
function Scores:getStadiumProgress(dimension, difficulty)
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
function Scores:saveStadiumRun(dimension, difficulty, lastStageBeaten, continues, time)
  local progress = self:getStadiumProgress(dimension, difficulty)
  progress.lastStageBeaten = lastStageBeaten
  progress.continues = continues
  progress.time = time
  self:saveToFile()
end

-- Forgets the run of a difficulty, as starting a new game does; its clears stay
---@param dimension StadiumDimension
---@param difficulty integer
function Scores:resetStadiumRun(dimension, difficulty)
  self:saveStadiumRun(dimension, difficulty, 0, 0, 0)
end

-- Records a finished run; the next game of the difficulty starts from its first stage again
---@param dimension StadiumDimension
---@param difficulty integer
---@param continues integer
---@param time integer frames
function Scores:saveStadiumClear(dimension, difficulty, continues, time)
  local progress = self:getStadiumProgress(dimension, difficulty)
  if progress.clears == 0 or continues < progress.bestContinues then
    progress.bestContinues = continues
  end
  if progress.clears == 0 or time < progress.bestTime then
    progress.bestTime = time
  end
  progress.clears = progress.clears + 1
  self:resetStadiumRun(dimension, difficulty)
end

function Scores.saveToFile(self)
  if self.version == currentVersion then
    love.filesystem.write("scores.json", json.encode(self))
  end
end

return Scores

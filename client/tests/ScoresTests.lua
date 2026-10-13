local Scores = require("client.src.scores")
local StadiumLadder = require("common.data.StadiumLadder")

local function record(timestamp)
  return {inputs = "A", timestamp = timestamp, success = true}
end

-- a puzzle whose UUID changed keeps the records it had under the old one
local function recordsUnderAnOldUUIDMoveToThePuzzle()
  local scores = Scores()
  scores.puzzleRecords["old"] = {record(1), record(2)}

  local moved = scores:carryRecordsToPuzzle({UUID = "new", oldUUIDs = {"old"}})

  assert(moved, "a record was moved, so the scores need saving")
  assert(scores.puzzleRecords["old"] == nil, "nothing is left under the old UUID")
  assert(#scores.puzzleRecords["new"] == 2 and scores.puzzleRecords["new"][2].timestamp == 2, "both records are under the new UUID")
end

-- records already made under the new UUID stay, after the older ones carried across
local function carriedRecordsGoBeforeTheNewOnes()
  local scores = Scores()
  scores.puzzleRecords["old"] = {record(1)}
  scores.puzzleRecords["new"] = {record(5)}

  scores:carryRecordsToPuzzle({UUID = "new", oldUUIDs = {"old"}})

  local records = scores.puzzleRecords["new"]
  assert(#records == 2 and records[1].timestamp == 1 and records[2].timestamp == 5, "the carried record comes first")
end

-- a puzzle changed twice lists both old UUIDs, oldest first, and its records keep that order
local function recordsUnderEveryOldUUIDMoveInListOrder()
  local scores = Scores()
  scores.puzzleRecords["first"] = {record(1)}
  scores.puzzleRecords["second"] = {record(2)}

  scores:carryRecordsToPuzzle({UUID = "third", oldUUIDs = {"first", "second"}})

  local records = scores.puzzleRecords["third"]
  assert(scores.puzzleRecords["first"] == nil and scores.puzzleRecords["second"] == nil)
  assert(#records == 2 and records[1].timestamp == 1 and records[2].timestamp == 2, "the records keep their order")
end

-- once carried, loading again moves nothing, so the scores file is not rewritten on every start
local function nothingToCarryMovesNothing()
  local scores = Scores()
  scores.puzzleRecords["new"] = {record(1)}

  assert(not scores:carryRecordsToPuzzle({UUID = "new", oldUUIDs = {"old"}}))
  assert(not scores:carryRecordsToPuzzle({UUID = "new"}), "a puzzle that never changed has nothing to carry")
  assert(#scores.puzzleRecords["new"] == 1)
end

recordsUnderAnOldUUIDMoveToThePuzzle()
carriedRecordsGoBeforeTheNewOnes()
recordsUnderEveryOldUUIDMoveInListOrder()
nothingToCarryMovesNothing()

-- a version 5 file has no Stadium progress: it loads with fresh progress everywhere, keeps the rest and is
-- marked for rewriting as version 6
local function version5GainsStadiumProgress()
  local data = json.decode(json.encode(Scores()))
  data.version = 5
  data.stadium = nil
  data.vsSelf[3].record = 1234

  local scores, upgraded = Scores.createFromScoreData(data)

  assert(upgraded, "an older file gets rewritten")
  assert(scores.version == 6)
  assert(scores.vsSelf[3].record == 1234, "the older records stay")
  for _, dimension in ipairs({"2d", "3d"}) do
    for difficulty = 1, StadiumLadder.DIFFICULTY_COUNT do
      local progress = scores:getStadiumProgress(dimension, difficulty)
      assert(progress.lastStageBeaten == 0 and progress.continues == 0 and progress.clears == 0,
             "fresh progress for " .. dimension .. " difficulty " .. difficulty)
    end
  end
end

-- Scores whose saving is counted instead of writing scores.json
---@return Scores
local function createUnsavedScores()
  local scores = Scores()
  scores.saveCount = 0
  scores.saveToFile = function(self)
    self.saveCount = self.saveCount + 1
  end
  return scores
end

-- runs, clears and their bests are kept per dimension and difficulty and survive the trip through the file
local function stadiumProgressSurvivesSaving()
  local scores = createUnsavedScores()
  scores:saveStadiumRun("2d", 2, 6, 3, 5000)
  scores:saveStadiumClear("3d", 4, 7, 90000)
  scores:saveStadiumClear("3d", 4, 2, 95000)
  scores:saveStadiumRun("3d", 4, 9, 1, 400)
  assert(scores.saveCount == 4, "every change is saved")
  scores.saveToFile = nil
  scores.saveCount = nil

  local loaded, upgraded = Scores.createFromScoreData(json.decode(json.encode(scores)))

  assert(not upgraded, "a current file is not rewritten")
  local run = loaded:getStadiumProgress("2d", 2)
  assert(run.lastStageBeaten == 6 and run.continues == 3 and run.time == 5000 and run.clears == 0)
  local cleared = loaded:getStadiumProgress("3d", 4)
  assert(cleared.clears == 2, "both clears count")
  assert(cleared.bestContinues == 2 and cleared.bestTime == 90000, "the bests are kept apart")
  assert(cleared.lastStageBeaten == 9 and cleared.continues == 1, "with the run started after them")
  assert(loaded:getStadiumProgress("2d", 4).clears == 0, "2D and 3D are separate")
end

-- a clear ends the run, so the next game of the difficulty starts at its first stage
local function clearResetsTheRun()
  local scores = createUnsavedScores()
  scores:saveStadiumRun("2d", 1, 10, 4, 3000)
  scores:saveStadiumClear("2d", 1, 4, 3600)

  local progress = scores:getStadiumProgress("2d", 1)
  assert(progress.lastStageBeaten == 0 and progress.continues == 0 and progress.time == 0)
  assert(progress.clears == 1 and progress.bestContinues == 4 and progress.bestTime == 3600)
end

-- odd values in a hand edited file are skipped field by field instead of breaking the run
local function malformedStadiumDataIsIgnored()
  local data = json.decode(json.encode(Scores()))
  data.stadium = {["2d"] = {{lastStageBeaten = "five", continues = 2}, "nonsense"}, ["3d"] = 7}

  local scores = Scores.createFromScoreData(data)

  local progress = scores:getStadiumProgress("2d", 1)
  assert(progress.lastStageBeaten == 0 and progress.continues == 2)
  assert(scores:getStadiumProgress("2d", 2).lastStageBeaten == 0)
  assert(scores:getStadiumProgress("3d", 1).lastStageBeaten == 0)
end

version5GainsStadiumProgress()
stadiumProgressSurvivesSaving()
clearResetsTheRun()
malformedStadiumDataIsIgnored()

local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")

-- The 1P Stadium ladder after Pokémon Puzzle League (docs/cpu-ai/STADIUM-SPEC.md): five difficulties of 11 to 16
-- stages against the PPL CPU. Data only; the client turns the title keys into text and dresses each opponent in a
-- Panel Attack character.

---@alias StadiumRole
---| "rival" # the opponent of the first stage, met again right before the boss
---| "boss" # the last stage of the top difficulties; losing to it sends the player back to the rival

---@class StadiumStage
---@field index integer the stage's place in its difficulty's ladder
---@field cpuOptions CpuStrength the PPL CPU preset, Stadium difficulty and stage; ClientMatch adds the seed
---@field level integer the Panel Attack modern level both stacks play on
---@field role StadiumRole?
---@field titleKey string localization key of the stage's title
---@field titleNumber integer? fills the title's %1, e.g. the 3 of "Gym 3"
---@field introKey string? localization key of the story screen PPL shows on reaching the stage
---@field beatenKey string? localization key of the scene PPL shows after beating the stage, in place of the result

---@class StadiumDifficulty
---@field index integer 1 Easy .. 5 Super Hard
---@field nameKey string localization key of the difficulty's name
---@field level integer the Panel Attack modern level of every stage
---@field unlockedBy integer? the difficulty whose ending reveals this one's code; nil if open from the start
---@field unlockCode string[]? the buttons pressed while holding Raise1 on the difficulty select to unlock it
---@field helperPairs PplHelperPairs? how often a new row brings a ready-made pair
---@field endingKey string localization key of the difficulty's ending
---@field credits boolean the ending rolls the credits
---@field stages StadiumStage[]

local StadiumLadder = {}

StadiumLadder.EASY = 1
StadiumLadder.NORMAL = 2
StadiumLadder.HARD = 3
StadiumLadder.VERY_HARD = 4
StadiumLadder.SUPER_HARD = 5

-- PPL plays both stacks on its 2P VS level 1, 2 or 4 by difficulty, which are Panel Attack's modern levels 1, 2 and 4
-- (STADIUM-SPEC §6)
local LEVEL_BY_DIFFICULTY = {1, 2, 4, 4, 4}

-- PPL resumes a saved run at the stage after the last one beaten, but never past stage 15 (STADIUM-SPEC §3.1), so a
-- run saved after the rival's rematch starts on the rival again: rival and boss are always beaten back to back
local RESUME_STAGE_CAP = 15

-- PPL unlocks the top two with button codes that the endings below them show: hold Z and press L, L, A, B for
-- Very Hard, R, L, A, B for Super Hard (STADIUM-SPEC §1 "Unlocks"). Panel Attack has no Z, L or R, so Raise1 is held
-- and the shoulders become Left and Right; A and B are Swap1 and Swap2, as they are in Panel Attack.
local UNLOCKED_BY = {nil, nil, nil, StadiumLadder.HARD, StadiumLadder.VERY_HARD}
local UNLOCK_CODES = {
  [StadiumLadder.VERY_HARD] = {"Left", "Left", "Swap1", "Swap2"},
  [StadiumLadder.SUPER_HARD] = {"Right", "Left", "Swap1", "Swap2"},
}

-- PPL's state.newBlock per difficulty: Easy 0 (a pair in every new row), Normal and Hard 1 (every other row), Very
-- and Super Hard 3 (never) (STADIUM-SPEC §2 "Stack level")
local HELPER_PAIRS = {"every", "alternate", "alternate", nil, nil}

-- Easy and Normal end on an ending screen; Hard and up roll the credits (STADIUM-SPEC §1 "Difficulties")
local CREDITS_FROM = StadiumLadder.HARD

-- PPL's story screens (STADIUM-SPEC §1 "Opponent order" and §3): the intro before the first match, the elites'
-- introduction on reaching stage 12, the boss's intro, and the scenes after beating the rival and the two wanderers
local INTRO_KEYS = {[1] = "stadium_story_intro", [12] = "stadium_story_elite", [16] = "stadium_story_boss"}
local BEATEN_KEYS = {
  [1] = "stadium_story_rival_beaten",
  [9] = "stadium_story_wanderer_beaten",
  [10] = "stadium_story_rogues_beaten",
}

-- PPL's opponent order (STADIUM-SPEC §1) with neutral titles: the rival, seven gyms, two wanderers, the eighth gym,
-- three elites, the rival as champion and the boss. Every difficulty plays a prefix of it.
local STAGE_TITLES = {
  {key = "stadium_title_rival", role = "rival"},
  {key = "stadium_title_gym", number = 1},
  {key = "stadium_title_gym", number = 2},
  {key = "stadium_title_gym", number = 3},
  {key = "stadium_title_gym", number = 4},
  {key = "stadium_title_gym", number = 5},
  {key = "stadium_title_gym", number = 6},
  {key = "stadium_title_gym", number = 7},
  {key = "stadium_title_wanderer"},
  {key = "stadium_title_rogues"},
  {key = "stadium_title_gym", number = 8},
  {key = "stadium_title_elite", number = 1},
  {key = "stadium_title_elite", number = 2},
  {key = "stadium_title_elite", number = 3},
  {key = "stadium_title_champion", role = "rival"},
  {key = "stadium_title_boss", role = "boss"},
}

---@param difficulty integer
---@return StadiumDifficulty
local function createDifficulty(difficulty)
  local level = LEVEL_BY_DIFFICULTY[difficulty]
  local stages = {}
  for index = 1, ComputerPlayer.STAGE_COUNTS[difficulty] do
    local title = STAGE_TITLES[index]
    stages[index] = {
      index = index,
      cpuOptions = {difficulty = difficulty, stage = index},
      level = level,
      role = title.role,
      titleKey = title.key,
      titleNumber = title.number,
      introKey = INTRO_KEYS[index],
      beatenKey = BEATEN_KEYS[index],
    }
  end

  return {
    index = difficulty,
    nameKey = "stadium_difficulty_" .. difficulty,
    level = level,
    unlockedBy = UNLOCKED_BY[difficulty],
    unlockCode = UNLOCK_CODES[difficulty],
    helperPairs = HELPER_PAIRS[difficulty],
    endingKey = "stadium_ending_" .. difficulty,
    credits = difficulty >= CREDITS_FROM,
    stages = stages,
  }
end

---@type StadiumDifficulty[]
StadiumLadder.difficulties = {}
for difficulty = 1, #ComputerPlayer.STAGE_COUNTS do
  StadiumLadder.difficulties[difficulty] = createDifficulty(difficulty)
end

StadiumLadder.DIFFICULTY_COUNT = #StadiumLadder.difficulties

---@param difficulty integer
---@return StadiumDifficulty
function StadiumLadder.getDifficulty(difficulty)
  local ladder = StadiumLadder.difficulties[difficulty]
  assert(ladder, "Stadium has difficulties 1 to " .. StadiumLadder.DIFFICULTY_COUNT .. ", got " .. tostring(difficulty))
  return ladder
end

-- The stage a resumed run starts on
---@param difficulty integer
---@param lastStageBeaten integer from the saved progress
---@return integer
function StadiumLadder.getResumeStage(difficulty, lastStageBeaten)
  local stageCount = #StadiumLadder.getDifficulty(difficulty).stages
  return math.min(lastStageBeaten + 1, stageCount, RESUME_STAGE_CAP)
end

return StadiumLadder

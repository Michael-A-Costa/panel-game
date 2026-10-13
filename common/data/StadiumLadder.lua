local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")

-- The 1P Stadium ladder after Pokémon Puzzle League (docs/stadium/STADIUM-SPEC.md): five difficulties of 11 to 16
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

---@class StadiumDifficulty
---@field index integer 1 Easy .. 5 Super Hard
---@field nameKey string localization key of the difficulty's name
---@field level integer the Panel Attack modern level of every stage
---@field unlockedBy integer? the difficulty whose clear unlocks this one; nil if open from the start
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

-- PPL unlocks the top two with button codes; here clearing the difficulty below does (PLAN "Decisions taken")
local UNLOCKED_BY = {nil, nil, nil, StadiumLadder.HARD, StadiumLadder.VERY_HARD}

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
    }
  end

  return {
    index = difficulty,
    nameKey = "stadium_difficulty_" .. difficulty,
    level = level,
    unlockedBy = UNLOCKED_BY[difficulty],
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

return StadiumLadder

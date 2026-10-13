require("common.lib.util")
local class = require("common.lib.class")
local MatchRules = require("common.data.MatchRules")
local TIME_ATTACK_TIME = 120

local GameModes = {}

---@class GameMode
---@field stackInteraction StackInteractions
---@field matchRules MatchRules
---@field playerCount integer
---@field name string
--- the following properties should be strictly client side rather than universal
--- but since they're just magic strings without dependencies it's not like they ruin anything for now
---@field gameScene string
---@field style Styles
---@field richPresenceLabel string?
---@field updateLocalPlayersDerivedSettings function
---@field gameModeId GameModeID
local GameMode = class(function(self, properties)
  for key, value in pairs(properties) do
    self[key] = value
  end
end)

-- Returns a copy of the game mode data suitable for JSON serialization
-- Removes all methods/functions from the copied data
---@return table
function GameMode:getGameModeJSONData()
  local gameModeData = deepcpy(self)
  for key, value in pairs(gameModeData) do
    if type(value) == "function" then
      gameModeData[key] = nil
    end
  end
  return gameModeData
end

-- longterm we want to abandon the concept of "style" on the engine and room setup level
-- the engine only cares about levelData, style is a menu-only concept
-- there is no technical reason why someone on level 10 shouldn't be able to play against someone on Hard
-- meaning the props which scene uses which style should live on the scenes, not here
---@enum Styles
local Styles = { CHOOSE = 0, CLASSIC = 1, MODERN = 2}
---@enum StackInteractions
local StackInteractions = { NONE = 0, VERSUS = 1, SELF = 2, ATTACK_ENGINE = 3 }

---@type GameMode
local OnePlayerVsSelf = GameMode({
  gameScene = "VsSelfGame",
  richPresenceLabel = "1p vs self", -- loc("mm_1_vs"),
  name = "vsSelf",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.SELF,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 0 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

---@type GameMode
local OnePlayerTimeAttack = GameMode({
  gameScene = "TimeAttackGame",
  richPresenceLabel = "Time Attack", -- loc("mm_1_time"),
  name = "timeattack",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.NONE,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 0, [MatchRules.MatchEndConditions.TIME_LIMIT] = TIME_ATTACK_TIME * 60 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.SCORE] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

---@type GameMode
local OnePlayerEndless = GameMode({
  gameScene = "EndlessGame",
  richPresenceLabel = "Endless", -- loc("mm_1_endless"),
  name = "endless",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.NONE,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 0 },
    matchWinRuleset = { {[MatchRules.MatchWinCriterias.SCORE] = MatchRules.orders.HIGHEST}, { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

---@type GameMode
local OnePlayerTraining = GameMode({
  gameScene = "GameBase",
  richPresenceLabel = "Training", -- loc("mm_1_training"),
  name = "training",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.ATTACK_ENGINE,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 1 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

---@type GameMode
local OnePlayerPuzzle = GameMode({
  -- flags for battleRoom to evaluate and in some cases offer UI for
  richPresenceLabel = "Puzzle", -- loc("mm_1_puzzle"),
  gameScene = "PuzzleGame",
  name = "puzzle",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.NONE,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 0 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.TIME] = MatchRules.orders.LOWEST} },
    -- these are extended based on the loaded puzzle
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    -- these are extended based on the loaded puzzle
    stackWinConditions = {},
    -- these are extended based on the loaded puzzle
    stackSetupModifications = {},
    doCountdown = false,
  },

})

---@type GameMode
local OnePlayerChallenge = GameMode({
  gameScene = "Game1pChallenge",
  richPresenceLabel = "Challenge Mode", -- loc("mm_1_challenge_mode"),
  name = "challenge",

  -- already known match properties
  playerCount = 1,
  stackInteraction = StackInteractions.VERSUS,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 1 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

---@type GameMode
local TwoPlayerVersus = GameMode({
  gameScene = "GameBase",
  richPresenceLabel = "2p versus", -- loc("mm_2_vs"),
  name = "VS",

  -- already known match properties
  playerCount = 2,
  stackInteraction = StackInteractions.VERSUS,
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 1 },
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST} },
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true
  },

})
---@type GameMode
local TwoPlayerTimeAttack = GameMode({
  gameScene = "TimeAttackGame",
  richPresenceLabel = "2p Time Attack", -- loc("mm_2_time"),
  name = "2p_timeattack",

  playerCount = 2,
  stackInteraction = StackInteractions.NONE, -- Cambia VERSUS por NONE
  matchRules = {
    matchEndConditions = { [MatchRules.MatchEndConditions.STACKS_ACTIVE] = 1, [MatchRules.MatchEndConditions.TIME_LIMIT] = TIME_ATTACK_TIME * 60},
    matchWinRuleset = { { [MatchRules.MatchWinCriterias.GAME_OVER_CLOCK] = MatchRules.orders.HIGHEST }, { [MatchRules.MatchWinCriterias.SCORE] = MatchRules.orders.HIGHEST }},
    stackOverConditions = { [MatchRules.StackOverConditions.HEALTH] = 0 },
    stackWinConditions = {},
    stackSetupModifications = {},
    doCountdown = true,
  },

})

-- the 3D modes play their 2D counterparts on a cylinder
---@param gameMode GameMode
---@param name string
---@param richPresenceLabel string
---@return GameMode
local function cylinderVariant(gameMode, name, richPresenceLabel)
  local variant = deepcpy(gameMode)
  variant.name = name
  variant.richPresenceLabel = richPresenceLabel
  variant.matchRules.stackSetupModifications.cylinder = true
  return variant
end

local OnePlayerEndless3D = cylinderVariant(OnePlayerEndless, "endless3d", "Endless 3D")
local OnePlayerTimeAttack3D = cylinderVariant(OnePlayerTimeAttack, "timeattack3d", "Time Attack 3D")
local TwoPlayerVersus3D = cylinderVariant(TwoPlayerVersus, "VS3d", "2p versus 3D")
local OnePlayerTraining3D = cylinderVariant(OnePlayerTraining, "training3d", "Training 3D")
-- only the player's stack becomes a cylinder, the challenger is an attack engine without a board
local OnePlayerChallenge3D = cylinderVariant(OnePlayerChallenge, "challenge3d", "Challenge Mode 3D")

GameModes.Styles = Styles
GameModes.StackInteractions = StackInteractions

---@enum (key) GameModeID Used as identifier for the type of game that is being played
GameModes.IDs = {
  TWO_PLAYER_VS = "TWO_PLAYER_VS",
  ONE_PLAYER_TIME_ATTACK = "ONE_PLAYER_TIME_ATTACK",
  ONE_PLAYER_ENDLESS = "ONE_PLAYER_ENDLESS",
  ONE_PLAYER_TRAINING = "ONE_PLAYER_TRAINING",
  ONE_PLAYER_CHALLENGE = "ONE_PLAYER_CHALLENGE",
  ONE_PLAYER_VS_SELF = "ONE_PLAYER_VS_SELF",
  ONE_PLAYER_PUZZLE = "ONE_PLAYER_PUZZLE",
  TWO_PLAYER_TIME_ATTACK = "TWO_PLAYER_TIME_ATTACK",
  ONE_PLAYER_ENDLESS_3D = "ONE_PLAYER_ENDLESS_3D",
  ONE_PLAYER_TIME_ATTACK_3D = "ONE_PLAYER_TIME_ATTACK_3D",
  TWO_PLAYER_VS_3D = "TWO_PLAYER_VS_3D",
  ONE_PLAYER_TRAINING_3D = "ONE_PLAYER_TRAINING_3D",
  ONE_PLAYER_CHALLENGE_3D = "ONE_PLAYER_CHALLENGE_3D",
}

---@type table<GameModeID, GameMode>
local privateGameModes = {}
privateGameModes[GameModes.IDs.ONE_PLAYER_VS_SELF] = OnePlayerVsSelf
privateGameModes[GameModes.IDs.ONE_PLAYER_TIME_ATTACK] = OnePlayerTimeAttack
privateGameModes[GameModes.IDs.ONE_PLAYER_ENDLESS] = OnePlayerEndless
privateGameModes[GameModes.IDs.ONE_PLAYER_TRAINING] = OnePlayerTraining
privateGameModes[GameModes.IDs.ONE_PLAYER_PUZZLE] = OnePlayerPuzzle
privateGameModes[GameModes.IDs.ONE_PLAYER_CHALLENGE] = OnePlayerChallenge
privateGameModes[GameModes.IDs.TWO_PLAYER_VS] = TwoPlayerVersus
privateGameModes[GameModes.IDs.TWO_PLAYER_TIME_ATTACK] = TwoPlayerTimeAttack
privateGameModes[GameModes.IDs.ONE_PLAYER_ENDLESS_3D] = OnePlayerEndless3D
privateGameModes[GameModes.IDs.ONE_PLAYER_TIME_ATTACK_3D] = OnePlayerTimeAttack3D
privateGameModes[GameModes.IDs.TWO_PLAYER_VS_3D] = TwoPlayerVersus3D
privateGameModes[GameModes.IDs.ONE_PLAYER_TRAINING_3D] = OnePlayerTraining3D
privateGameModes[GameModes.IDs.ONE_PLAYER_CHALLENGE_3D] = OnePlayerChallenge3D

---@param mode GameModeID
---@return GameMode
function GameModes.getPreset(mode)
  assert(privateGameModes[mode], "Trying to access non existing mode " .. mode)
  return deepcpy(privateGameModes[mode])
end

-- Creates a GameMode from server message data by loading the preset and applying overrides
---@param gameModeData table The game mode data from the server message
---@return GameMode
function GameModes.createFromServerData(gameModeData)
  local preset = nil
  for _, gameMode in pairs(privateGameModes) do
    if gameMode.name == gameModeData.name then
      preset = gameMode
      break
    end
  end

  assert(preset, "Unknown game mode name: " .. tostring(gameModeData.name))

  local result = deepcpy(preset)

  for key, value in pairs(gameModeData) do
    result[key] = value
  end

  return result
end

---@type table<GameModeID, string>
GameModes.gameModeIdToName = {
  TWO_PLAYER_VS = "VS",
  ONE_PLAYER_TIME_ATTACK = "timeattack",
  ONE_PLAYER_ENDLESS = "endless",
  ONE_PLAYER_TRAINING = "training",
  ONE_PLAYER_CHALLENGE = "challenge",
  ONE_PLAYER_VS_SELF = "vsSelf",
  ONE_PLAYER_PUZZLE = "puzzle",
  TWO_PLAYER_TIME_ATTACK = "2p_timeattack",
  ONE_PLAYER_ENDLESS_3D = "endless3d",
  ONE_PLAYER_TIME_ATTACK_3D = "timeattack3d",
  TWO_PLAYER_VS_3D = "VS3d",
  ONE_PLAYER_TRAINING_3D = "training3d",
  ONE_PLAYER_CHALLENGE_3D = "challenge3d",
}

---@type table<string, GameModeID>
GameModes.nameToGameModeId = {
  VS = "TWO_PLAYER_VS",
  timeattack = "ONE_PLAYER_TIME_ATTACK",
  endless = "ONE_PLAYER_ENDLESS",
  training = "ONE_PLAYER_TRAINING",
  challenge = "ONE_PLAYER_CHALLENGE",
  vsSelf = "ONE_PLAYER_VS_SELF",
  puzzle = "ONE_PLAYER_PUZZLE",
  ["2p_timeattack"] = "TWO_PLAYER_TIME_ATTACK",
  endless3d = "ONE_PLAYER_ENDLESS_3D",
  timeattack3d = "ONE_PLAYER_TIME_ATTACK_3D",
  VS3d = "TWO_PLAYER_VS_3D",
  training3d = "ONE_PLAYER_TRAINING_3D",
  challenge3d = "ONE_PLAYER_CHALLENGE_3D",
}

return GameModes

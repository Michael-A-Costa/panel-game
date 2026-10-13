local logger = require("common.lib.logger")
local class = require("common.lib.class")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local StadiumLadder = require("common.data.StadiumLadder")
local CpuPlayer = require("client.src.CpuPlayer")
local StadiumProgress = require("client.src.StadiumProgress")
require("client.src.BattleRoom")

local CPU_NAME = "PplCpu"

---@class StadiumOptions
---@field resume boolean? continue the difficulty's saved run instead of starting a new one
---@field progress StadiumProgress? where progress is read and saved; the player's own if nil

-- A run up one difficulty of the 1P Stadium ladder (docs/stadium/STADIUM-SPEC.md §3): the local player against the
-- PPL CPU, one game per stage. A win moves on to the next stage, a draw replays the stage for free, a loss costs a
-- continue, and losing the boss sends the player back to the rival before it. Progress is saved after every match.
---@class Stadium : BattleRoom
---@field ladder StadiumDifficulty
---@field difficulty integer 1 Easy .. 5 Super Hard
---@field difficultyName string
---@field dimension StadiumDimension
---@field stageIndex integer the stage the next match is played on
---@field continues integer continues the run used, unlimited like PPL's
---@field expendedTime integer frames the run played, lost matches included
---@field complete boolean the last stage was beaten
---@field unlockedDifficulty integer? the difficulty this run's clear unlocked, for the recap
---@field cpuPlayer CpuPlayer
---@field opponentCandidates string[] the characters the run's opponents wear, from Stadium.getOpponentCandidates
---@field stadiumProgress StadiumProgress
---@overload fun(mode: GameMode, gameScene: table?, difficulty: integer, options: StadiumOptions): Stadium
local Stadium
-- declared first so the constructor can reach the static functions below
Stadium = class(
---@param self Stadium
---@param mode GameMode
---@param gameScene table? the scene class for matches; BattleRoom requires the mode's own if nil
---@param difficulty integer
---@param options StadiumOptions
function(self, mode, gameScene, difficulty, options)
  self.ladder = StadiumLadder.getDifficulty(difficulty)
  self.difficulty = difficulty
  self.difficultyName = loc(self.ladder.nameKey)
  self.dimension = Stadium.getDimension(mode)
  self.stadiumProgress = options.progress or StadiumProgress.load()
  self.complete = false
  self.unlockedDifficulty = nil

  local startStage = 1
  if options.resume then
    local progress = self.stadiumProgress:get(self.dimension, difficulty)
    startStage = math.min(progress.lastStageBeaten + 1, #self.ladder.stages)
    self.continues = progress.continues
    self.expendedTime = progress.time
  else
    -- like PPL, a new game wipes the difficulty's saved run
    self.stadiumProgress:resetRun(self.dimension, difficulty)
    self.continues = 0
    self.expendedTime = 0
  end

  self:addPlayer(GAME.localPlayer)
  GAME.localPlayer:setStyle(GameModes.Styles.MODERN)

  self.cpuPlayer = CpuPlayer("")
  self:addPlayer(self.cpuPlayer)
  -- fixed for the run, so the rival and the boss stay who they are
  self.opponentCandidates = Stadium.getOpponentCandidates()
  -- only a stage whose opponent wears the player's pick changes with it (see Stadium.getStandIn)
  GAME.localPlayer:connectSignal("characterIdChanged", self, self.refreshOpponentCharacter)
  self:restoreInputConfigurations()
  self:setStage(startStage)
end,
BattleRoom)

---@param difficulty integer
---@param gameModeId GameModeID? ONE_PLAYER_STADIUM or ONE_PLAYER_STADIUM_3D; 2D if nil
---@param options StadiumOptions?
---@return Stadium
function Stadium.create(difficulty, gameModeId, options)
  -- BattleRoom loads Game1pStadium by the mode's gameScene, which keeps that scene free to require Stadium
  return Stadium(GameModes.getPreset(gameModeId or GameModes.IDs.ONE_PLAYER_STADIUM), nil, difficulty, options or {})
end

---@param gameMode GameMode
---@return StadiumDimension
function Stadium.getDimension(gameMode)
  if gameMode.matchRules.stackSetupModifications.cylinder then
    return "3d"
  else
    return "2d"
  end
end

-- a difficulty is open from the start or once the one it names is cleared, separately in 2D and 3D
---@param stadiumProgress StadiumProgress
---@param dimension StadiumDimension
---@param difficulty integer
---@return boolean
function Stadium.isUnlocked(stadiumProgress, dimension, difficulty)
  local unlockedBy = StadiumLadder.getDifficulty(difficulty).unlockedBy
  return unlockedBy == nil or stadiumProgress:get(dimension, unlockedBy).clears > 0
end

---@param stage StadiumStage
---@return string
function Stadium.getStageTitle(stage)
  if stage.titleNumber then
    return loc(stage.titleKey, tostring(stage.titleNumber))
  else
    return loc(stage.titleKey)
  end
end

-- The characters an opponent may wear, in the order of the character select: every visible character except
-- bundles, or the bundles' first characters if that leaves nothing. It doesn't depend on the player's pick, so a run's
-- cast stays the same while the player changes characters.
---@return string[]
function Stadium.getOpponentCandidates()
  local candidates = {}
  for _, characterId in ipairs(visibleCharacters) do
    if not characters[characterId]:isBundle() then
      candidates[#candidates + 1] = characterId
    end
  end

  if #candidates == 0 then
    for _, characterId in ipairs(visibleCharacters) do
      candidates[#candidates + 1] = characters[characterId].subIds[1]
    end
  end

  return candidates
end

-- The rival is the first candidate and the boss the last, so both stay the same character across stages and
-- difficulties; every other stage takes the ones in between in turn.
---@param candidates string[] from Stadium.getOpponentCandidates
---@param stage StadiumStage
---@return string characterId
function Stadium.getOpponentCharacter(candidates, stage)
  assert(#candidates > 0, "Stadium needs at least one character for its opponents")
  local count = #candidates
  if stage.role == "rival" then
    return candidates[1]
  elseif stage.role == "boss" then
    return candidates[count]
  elseif count >= 3 then
    -- stage 1 is the rival's, so stage 2 takes the first of the ones in between
    return candidates[2 + (stage.index - 2) % (count - 2)]
  else
    return candidates[1 + (stage.index - 1) % count]
  end
end

-- The character a stage's opponent wears against this player: its own, unless the player picked that one. Then the
-- first in-between candidate the player didn't pick stands in, the same one every time, so a stand-in is never the
-- rival or the boss while there are others. With a single candidate it is a mirror match.
---@param candidates string[] from Stadium.getOpponentCandidates
---@param characterId string the stage's own opponent, from Stadium.getOpponentCharacter
---@param playerCharacterId string?
---@return string characterId
function Stadium.getStandIn(candidates, characterId, playerCharacterId)
  if characterId ~= playerCharacterId then
    return characterId
  end
  for i = 2, #candidates - 1 do
    if candidates[i] ~= playerCharacterId then
      return candidates[i]
    end
  end
  for _, candidate in ipairs(candidates) do
    if candidate ~= playerCharacterId then
      return candidate
    end
  end
  return characterId
end

-- Every Stadium match runs in Game1pStadium: the PortraitGame BattleRoom gives touch players has no pre-match card,
-- HUD or recap, and would leave a cleared ladder sitting on its last stage.
---@param match ClientMatch
---@return GameBase
function Stadium:createScene(match)
  return self.gameScene({match = match})
end

---@return StadiumStage
function Stadium:getStage()
  return self.ladder.stages[self.stageIndex]
end

-- The opponent wears a character and goes by its name, the way PPL's name bar shows the trainer; the stage title
-- has its own place in the HUD.
function Stadium:refreshOpponentCharacter()
  local cast = Stadium.getOpponentCharacter(self.opponentCandidates, self:getStage())
  local characterId = Stadium.getStandIn(self.opponentCandidates, cast, GAME.localPlayer.settings.characterId)
  if characterId ~= self.cpuPlayer.settings.characterId then
    self.cpuPlayer:setCharacter(characterId)
  end
  self.cpuPlayer.name = characters[characterId].display_name
end

---@param index integer
function Stadium:setStage(index)
  logger.debug("Setting Stadium stage to " .. index)
  self.stageIndex = index
  local stage = self:getStage()

  GAME.localPlayer:setLevel(stage.level)
  GAME.localPlayer:setLevelData(LevelPresets.getModern(stage.level))
  self.cpuPlayer:setCpu(CPU_NAME, stage.cpuOptions)
  self.cpuPlayer:copyLevelFrom(GAME.localPlayer)
  self:refreshOpponentCharacter()
end

-- Moves the run on after a match and saves it.
---@param winners MatchParticipant[] empty for an aborted match
---@param gameLength integer frames
function Stadium:recordStageResult(winners, gameLength)
  self.expendedTime = self.expendedTime + gameLength

  if #winners == 1 and winners[1] ~= self.cpuPlayer then
    if self.stageIndex < #self.ladder.stages then
      self:setStage(self.stageIndex + 1)
    else
      self:completeLadder()
      return
    end
  elseif #winners == 2 then
    -- a draw: PPL replays the stage at no cost
  else
    -- a loss, or an abort, which only the player can cause: the rematch costs a continue
    self.continues = self.continues + 1
    if self:getStage().role == "boss" then
      -- PPL makes the player beat the rival and the boss back to back (STADIUM-SPEC §3.8)
      self:setStage(self.stageIndex - 1)
    end
  end

  self.stadiumProgress:saveRun(self.dimension, self.difficulty, self.stageIndex - 1, self.continues, self.expendedTime)
end

function Stadium:completeLadder()
  self.complete = true
  for difficulty, ladder in ipairs(StadiumLadder.difficulties) do
    if ladder.unlockedBy == self.difficulty and not Stadium.isUnlocked(self.stadiumProgress, self.dimension, difficulty) then
      self.unlockedDifficulty = difficulty
    end
  end
  self.stadiumProgress:saveClear(self.dimension, self.difficulty, self.continues, self.expendedTime)
end

---@param match ClientMatch
function Stadium:onMatchEnded(match)
  local gameLength = 0
  local engine = match.stacks[1].engine
  if engine and engine.stopWatch then
    gameLength = engine.stopWatch
  end

  local winners
  if match.engine.aborted then
    winners = {}
  else
    winners = match:getWinners() or {}
  end

  -- counts the match, credits the win and returns the room to setup
  BattleRoom.onMatchEnded(self, match)
  self:recordStageResult(winners, gameLength)
end

return Stadium

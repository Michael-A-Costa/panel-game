local GameModes = require("common.data.GameModes")
local StadiumLadder = require("common.data.StadiumLadder")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
local GeneratorSource = require("common.engine.GeneratorSource")
local logger = require("common.lib.logger")
local ClientMatch = require("client.src.ClientMatch")
local StadiumProgress = require("client.src.StadiumProgress")
local Stadium = require("client.src.Stadium")
require("common.engine.computerPlayers.PplCpu.PplCpu")

-- Whole Stadium runs played through the room as the game plays them: real matches in ClientMatch with PPL's pace and
-- helper pairs, the stage CPU on one side and a PPL CPU in the player's seat, answering "Continue?" with yes. Checks
-- that the progression holds up in play: stages in order, story screens where PPL has them, continues counted,
-- the boss rule, the ending, the saved run and records. Run by name: testLauncher.lua StadiumPlaythrough

local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- no match of a run should last near this long; one that does is left from the pause menu, which costs a continue
local FRAME_CAP = 60 * 60 * 10

---@class PlaythroughMatch
---@field stage integer
---@field story string?
---@field result "win" | "loss" | "draw" | "abort"
---@field frames integer

-- a character with its assets loaded; the run's own cast may not be, headless
---@return string
local function loadedCharacterId()
  for _, id in ipairs(visibleCharacters) do
    if characters[id].fullyLoaded and not characters[id]:isBundle() then
      return id
    end
  end
  error("the game loads a character on startup")
end

---@param difficulty integer
---@param gameModeId GameModeID
---@param player CpuStrength the preset in the player's seat
---@param seed integer
---@return Stadium stadium
---@return PlaythroughMatch[] matches
---@return StadiumProgress progress
local function playRun(difficulty, gameModeId, player, seed)
  local progress = StadiumProgress()
  progress.saveToFile = function() end
  local stadium = Stadium.create(difficulty, gameModeId, {progress = progress})
  local human = GAME.localPlayer
  if not human.inputConfiguration then
    stadium:claimDeviceForPlayer(human, GAME.input:getAssignableDevices()[1])
  end

  local characterId = loadedCharacterId()
  local selectedCharacterId = human.settings.selectedCharacterId
  human:setCharacter(characterId)

  local matches = {}
  while not stadium.complete do
    assert(#matches < 80, "the run should end")
    local entry = {stage = stadium.stageIndex, story = stadium.cardStoryKey}
    -- the pre-match card shows it once
    stadium.cardStoryKey = nil
    stadium.startDirectly = false
    stadium.panelSource = GeneratorSource(seed * 1000 + #matches, true)
    stadium.cpuPlayer:setCharacter(characterId)

    local match = ClientMatch.createFromBattleRoom(stadium)
    match:connectSignal("matchEnded", stadium, stadium.onMatchEnded)
    match:start()
    local engine = match.stacks[1].engine
    ---@cast engine Stack
    local playerCpu = ComputerPlayer.create("PplCpu", engine,
        {seed = seed + #matches, difficulty = player.difficulty, stage = player.stage})
    local frames = 0
    while not match.ended and frames < FRAME_CAP do
      frames = frames + 1
      if #engine.confirmedInput == engine.clock and not engine:game_ended() then
        engine:receiveConfirmedInput(playerCpu:getInput())
      end
      match:run()
    end
    if not match.ended then
      match:abort()
      entry.result = "abort"
    else
      local winners = match:getWinners()
      if #winners == 2 then
        entry.result = "draw"
      elseif #winners == 1 and winners[1] == human then
        entry.result = "win"
      else
        entry.result = "loss"
      end
    end
    entry.frames = frames
    matches[#matches + 1] = entry
    match:deinit()

    if stadium.awaitingContinue then
      stadium:continueRun()
    end
  end
  human:setCharacter(selectedCharacterId)
  return stadium, matches, progress
end

---@param name string
---@param matches PlaythroughMatch[]
local function log(name, matches)
  local parts = {}
  for _, entry in ipairs(matches) do
    parts[#parts + 1] = entry.stage .. entry.result:sub(1, 1) .. string.format("(%ds)", math.floor(entry.frames / 60))
  end
  logger.info(name .. ": " .. table.concat(parts, " "))
end

-- the stages follow PPL's rules from one match to the next
---@param stadium Stadium
---@param matches PlaythroughMatch[]
local function checkFlow(stadium, matches)
  local continues = 0
  for i, entry in ipairs(matches) do
    local stage = stadium.ladder.stages[entry.stage]
    local nextEntry = matches[i + 1]
    if entry.result == "win" then
      if nextEntry then
        expect(nextEntry.stage, entry.stage + 1, "a win moves on")
        expect(nextEntry.story, stadium.ladder.stages[entry.stage + 1].introKey, "with the next stage's story")
      else
        expect(entry.stage, #stadium.ladder.stages, "the run ends on the last stage")
      end
    else
      if entry.result ~= "draw" then
        continues = continues + 1
      end
      if entry.result ~= "draw" and stage.role == "boss" then
        expect(nextEntry.stage, entry.stage - 1, "losing the boss goes back to the rival")
        expect(nextEntry.story, "stadium_story_rival_returns", "who says so")
      else
        expect(nextEntry.stage, entry.stage, "a loss or draw replays the stage")
        expect(nextEntry.story, nil, "without its story")
      end
    end
  end
  expect(stadium.continues, continues, "every loss cost a continue")
end

local function easyRun()
  local stadium, matches, progress = playRun(StadiumLadder.EASY, GameModes.IDs.ONE_PLAYER_STADIUM,
                                             {difficulty = StadiumLadder.SUPER_HARD, stage = 16}, 1)
  log("Easy 2D", matches)
  expect(matches[1].story, "stadium_story_intro", "the run opens on the intro")
  checkFlow(stadium, matches)
  local saved = progress:get("2d", StadiumLadder.EASY)
  expect(saved.clears, 1, "the clear is saved")
  expect(saved.lastStageBeaten, 0, "and the next game starts over")
  assert(saved.bestChain > 0 or saved.bestCombo > 0, "the run's best chain and combo are kept")
  expect(stadium.revealedDifficulty, nil, "Easy's ending shows no code")
  stadium:shutdown()
end

-- Very Hard in 3D: the elites, the boss straight after the rival, and the code for Super Hard
local function veryHardRun()
  local stadium, matches, progress = playRun(StadiumLadder.VERY_HARD, GameModes.IDs.ONE_PLAYER_STADIUM_3D,
                                             {difficulty = StadiumLadder.SUPER_HARD, stage = 16}, 7)
  log("Very Hard 3D", matches)
  checkFlow(stadium, matches)
  local storiesSeen = {}
  for _, entry in ipairs(matches) do
    if entry.story then
      storiesSeen[entry.story] = true
    end
  end
  for _, key in ipairs({"stadium_story_intro", "stadium_story_elite", "stadium_story_boss"}) do
    assert(storiesSeen[key], key .. " was shown")
  end
  expect(matches[#matches].stage, 16, "the boss is beaten last")
  expect(stadium.revealedDifficulty, StadiumLadder.SUPER_HARD, "the ending shows Super Hard's code")
  expect(progress:get("3d", StadiumLadder.VERY_HARD).clears, 1, "the clear is saved")
  stadium:shutdown()
end

-- the player's seat is weaker than the stage CPU: losses, continues and the boss's rematch rule come up in play
local function losingRun()
  local stadium, matches = playRun(StadiumLadder.SUPER_HARD, GameModes.IDs.ONE_PLAYER_STADIUM,
                                   {difficulty = StadiumLadder.SUPER_HARD, stage = 13}, 3)
  log("Super Hard 2D, a weaker player", matches)
  checkFlow(stadium, matches)
  assert(stadium.continues > 0, "a weaker player needs continues")
  stadium:shutdown()
end

local level = GAME.localPlayer.settings.level
local levelData = GAME.localPlayer.settings.levelData
easyRun()
veryHardRun()
losingRun()
GAME.localPlayer:setLevel(level)
GAME.localPlayer:setLevelData(levelData)

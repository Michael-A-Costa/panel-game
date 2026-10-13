local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local StadiumLadder = require("common.data.StadiumLadder")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
local GeneratorSource = require("common.engine.GeneratorSource")
local ClientMatch = require("client.src.ClientMatch")
local StadiumProgress = require("client.src.StadiumProgress")
local Stadium = require("client.src.Stadium")
local StadiumMenu = require("client.src.scenes.StadiumMenu")
local CharacterSelectStadium = require("client.src.scenes.CharacterSelectStadium")
local Game1pStadium = require("client.src.scenes.Game1pStadium")
local StadiumRecapScene = require("client.src.scenes.StadiumRecapScene")
local input = require("client.src.inputManager")
local DebugSettings = require("client.src.debug.DebugSettings")
local BattleRoom = require("client.src.BattleRoom")

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Stadium progress whose saving is counted instead of writing the player's stadium.json
---@return CountedStadiumProgress
local function createUnsavedProgress()
  ---@class CountedStadiumProgress : StadiumProgress
  ---@field saveCount integer
  local saved = StadiumProgress()
  saved.saveCount = 0
  -- counts instead of writing
  ---@diagnostic disable-next-line: duplicate-set-field
  saved.saveToFile = function(self)
    self.saveCount = self.saveCount + 1
  end
  return saved
end

-- the room changes the local player's level; tests put it back so later tests see the player as they found it
---@param test fun()
local function keepingLocalPlayerLevel(test)
  local player = GAME.localPlayer
  local level = player.settings.level
  test()
  player:setLevel(level)
  player:setLevelData(LevelPresets.getModern(level))
end

local function ladderDataTest()
  local stageCounts = {11, 14, 15, 16, 16}
  local levels = {1, 2, 4, 4, 4}
  expect(StadiumLadder.DIFFICULTY_COUNT, 5, "Stadium has five difficulties")
  for difficulty, ladder in ipairs(StadiumLadder.difficulties) do
    local name = "difficulty " .. difficulty
    expect(ladder.index, difficulty, name .. " knows its index")
    expect(#ladder.stages, stageCounts[difficulty], name .. " has PPL's stage count")
    expect(#ladder.stages, ComputerPlayer.STAGE_COUNTS[difficulty], name .. " has a CPU preset for every stage")
    expect(ladder.level, levels[difficulty], name .. " plays PPL's VS level")
    assert(loc(ladder.nameKey):sub(1, 1) ~= "#", name .. " has a localized name")
    for index, stage in ipairs(ladder.stages) do
      local stageName = name .. " stage " .. index
      expect(stage.index, index, stageName .. " knows its index")
      expect(stage.level, ladder.level, stageName .. " plays the difficulty's level")
      expect(stage.cpuOptions.difficulty, difficulty, stageName .. " uses its difficulty's CPU table")
      expect(stage.cpuOptions.stage, index, stageName .. " uses its own row of it")
      ComputerPlayer.validateOptions({seed = 1, difficulty = stage.cpuOptions.difficulty, stage = stage.cpuOptions.stage})
      local role = nil
      if index == 1 or index == 15 then
        role = "rival"
      elseif index == 16 then
        role = "boss"
      end
      expect(stage.role, role, stageName .. "'s role")
      assert(Stadium.getStageTitle(stage):sub(1, 1) ~= "#", stageName .. " has a localized title")
    end
  end
  expect(StadiumLadder.getDifficulty(1).unlockedBy, nil, "Easy is open")
  expect(StadiumLadder.getDifficulty(3).unlockedBy, nil, "Hard is open")
  expect(StadiumLadder.getDifficulty(4).unlockedBy, StadiumLadder.HARD, "Hard unlocks Very Hard")
  expect(StadiumLadder.getDifficulty(5).unlockedBy, StadiumLadder.VERY_HARD, "Very Hard unlocks Super Hard")
  expect(Stadium.getStageTitle(StadiumLadder.getDifficulty(2).stages[4]), "Gym 3", "titles fill in their number")
end

local function opponentCharacterTest()
  local candidates = {"a", "b", "c", "d", "e"}
  local stages = StadiumLadder.getDifficulty(StadiumLadder.SUPER_HARD).stages
  local rival = Stadium.getOpponentCharacter(candidates, stages[1])
  local boss = Stadium.getOpponentCharacter(candidates, stages[16])
  expect(Stadium.getOpponentCharacter(candidates, stages[15]), rival, "the rival comes back before the boss")
  assert(boss ~= rival, "the boss is someone else")
  for index = 2, 14 do
    local characterId = Stadium.getOpponentCharacter(candidates, stages[index])
    assert(characterId ~= rival and characterId ~= boss, "stage " .. index .. " is neither rival nor boss")
  end
  local easyRival = Stadium.getOpponentCharacter(candidates, StadiumLadder.getDifficulty(1).stages[1])
  expect(easyRival, rival, "every difficulty meets the same rival")

  expect(Stadium.getOpponentCharacter({"a", "b"}, stages[16]), "b", "two characters still make a separate boss")
  expect(Stadium.getOpponentCharacter({"a"}, stages[7]), "a", "one character plays everyone")

  -- only a slot that wears the player's pick changes, always to the same stand-in
  expect(Stadium.getStandIn(candidates, "c", "a"), "c", "no clash keeps the stage's own")
  expect(Stadium.getStandIn(candidates, "a", "a"), "b", "the first in-between candidate stands in for the rival")
  expect(Stadium.getStandIn(candidates, "e", "e"), "b", "and for the boss, so it is never the rival")
  expect(Stadium.getStandIn(candidates, "b", "b"), "c", "a stage the stand-in plays itself gets the next one")
  expect(Stadium.getStandIn({"a", "b"}, "b", "b"), "a", "two characters leave no choice")
  expect(Stadium.getStandIn({"a"}, "a", "a"), "a", "one character is a mirror match")

  assert(#Stadium.getOpponentCandidates() > 0, "there is always someone to play")
end

-- the cast of a run stays put while the player changes characters, e.g. a random pick re-rolled after a match
local function castStaysForTheRunTest()
  local candidates = Stadium.getOpponentCandidates()
  if #candidates < 4 then
    return
  end
  local human = GAME.localPlayer
  local selectedCharacterId = human.settings.selectedCharacterId
  human:setCharacter(candidates[2])
  local stadium = Stadium.create(StadiumLadder.VERY_HARD, GameModes.IDs.ONE_PLAYER_STADIUM, {progress = createUnsavedProgress()})
  local cpu = stadium.cpuPlayer
  expect(cpu.settings.characterId, candidates[1], "the rival")

  stadium:setStage(16)
  local boss = cpu.settings.characterId
  human:setCharacter(candidates[3])
  expect(cpu.settings.characterId, boss, "the boss stays when the player changes characters")

  stadium:setStage(15)
  expect(cpu.settings.characterId, candidates[1], "the rival comes back as the same character")
  human:setCharacter(candidates[1])
  expect(cpu.settings.characterId, candidates[2], "a clash with the player's pick gets the stand-in")
  stadium:setStage(1)
  expect(cpu.settings.characterId, candidates[2], "the same stand-in on every rival stage")
  stadium:setStage(16)
  expect(cpu.settings.characterId, boss, "the boss isn't touched by it")

  stadium:shutdown()
  human:setCharacter(selectedCharacterId)
end

-- the run of one difficulty: win, draw, loss and abort, then up to the end of a ladder without a boss
local function stageFlowTest()
  local saved = createUnsavedProgress()
  local stadium = Stadium.create(StadiumLadder.NORMAL, GameModes.IDs.ONE_PLAYER_STADIUM, {progress = saved})
  local human = GAME.localPlayer
  local cpu = stadium.cpuPlayer

  expect(stadium.dimension, "2d", "the 2D mode")
  expect(#stadium.players, 2, "the room holds the player and the CPU")
  expect(stadium.players[1], human, "the local player plays")
  assert(cpu.isCpu and cpu.isLocal and not cpu.human, "the opponent is a local CPU")
  expect(cpu.settings.cpuName, "PplCpu", "the PPL CPU plays")
  expect(cpu.settings.cpuOptions.difficulty, StadiumLadder.NORMAL, "on the difficulty's table")
  expect(cpu.settings.cpuOptions.stage, 1, "at the first stage")
  expect(human.settings.level, 2, "Normal plays level 2")
  expect(cpu.settings.level, 2, "on both sides")
  expect(cpu.settings.levelData.startingSpeed, LevelPresets.getModern(2).startingSpeed, "with level 2's data")
  expect(cpu.name, characters[cpu.settings.characterId].display_name, "the CPU goes by its character's name")
  expect(stadium.stageIndex, 1, "a new game starts at stage 1")

  stadium:recordStageResult({human}, 600)
  expect(stadium.stageIndex, 2, "a win moves on")
  expect(cpu.settings.cpuOptions.stage, 2, "to the next CPU")
  local progress = saved:get("2d", StadiumLadder.NORMAL)
  expect(progress.lastStageBeaten, 1, "the win is saved")
  expect(progress.time, 600, "with the time played")

  stadium:recordStageResult({human, cpu}, 300)
  expect(stadium.stageIndex, 2, "a draw replays the stage")
  expect(stadium.continues, 0, "for free")

  stadium:recordStageResult({cpu}, 300)
  expect(stadium.stageIndex, 2, "a loss replays the stage")
  expect(stadium.continues, 1, "for a continue")
  expect(progress.continues, 1, "which is saved")

  stadium:recordStageResult({}, 0)
  expect(stadium.continues, 2, "leaving a match costs a continue too")
  expect(progress.time, 1200, "every match's time counts")

  local saves = saved.saveCount
  while not stadium.complete do
    stadium:recordStageResult({human}, 60)
  end
  expect(stadium.stageIndex, 14, "Normal ends after stage 14")
  expect(saved.saveCount - saves, 13, "every match is saved")
  expect(progress.clears, 1, "the clear is recorded")
  expect(progress.bestContinues, 2, "with its continues")
  expect(progress.lastStageBeaten, 0, "and the next game starts over")
  expect(stadium.unlockedDifficulty, nil, "Normal unlocks nothing")
  stadium:shutdown()
end

-- the boss: losing it goes back to the rival, and both have to be beaten back to back; clearing unlocks the next
local function bossAndUnlockTest()
  local saved = createUnsavedProgress()
  local veryHard = StadiumLadder.VERY_HARD
  assert(not Stadium.isUnlocked(saved, "3d", veryHard), "Very Hard starts locked")
  saved:saveClear("3d", StadiumLadder.HARD, 0, 0)
  assert(Stadium.isUnlocked(saved, "3d", veryHard), "clearing Hard unlocks Very Hard")
  assert(not Stadium.isUnlocked(saved, "2d", veryHard), "in the dimension it was cleared in")
  assert(not Stadium.isUnlocked(saved, "3d", StadiumLadder.SUPER_HARD), "Super Hard needs Very Hard")

  -- a saved run that beat stage 14
  saved:saveRun("3d", veryHard, 14, 3, 1000)
  local stadium = Stadium.create(veryHard, GameModes.IDs.ONE_PLAYER_STADIUM_3D, {resume = true, progress = saved})
  local human = GAME.localPlayer
  local cpu = stadium.cpuPlayer
  expect(stadium.dimension, "3d", "the 3D mode")
  assert(stadium.mode.matchRules.stackSetupModifications.cylinder, "both stacks are 3D")
  expect(stadium.stageIndex, 15, "resume starts after the last beaten stage")
  expect(stadium.continues, 3, "with the run's continues")
  expect(stadium.expendedTime, 1000, "and time")
  expect(human.settings.level, 4, "Very Hard plays level 4")
  local rivalCharacter = cpu.settings.characterId

  stadium:recordStageResult({human}, 100)
  expect(stadium.stageIndex, 16, "the rival leads to the boss")
  expect(stadium:getStage().role, "boss", "stage 16 is the boss")
  local candidates = Stadium.getOpponentCandidates()
  local bossCharacter = Stadium.getOpponentCharacter(candidates, stadium:getStage())
  expect(cpu.settings.characterId, Stadium.getStandIn(candidates, bossCharacter, human.settings.characterId),
         "the boss's character")
  -- with two characters, one of them the player's, the rival's stand-in can only be the boss
  if #candidates > 2 then
    assert(cpu.settings.characterId ~= rivalCharacter, "the boss is not the rival")
  end
  expect(cpu.name, characters[cpu.settings.characterId].display_name, "the name bar follows the character")

  stadium:recordStageResult({cpu}, 100)
  expect(stadium.stageIndex, 15, "losing the boss goes back to the rival")
  expect(stadium.continues, 4, "for a continue")
  expect(cpu.settings.characterId, rivalCharacter, "the same rival")
  expect(saved:get("3d", veryHard).lastStageBeaten, 14, "the rival has to be beaten again")

  stadium:recordStageResult({human}, 100)
  stadium:recordStageResult({human, cpu}, 100)
  expect(stadium.stageIndex, 16, "a draw with the boss replays the boss")
  expect(stadium.continues, 4, "for free")

  stadium:recordStageResult({human}, 100)
  assert(stadium.complete, "beating the boss finishes Very Hard")
  expect(stadium.unlockedDifficulty, StadiumLadder.SUPER_HARD, "and unlocks Super Hard")
  assert(Stadium.isUnlocked(saved, "3d", StadiumLadder.SUPER_HARD), "for good")
  expect(saved:get("3d", veryHard).bestTime, 1500, "the clear keeps the whole run's time")

  local recap = StadiumRecapScene({stadium = stadium})
  assert(recap.unlockText:find(loc("stadium_difficulty_5"), 1, true), "the recap names the unlocked difficulty")
  stadium:shutdown()
end

local function newGameWipesTheRunTest()
  local saved = createUnsavedProgress()
  saved:saveRun("2d", StadiumLadder.EASY, 5, 2, 100)
  local stadium = Stadium.create(StadiumLadder.EASY, GameModes.IDs.ONE_PLAYER_STADIUM, {progress = saved})
  expect(stadium.stageIndex, 1, "a new game starts at stage 1")
  expect(stadium.continues, 0, "without continues")
  expect(saved:get("2d", StadiumLadder.EASY).lastStageBeaten, 0, "and forgets the saved run")
  stadium:shutdown()
end

-- a character with its assets loaded; loading one here would also load everything earlier tests queued
---@return string?
local function loadedCharacterId()
  for _, id in ipairs(visibleCharacters) do
    if characters[id].fullyLoaded and not characters[id]:isBundle() then
      return id
    end
  end
end

-- the menu, the character select and the game scene build without a window or a real save
local function scenesTest()
  local saved = createUnsavedProgress()
  local menu = StadiumMenu({gameModeId = GameModes.IDs.ONE_PLAYER_STADIUM_3D, progress = saved})
  expect(menu.gameModeId, GameModes.IDs.ONE_PLAYER_STADIUM_3D, "the 3D menu item opens the 3D mode")
  expect(menu.dimension, "3d", "and reads 3D progress")
  assert(not menu:isUnlocked(StadiumLadder.VERY_HARD), "Very Hard is locked")
  menu.difficultyStepper:setState(StadiumLadder.EASY)
  expect(menu.resumeItem, nil, "nothing to resume")
  saved:saveRun("3d", StadiumLadder.EASY, 3, 0, 0)
  menu:refresh()
  assert(menu.resumeItem, "a saved run can be resumed")
  expect(menu.menu.menuItems[2], menu.resumeItem, "right below the difficulty")
  menu.difficultyStepper:setState(StadiumLadder.VERY_HARD)
  expect(menu.resumeItem, nil, "a locked difficulty has no run")

  local stadium = Stadium.create(StadiumLadder.EASY, GameModes.IDs.ONE_PLAYER_STADIUM_3D, {resume = true, progress = saved})
  GAME.battleRoom = stadium
  local characterSelect = CharacterSelectStadium({battleRoom = stadium})
  local info = characterSelect.ui.stadiumInfo.text
  assert(info:find(Stadium.getStageTitle(stadium:getStage()), 1, true), "the select names the next stage: " .. info)

  -- the HUD draws both characters' faces, so both wear one that is loaded
  local human = GAME.localPlayer
  local selectedCharacterId = human.settings.selectedCharacterId
  local characterId = loadedCharacterId()
  assert(characterId, "the game loads a character on startup")
  human:setCharacter(characterId)
  stadium.cpuPlayer:setCharacter(characterId)
  local match = ClientMatch.createFromBattleRoom(stadium)
  match:start()
  -- without load, which would pull in the stage's and characters' music and art
  local game = Game1pStadium({match = match})
  expect(game.stadiumStage.index, 4, "the game shows the stage it plays")
  expect(game.stageLabel, loc("stadium_stage", "4", "11"), "out of the difficulty's stages")
  -- the HUD reads the room, so drawing it once catches a field it can't find
  game:drawHUD()

  -- the match waits on its first frame behind the pre-match card, which Swap or Start closes early
  assert(game.cardVisible, "the match opens on the pre-match card")
  game:drawCard()
  game:update(1)
  assert(game.cardVisible, "the card stays up without a press")
  expect(match.stacks[1].engine.clock, 0, "and the match waits")
  input.isDown["MenuSelect"] = true
  game:update(0.1)
  input.isDown["MenuSelect"] = nil
  assert(not game.cardVisible, "a press closes the card")
  local unattended = Game1pStadium({match = match})
  unattended:update(3)
  assert(not unattended.cardVisible, "the card closes by itself")

  -- a touch player gets the Stadium scene as well, where BattleRoom would hand out PortraitGame
  local inputMethod = human.settings.inputMethod
  local simulateMobileOS = DebugSettings.simulateMobileOS
  human:setInputMethod("touch")
  ---@diagnostic disable-next-line: duplicate-set-field
  DebugSettings.simulateMobileOS = function()
    return true
  end
  expect(BattleRoom.createScene(stadium, match).name, "PortraitGame", "a plain room's touch scene")
  expect(stadium:createScene(match).name, "Game1pStadium", "Stadium keeps its own scene")
  DebugSettings.simulateMobileOS = simulateMobileOS
  human:setInputMethod(inputMethod)

  -- a win names the next stage
  match.getWinners = function()
    return {human}
  end
  game:customGameOverSetup()
  expect(game.text, loc("stadium_stage_beaten", "Gym 3", "Gym 4"), "the result line after a win")
  match:deinit()
  stadium:shutdown()
  human:setCharacter(selectedCharacterId)
end

-- a whole match of the room, the PPL CPU against an idle player, through ClientMatch as the game runs it
---@param gameModeId GameModeID
local function realMatchTest(gameModeId)
  local saved = createUnsavedProgress()
  local stadium = Stadium.create(StadiumLadder.HARD, gameModeId, {progress = saved})
  stadium:setStage(14)
  -- a fixed seed instead of the room's random one keeps the game, and so the test, the same every run
  stadium.panelSource = GeneratorSource(4321, true)
  local human = GAME.localPlayer
  local cpu = stadium.cpuPlayer
  local characterId = loadedCharacterId()
  assert(characterId, "the game loads a character on startup")
  cpu:setCharacter(characterId)
  if not human.inputConfiguration then
    stadium:claimDeviceForPlayer(human, GAME.input:getAssignableDevices()[1])
  end

  local match = ClientMatch.createFromBattleRoom(stadium)
  match:connectSignal("matchEnded", stadium, stadium.onMatchEnded)
  match:start()
  local frames = 0
  while not match.ended and frames < 60 * 60 * 4 do
    frames = frames + 1
    match:run()
  end
  local ended = match.ended
  if not ended then
    match:abort()
  end

  local engine = match.stacks[2].engine
  ---@cast engine Stack
  expect(engine.TYPE, "Stack", "the CPU plays a regular stack")
  assert(engine.panels_cleared > 0, "the PPL CPU cleared panels")
  local replay = match.replay
  expect(replay.metadata.gameModeName, stadium.mode.name, "the replay names the mode")
  local metadata = replay.metadata.stacks[2]
  ---@cast metadata StackMetadata
  expect(metadata.cpu.name, "PplCpu", "the replay records the CPU")
  expect(metadata.cpu.options.difficulty, StadiumLadder.HARD, "with its difficulty")
  expect(metadata.cpu.options.stage, 14, "and stage")
  local folder = gameModeId == GameModes.IDs.ONE_PLAYER_STADIUM_3D and "/Stadium 3D" or "/Stadium"
  local path = replay:generatePath("/")
  assert(path:sub(-#folder) == folder, "the replay gets its own folder, not " .. path)

  expect(stadium.matchesPlayed, 1, "the room counted the match")
  if ended and #match:getWinners() == 1 and match:getWinners()[1] == human then
    expect(stadium.stageIndex, 15, "a win moves on")
  else
    expect(stadium.continues, 1, "a loss costs a continue")
    expect(stadium.stageIndex, 14, "and replays the stage")
  end

  match:deinit()
  stadium:shutdown()
end

ladderDataTest()
opponentCharacterTest()
keepingLocalPlayerLevel(castStaysForTheRunTest)
keepingLocalPlayerLevel(stageFlowTest)
keepingLocalPlayerLevel(bossAndUnlockTest)
keepingLocalPlayerLevel(newGameWipesTheRunTest)
keepingLocalPlayerLevel(scenesTest)
keepingLocalPlayerLevel(function()
  realMatchTest(GameModes.IDs.ONE_PLAYER_STADIUM)
end)
keepingLocalPlayerLevel(function()
  realMatchTest(GameModes.IDs.ONE_PLAYER_STADIUM_3D)
end)

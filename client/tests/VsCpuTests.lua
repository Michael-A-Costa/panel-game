local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
local ClientMatch = require("client.src.ClientMatch")
local CpuPlayer = require("client.src.CpuPlayer")
local VsCpuMenu = require("client.src.scenes.VsCpuMenu")
local CharacterSelectVsCpu = require("client.src.scenes.CharacterSelectVsCpu")
local BattleRoom = require("client.src.BattleRoom")
local GeneratorSource = require("common.engine.GeneratorSource")

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- the main menu's path: level menu, room, character select; the CPU follows the human's level
local function menuPathTest()
  local menu = VsCpuMenu({gameModeId = GameModes.IDs.ONE_PLAYER_VS_CPU_3D})
  expect(menu.gameModeId, GameModes.IDs.ONE_PLAYER_VS_CPU_3D, "the 3D menu item opens the 3D mode")

  local human = GAME.localPlayer
  local originalLevel = human.settings.level
  local battleRoom = VsCpuMenu.createBattleRoom(GameModes.IDs.ONE_PLAYER_VS_CPU_3D, 7)
  assert(battleRoom, "the room is created")
  expect(#battleRoom.players, 2, "the room holds the player and the CPU")
  expect(battleRoom.players[1], human, "the local player plays")
  local cpu = battleRoom.players[2]
  ---@cast cpu CpuPlayer
  assert(cpu.isCpu and cpu.isLocal and not cpu.human, "the second player is a local CPU")
  expect(cpu.settings.cpuName, "SimpleCpu", "the placeholder CPU plays until the PPL CPU lands")
  expect(cpu.settings.cpuOptions.level, 7, "the CPU plays at the picked level")
  expect(cpu.settings.wantsReady, true, "the CPU is always ready")
  assert(battleRoom.mode.matchRules.stackSetupModifications.cylinder, "both stacks are 3D")

  local characterSelect = CharacterSelectVsCpu({battleRoom = battleRoom})
  assert(characterSelect.ui.levelSelection, "the human picks the level on the character select")
  local newLevel = originalLevel % LevelPresets.modernPresetCount + 1
  human:setLevel(newLevel)
  human:setLevelData(LevelPresets.getModern(newLevel))
  expect(cpu.settings.level, newLevel, "the CPU follows the human's level")
  expect(cpu.settings.levelData.startingSpeed, human.settings.levelData.startingSpeed, "with the same level data")
  assert(not rawequal(cpu.settings.levelData, human.settings.levelData), "in a copy of its own")

  human:setLevel(originalLevel)
  human:setLevelData(LevelPresets.getModern(originalLevel))
  battleRoom:shutdown()
end

-- a character with its assets loaded; the room would wait for any other to load, and loading one here would also
-- load everything earlier tests queued
---@return string?
local function loadedCharacterId()
  for _, id in ipairs(visibleCharacters) do
    if characters[id].fullyLoaded and not characters[id]:isBundle() then
      return id
    end
  end
end

-- a whole client match with CPUs on both sides: ClientMatch builds engine stacks for them, feeds their inputs and
-- records them in the replay
---@param gameModeId GameModeID
local function clientMatchTest(gameModeId)
  local characterId = loadedCharacterId()
  assert(characterId, "the game loads a character on startup")
  local battleRoom = BattleRoom(GameModes.getPreset(gameModeId))
  -- a fixed seed instead of the room's random one keeps the game, and so the test, the same every run
  battleRoom.panelSource = GeneratorSource(1234, true)
  for i, level in ipairs({5, 9}) do
    local cpu = CpuPlayer("cpu " .. i)
    cpu:setCpu("SimpleCpu", {level = level})
    cpu:setCharacter(characterId)
    cpu:setLevel(6)
    cpu:setLevelData(LevelPresets.getModern(6))
    battleRoom:addPlayer(cpu)
  end

  local match = ClientMatch.createFromBattleRoom(battleRoom)
  match:start()
  local frames = 0
  while not match.ended do
    frames = frames + 1
    assert(frames <= 60 * 60 * 5, "the match ends")
    match:run()
  end

  local replay = match.replay
  expect(replay.metadata.gameModeName, battleRoom.mode.name, "the replay names the mode")
  assert(replay.metadata.winnerIndex, "one CPU won")
  for i, player in ipairs(battleRoom.players) do
    local engine = match.stacks[i].engine
    ---@cast engine Stack
    assert(engine.TYPE == "Stack", "a CPU plays a regular stack")
    assert(engine.panels_cleared > 0, "CPU " .. i .. " played")
    local metadata = replay.metadata.stacks[i]
    ---@cast metadata StackMetadata
    expect(metadata.name, player.name, "the replay names the CPU")
    expect(metadata.cpu.name, "SimpleCpu", "the replay records which CPU played")
    expect(metadata.cpu.options.level, player.settings.cpuOptions.level, "and at which level")
    expect(metadata.cpu.options.seed, ComputerPlayer.deriveSeed(match.panelSource.seed, i), "with the match's seed")
  end
  local path = replay:generatePath("/")
  assert(path:find(gameModeId == GameModes.IDs.ONE_PLAYER_VS_CPU_3D and "Vs CPU 3D" or "Vs CPU", 1, true),
         "the replay gets its own folder, not " .. path)

  match:deinit()
  battleRoom:shutdown()
end

menuPathTest()
clientMatchTest(GameModes.IDs.ONE_PLAYER_VS_CPU)
clientMatchTest(GameModes.IDs.ONE_PLAYER_VS_CPU_3D)

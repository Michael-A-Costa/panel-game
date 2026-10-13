local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local ClientMatch = require("client.src.ClientMatch")
local ChallengeMode = require("client.src.ChallengeMode")
local ChallengeModePlayer = require("client.src.ChallengeModePlayer")
local Player = require("client.src.Player")

local COUNTDOWN_FRAMES = consts.COUNTDOWN_START + consts.COUNTDOWN_LENGTH

-- the same scripted player as CylinderReplayTests: busy, but deterministic
---@param frames integer
---@param seed integer
---@param buttons ("left" | "right" | "up" | "down" | "swap" | "raise")[]
---@return string
local function scriptedInputs(frames, seed, buttons)
  local rng = love.math.newRandomGenerator(seed)
  local inputs = {}
  for i = 1, frames do
    local button = buttons[rng:random(1, #buttons + 4)]
    inputs[i] = button and KeyDataEncoding[button] or KeyDataEncoding.idle
  end
  return table.concat(inputs)
end

-- a Challenge 3D match against one stage's challenger, set up by ClientMatch like the game does
---@param difficulty integer
---@param stageIndex integer
---@return ClientMatch
local function createChallengeMatch(difficulty, stageIndex)
  local stage = ChallengeMode:createStages(difficulty)[stageIndex]

  local player = Player.createLocalPlayerFromConfig()
  -- a local stack would read the input devices instead of the scripted inputs
  player.isLocal = false
  player.playerNumber = 1
  player:setStyle(GameModes.Styles.MODERN)
  player:setLevelData(LevelPresets.getModern(stage.playerLevel))

  local challenger = ChallengeModePlayer(2)
  challenger.settings.difficulty = difficulty
  challenger.settings.level = stageIndex
  challenger:setAttackEngineSettings(stage.attackSettings)
  challenger.settings.healthSettings = stage.healthSettings
  challenger:setCharacterForStage(stageIndex)

  local gameMode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_CHALLENGE_3D)
  local match = ClientMatch.createFromGameMode({player, challenger}, gameMode, GeneratorSource(31, true))
  for _, stack in ipairs(match.stacks) do
    -- the test runner never loads the characters' images that card and pop effects use
    stack.canvas = nil
  end
  match:start()
  for _, stack in ipairs(match.engine.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  return match
end

-- challenge stages with a scripted player that between them send every shape the tower reshapes garbage into:
-- combos of 4 to 7 keep their 3 to 6 columns, chains of 2 and 3 become 6 and 12 wide and longer ones full rings
local function challengeOnTheTowerTest()
  local widthsSeen = {}
  local receivedByChallengers = 0

  for _, run in ipairs({{difficulty = 8, stage = 1, seed = 5}, {difficulty = 4, stage = 11, seed = 5},
                        {difficulty = 5, stage = 1, seed = 6}, {difficulty = 5, stage = 7, seed = 5}}) do
    local match = createChallengeMatch(run.difficulty, run.stage)
    local tower = match.engine.stacks[1]
    local challenger = match.engine.stacks[2]
    ---@cast tower Stack
    ---@cast challenger SimulatedStack
    assert(tower.cylinder and tower.width == consts.CYLINDER_WIDTH, "the player plays on the tower")
    assert(challenger.TYPE == "SimulatedStack" and challenger.healthEngine, "the challenger stays an attack engine")

    local healthEngine = challenger.healthEngine
    local receiveGarbage = healthEngine.receiveGarbage
    ---@diagnostic disable-next-line: duplicate-set-field
    healthEngine.receiveGarbage = function(self, frame, garbage)
      receivedByChallengers = receivedByChallengers + 1
      receiveGarbage(self, frame, garbage)
    end

    local inputs = string.rep(KeyDataEncoding.idle, COUNTDOWN_FRAMES)
                   .. scriptedInputs(3000, run.seed, {"left", "right", "left", "up", "down", "swap"})
    tower:receiveConfirmedInput(inputs)

    while not match.engine:hasEnded() do
      assert(tower.clock < inputs:len(), "the scripted player should top out before its inputs run out")
      match:run()
      for row = 1, #tower.panels do
        for column = 1, tower.width do
          local panel = tower.panels[row][column]
          if panel.isGarbage then
            widthsSeen[panel.width] = true
          end
        end
      end
    end
    match:deinit()
  end

  for _, width in ipairs({3, 4, 5, 6, 12, 18}) do
    assert(widthsSeen[width], "a " .. width .. " wide block should have landed on the tower")
  end
  assert(receivedByChallengers > 0, "the tower's attacks should reach the challengers")
end

challengeOnTheTowerTest()

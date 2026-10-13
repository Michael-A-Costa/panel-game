local Scene = require("client.src.scenes.Scene")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local GameModes = require("common.data.GameModes")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
local CpuPlayer = require("client.src.CpuPlayer")
local GameBase = require("client.src.scenes.GameBase")
local CharacterSelectVsCpu = require("client.src.scenes.CharacterSelectVsCpu")
require("client.src.BattleRoom")

-- Scene picking the CPU's level for a 1P vs CPU game, 2D or 3D, before the character select
---@class VsCpuMenu : Scene
---@field gameModeId GameModeID
---@field menu Menu
local VsCpuMenu = class(
  function(self, sceneParams)
    self.backgroundImg = themes[config.theme].images.bg_main
    self.keepMusic = true
    self.gameModeId = sceneParams and sceneParams.gameModeId or GameModes.IDs.ONE_PLAYER_VS_CPU
    self:load(sceneParams)
  end,
  Scene
)

VsCpuMenu.name = "VsCpuMenu"

-- the level picked last, offered again for the next game
local lastCpuLevel = 1

-- A room with the local player against a CpuPlayer on the same level.
---@param gameModeId GameModeID
---@param cpuLevel integer 1-10 on the DemoCPU scale
---@return BattleRoom?
function VsCpuMenu.createBattleRoom(gameModeId, cpuLevel)
  local battleRoom = BattleRoom.createLocalFromGameMode(GameModes.getPreset(gameModeId), GameBase)
  if battleRoom then
    local cpuPlayer = CpuPlayer(loc("cpu_name", cpuLevel))
    cpuPlayer:setCpu("SimpleCpu", {level = cpuLevel})
    cpuPlayer:copyLevelFrom(GAME.localPlayer)
    battleRoom:addPlayer(cpuPlayer)
  end
  return battleRoom
end

local function exitMenu()
  GAME.theme:playCancelSfx()
  GAME.navigationStack:pop()
end

---@param cpuLevel integer
function VsCpuMenu:goToCharacterSelect(cpuLevel)
  GAME.theme:playValidationSfx()
  lastCpuLevel = cpuLevel
  GAME.battleRoom = VsCpuMenu.createBattleRoom(self.gameModeId, cpuLevel)
  if GAME.battleRoom then
    GAME.navigationStack:push(CharacterSelectVsCpu({battleRoom = GAME.battleRoom}))
  end
end

function VsCpuMenu:load(sceneParams)
  local levelLabels = {}
  local levels = {}
  for level = 1, ComputerPlayer.LEVEL_COUNT do
    levelLabels[level] = ui.Label({text = tostring(level), translate = false})
    levels[level] = level
  end

  local levelStepper = ui.Stepper({
    labels = levelLabels,
    values = levels,
    selectedIndex = lastCpuLevel,
    width = 70,
    height = 25,
    onChange = function(value)
      GAME.theme:playMoveSfx()
    end
  })

  local menuItems = {
    ui.MenuItem.createStepperMenuItem("cpu_level", nil, nil, levelStepper),
    ui.MenuItem.createButtonMenuItem("go_", nil, nil, function()
      self:goToCharacterSelect(levelStepper.value)
    end),
    ui.MenuItem.createButtonMenuItem("back", nil, nil, exitMenu)
  }

  self.menu = ui.Menu.createCenteredMenu(menuItems)
  self.uiRoot:addChild(self.menu)
end

function VsCpuMenu:updateSelf(dt)
  self.backgroundImg:update(dt)
  self.menu:receiveInputs()
  self.uiRoot:update(dt)
end

function VsCpuMenu:draw()
  self.backgroundImg:draw()
  self.uiRoot:draw()
end

return VsCpuMenu

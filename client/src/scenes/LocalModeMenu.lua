local Scene = require("client.src.scenes.Scene")
local class = require("common.lib.class")

-- Base of the small menus that set up a local mode against the CPU (1P vs CPU) before its character
-- select: the main menu's background and music, a game mode from the scene parameters, a centered menu and back.
-- Subclasses set DEFAULT_GAME_MODE_ID, build self.menu in load and call it from their constructor.
---@class LocalModeMenu : Scene
---@field gameModeId GameModeID the mode the menu sets up, 2D or 3D
---@field menu Menu
---@field backgroundImg UpdatingImage
---@field DEFAULT_GAME_MODE_ID GameModeID used when the scene parameters name none
local LocalModeMenu = class(
---@param self LocalModeMenu
function(self, sceneParams)
  self.backgroundImg = themes[config.theme].images.bg_main
  self.keepMusic = true
  self.gameModeId = sceneParams and sceneParams.gameModeId or self.DEFAULT_GAME_MODE_ID
end,
Scene)

LocalModeMenu.name = "LocalModeMenu"

function LocalModeMenu.exitMenu()
  GAME.theme:playCancelSfx()
  GAME.navigationStack:pop()
end

function LocalModeMenu:updateSelf(dt)
  self.backgroundImg:update(dt)
  self.menu:receiveInputs()
  self.uiRoot:update(dt)
end

function LocalModeMenu:draw()
  self.backgroundImg:draw()
  self.uiRoot:draw()
end

return LocalModeMenu

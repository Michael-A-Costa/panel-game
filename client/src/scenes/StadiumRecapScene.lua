local consts = require("common.engine.consts")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Scene = require("client.src.scenes.Scene")
local class = require("common.lib.class")
local input = require("client.src.inputManager")
local tableUtils = require("common.lib.tableUtils")
local StadiumLadder = require("common.data.StadiumLadder")

-- Shown once a Stadium run beat its last stage: the difficulty, the continues and time it took, and what it unlocked
---@class StadiumRecapScene : Scene
---@field stadium Stadium
---@field unlockText string? names the difficulty the clear unlocked
---@field recapStartTime number
---@field minDisplayTime number seconds before a key press leaves the scene
---@field backgroundImg UpdatingImage
local StadiumRecapScene = class(
---@param self StadiumRecapScene
function(self, sceneParams)
  self.backgroundImg = GAME.theme.images.bg_main
  self.stadium = sceneParams.stadium
  if self.stadium.unlockedDifficulty then
    local unlocked = StadiumLadder.getDifficulty(self.stadium.unlockedDifficulty)
    self.unlockText = loc("stadium_unlocked", loc(unlocked.nameKey))
  end
  self.recapStartTime = love.timer.getTime()
  self.minDisplayTime = 2
end,
Scene)

StadiumRecapScene.name = "StadiumRecapScene"

function StadiumRecapScene:updateSelf(dt)
  self.backgroundImg:update(dt)
  local displayTime = love.timer.getTime() - self.recapStartTime
  local keyPressed = (tableUtils.length(input.isDown) > 0) or (tableUtils.length(input.mouse.isDown) > 0)

  if displayTime >= self.minDisplayTime and keyPressed then
    GAME.theme:playValidationSfx()
    local stadium = self.stadium
    -- back to the difficulty menu, where an unlocked difficulty can be picked right away
    GAME.navigationStack:popToName("StadiumMenu", nil, function()
      stadium:shutdown()
    end)
  end
end

function StadiumRecapScene:drawSelf()
  self.backgroundImg:draw()

  local width = consts.CANVAS_WIDTH
  local drawY = 40
  GraphicsUtil.printf(loc("stadium_cleared", self.stadium.difficultyName), 0, drawY, width, "center", nil, nil, 30)

  drawY = drawY + 120
  GraphicsUtil.printf(loc("stadium_continues"), 0, drawY, width, "center", nil, nil, 4)
  GraphicsUtil.printf(self.stadium.continues, 0, drawY + 20, width, "center", nil, nil, 4)

  drawY = drawY + 60
  GraphicsUtil.printf(loc("stadium_time"), 0, drawY, width, "center", nil, nil, 4)
  GraphicsUtil.printf(frames_to_time_string(self.stadium.expendedTime, true), 0, drawY + 20, width, "center", nil, nil, 4)

  if self.unlockText then
    drawY = drawY + 80
    GraphicsUtil.printf(self.unlockText, 0, drawY, width, "center", nil, nil, 10)
  end

  local font = GraphicsUtil.getGlobalFont()
  local continueText = loc("continue_button")
  GraphicsUtil.print(continueText, (consts.CANVAS_WIDTH - font:getWidth(continueText)) / 2, consts.CANVAS_HEIGHT - 60)
end

return StadiumRecapScene

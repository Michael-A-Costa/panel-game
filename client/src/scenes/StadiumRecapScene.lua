local consts = require("common.engine.consts")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Scene = require("client.src.scenes.Scene")
local class = require("common.lib.class")
local input = require("client.src.inputManager")
local tableUtils = require("common.lib.tableUtils")
local StadiumLadder = require("common.data.StadiumLadder")
local Stadium = require("client.src.Stadium")

-- Shown once a Stadium run beat its last stage, PPL's ending in text: the difficulty's ending, the credits from Hard
-- on, the continues and time it took, and on Hard and Very Hard the code of the next difficulty
---@class StadiumRecapScene : Scene
---@field stadium Stadium
---@field endingText string
---@field creditsText string?
---@field unlockText string? the code of the next difficulty and how to enter it
---@field recapStartTime number
---@field minDisplayTime number seconds before a key press leaves the scene
---@field backgroundImg UpdatingImage
local StadiumRecapScene = class(
---@param self StadiumRecapScene
function(self, sceneParams)
  self.backgroundImg = GAME.theme.images.bg_main
  self.stadium = sceneParams.stadium
  local ladder = self.stadium.ladder
  self.endingText = loc(ladder.endingKey)
  if ladder.credits then
    self.creditsText = loc("stadium_credits")
  end
  if self.stadium.revealedDifficulty then
    local revealed = StadiumLadder.getDifficulty(self.stadium.revealedDifficulty)
    self.unlockText = loc("stadium_code", loc(revealed.nameKey), Stadium.getCodeText(revealed.index))
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

  drawY = drawY + 80
  GraphicsUtil.printf(self.endingText, width / 8, drawY, width * 3 / 4, "center", nil, nil, 4)
  if self.creditsText then
    GraphicsUtil.printf(self.creditsText, width / 8, drawY + 50, width * 3 / 4, "center", nil, nil, 0)
  end

  drawY = drawY + 110
  GraphicsUtil.printf(loc("stadium_continues"), 0, drawY, width, "center", nil, nil, 4)
  GraphicsUtil.printf(self.stadium.continues, 0, drawY + 20, width, "center", nil, nil, 4)

  drawY = drawY + 60
  GraphicsUtil.printf(loc("stadium_time"), 0, drawY, width, "center", nil, nil, 4)
  GraphicsUtil.printf(frames_to_time_string(self.stadium.expendedTime, true), 0, drawY + 20, width, "center", nil, nil, 4)

  if self.unlockText then
    drawY = drawY + 80
    GraphicsUtil.printf(self.unlockText, width / 8, drawY, width * 3 / 4, "center", nil, nil, 4)
  end

  local font = GraphicsUtil.getGlobalFont()
  local continueText = loc("continue_button")
  GraphicsUtil.print(continueText, (consts.CANVAS_WIDTH - font:getWidth(continueText)) / 2, consts.CANVAS_HEIGHT - 60)
end

return StadiumRecapScene

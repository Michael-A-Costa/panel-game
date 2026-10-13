local GameBase = require("client.src.scenes.GameBase")
local class = require("common.lib.class")
local consts = require("common.engine.consts")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Stadium = require("client.src.Stadium")
local StadiumRecapScene = require("client.src.scenes.StadiumRecapScene")

-- Scene for one match of a Stadium run; GAME.battleRoom is the Stadium
---@class Game1pStadium : GameBase
---@field stadiumStage StadiumStage the stage this match is played on; the room moves on to the next one when it ends
---@field stageTitle string
---@field stageCount integer
local Game1pStadium = class(
---@param self Game1pStadium
function(self, sceneParams)
  local stadium = GAME.battleRoom
  ---@cast stadium Stadium
  self.stadiumStage = stadium:getStage()
  self.stageTitle = Stadium.getStageTitle(self.stadiumStage)
  self.stageCount = #stadium.ladder.stages
end,
GameBase)

Game1pStadium.name = "Game1pStadium"

local HUD_WIDTH = 200
local HUD_TOP = 110
local TEXT_LIMIT = 400

function Game1pStadium:startNextScene()
  -- match:deinit is the responsibility of the one switching out of the game scene
  local stadium = GAME.battleRoom
  if stadium and stadium.complete then
    GAME.navigationStack:replace(StadiumRecapScene({stadium = stadium}), nil, function()
      self.match:deinit()
    end)
  else
    -- back to the character select, where readying up plays the next stage or the rematch
    GAME.navigationStack:pop(nil, function()
      self.match:deinit()
    end)
  end
end

function Game1pStadium:drawHUD()
  local stadium = GAME.battleRoom
  if not stadium then
    return
  end
  ---@cast stadium Stadium

  local drawX = consts.CANVAS_WIDTH / 2
  GraphicsUtil.drawRectangle("fill", drawX - HUD_WIDTH / 2, HUD_TOP, HUD_WIDTH, consts.CANVAS_HEIGHT - HUD_TOP, 0, 0, 0, 0.5)

  local left = drawX - TEXT_LIMIT / 2
  local drawY = HUD_TOP
  GraphicsUtil.printf(loc("difficulty"), left, drawY, TEXT_LIMIT, "center", nil, nil, 10)
  GraphicsUtil.printf(stadium.difficultyName, left, drawY + 26, TEXT_LIMIT, "center", nil, nil, 10)

  drawY = drawY + 70
  GraphicsUtil.printf(loc("stadium_stage", self.stadiumStage.index, self.stageCount), left, drawY, TEXT_LIMIT, "center", nil, nil, 10)
  GraphicsUtil.printf(self.stageTitle, left, drawY + 26, TEXT_LIMIT, "center", nil, nil, 4)

  drawY = drawY + 70
  GraphicsUtil.printf(loc("stadium_continues"), left, drawY, TEXT_LIMIT, "center", nil, nil, 4)
  GraphicsUtil.printf(stadium.continues, left, drawY + 20, TEXT_LIMIT, "center", nil, nil, 4)

  if not self.match.isPaused then
    for _, stack in ipairs(self.match.stacks) do
      if stack.player and stack.player.human then
        if config.show_ingame_infos then
          stack:drawMultibar()
          stack:drawAnalyticData()
        end
      else
        stack:drawMultibar()
      end
    end
  end
end

return Game1pStadium

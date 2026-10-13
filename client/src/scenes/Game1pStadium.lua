local GameBase = require("client.src.scenes.GameBase")
local class = require("common.lib.class")
local consts = require("common.engine.consts")
local input = require("client.src.inputManager")
local GraphicsUtil = require("client.src.graphics.graphics_util")
local Stadium = require("client.src.Stadium")
local StadiumRecapScene = require("client.src.scenes.StadiumRecapScene")

-- Scene for one match of a Stadium run; GAME.battleRoom is the Stadium.
-- The match opens on a card naming the stage and the opponent (PPL's pre-match screen without its dialogue); the
-- match waits on its first frame until the card closes.
---@class Game1pStadium : GameBase
---@field stadium Stadium the room this match belongs to
---@field stadiumStage StadiumStage the stage this match is played on; the room moves on to the next one when it ends
---@field stageTitle string
---@field stageLabel string "Stage x/N"
---@field cardVisible boolean the pre-match card is up and the match hasn't started yet
---@field cardTime number seconds the card has been up
local Game1pStadium = class(
---@param self Game1pStadium
function(self, sceneParams)
  local stadium = GAME.battleRoom
  ---@cast stadium Stadium
  self.stadium = stadium
  self.stadiumStage = stadium:getStage()
  self.stageTitle = Stadium.getStageTitle(self.stadiumStage)
  self.stageLabel = loc("stadium_stage", tostring(self.stadiumStage.index), tostring(#stadium.ladder.stages))
  self.cardVisible = true
  self.cardTime = 0
end,
GameBase)

Game1pStadium.name = "Game1pStadium"

local HUD_WIDTH = 200
local HUD_TOP = 110
local TEXT_LIMIT = 400
-- the card closes by itself after this long
local CARD_SECONDS = 3
-- a press this soon after the card came up is still the one that readied up on the character select
local CARD_SKIP_DELAY = 0.25
-- the stacks' portrait proportions, twice their on-stack size
local PORTRAIT_WIDTH = 192
local PORTRAIT_HEIGHT = 384
local PORTRAIT_GAP = 120
local PORTRAIT_TOP = 200

---@return boolean
function Game1pStadium:skipPressed()
  if input.isDown["MenuSelect"] then
    return true
  end
  for _, player in ipairs(self.match.players) do
    local inputConfiguration = player.inputConfiguration
    if inputConfiguration and (inputConfiguration.isDown["Swap1"] or inputConfiguration.isDown["Start"]) then
      return true
    end
  end
  return false
end

function Game1pStadium:closeCard()
  self.cardVisible = false
end

function Game1pStadium:update(dt)
  if self.cardVisible then
    if self.backgroundImage then
      self.backgroundImage:update(dt)
    end
    self.cardTime = self.cardTime + dt
    if self.cardTime >= CARD_SECONDS or (self.cardTime >= CARD_SKIP_DELAY and self:skipPressed()) then
      self:closeCard()
    end
    -- the match's frame clock only starts with its first run, so the card's time is not caught up on afterwards
    return
  end
  GameBase.update(self, dt)
end

function Game1pStadium:draw()
  if self.cardVisible then
    -- the stage without the theme's overlay, whose frames belong to the HUD
    if self.backgroundImage then
      self.backgroundImage:draw()
    end
    self:drawCard()
  else
    GameBase.draw(self)
  end
end

-- a character's portrait facing the middle of the screen, as on the stacks
---@param character Character
---@param stackNumber integer 1 left, 2 right
---@param x number
---@param y number
local function drawPortrait(character, stackNumber, x, y)
  local image = character:portraitImage(stackNumber)
  if not image then
    return
  end
  local imageWidth, imageHeight = image:getDimensions()
  local xScale = PORTRAIT_WIDTH / imageWidth
  if character:portraitIsReversed(stackNumber) then
    x = x + PORTRAIT_WIDTH
    xScale = -xScale
  end
  GraphicsUtil.draw(image, x, y, 0, xScale, PORTRAIT_HEIGHT / imageHeight)
end

-- The difficulty, the stage and its title over both portraits and names.
function Game1pStadium:drawCard()
  local width = consts.CANVAS_WIDTH
  GraphicsUtil.drawRectangle("fill", 0, 0, width, consts.CANVAS_HEIGHT, 0, 0, 0, 0.6)

  GraphicsUtil.printf(self.stadium.difficultyName, 0, 40, width, "center", nil, nil, 10)
  GraphicsUtil.printf(self.stageLabel, 0, 85, width, "center", nil, nil, 4)
  GraphicsUtil.printf(self.stageTitle, 0, 115, width, "center", nil, nil, 30)

  local centerX = width / 2
  local nameTop = PORTRAIT_TOP + PORTRAIT_HEIGHT + 10
  for i, stack in ipairs(self.match.stacks) do
    local x
    if i == 1 then
      x = centerX - PORTRAIT_GAP - PORTRAIT_WIDTH
    else
      x = centerX + PORTRAIT_GAP
    end
    drawPortrait(stack.character, i, x, PORTRAIT_TOP)
    if stack.player then
      local nameWidth = PORTRAIT_WIDTH + PORTRAIT_GAP
      GraphicsUtil.printf(stack.player.name, x - PORTRAIT_GAP / 2, nameTop, nameWidth, "center", nil, nil, 6)
    end
  end
  GraphicsUtil.printf("VS", 0, PORTRAIT_TOP + PORTRAIT_HEIGHT / 2 - 30, width, "center", nil, nil, 30)
end

-- A win names the stage that comes next; the last one leads to the recap, which says the rest.
function Game1pStadium:customGameOverSetup()
  local winners = self.match:getWinners()
  if #winners == 1 and winners[1].human then
    local nextStage = self.stadium.ladder.stages[self.stadiumStage.index + 1]
    if nextStage then
      self.text = loc("stadium_stage_beaten", self.stageTitle, Stadium.getStageTitle(nextStage))
    else
      self.text = loc("stadium_cleared", self.stadium.difficultyName)
    end
  end
end

function Game1pStadium:startNextScene()
  -- match:deinit is the responsibility of the one switching out of the game scene
  local stadium = self.stadium
  if stadium.complete then
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
  local stadium = self.stadium
  local drawX = consts.CANVAS_WIDTH / 2
  GraphicsUtil.drawRectangle("fill", drawX - HUD_WIDTH / 2, HUD_TOP, HUD_WIDTH, consts.CANVAS_HEIGHT - HUD_TOP, 0, 0, 0, 0.5)

  local left = drawX - TEXT_LIMIT / 2
  local drawY = HUD_TOP
  GraphicsUtil.printf(loc("difficulty"), left, drawY, TEXT_LIMIT, "center", nil, nil, 10)
  GraphicsUtil.printf(stadium.difficultyName, left, drawY + 26, TEXT_LIMIT, "center", nil, nil, 10)

  drawY = drawY + 70
  GraphicsUtil.printf(self.stageLabel, left, drawY, TEXT_LIMIT, "center", nil, nil, 10)
  GraphicsUtil.printf(self.stageTitle, left, drawY + 26, TEXT_LIMIT, "center", nil, nil, 4)

  drawY = drawY + 70
  GraphicsUtil.printf(loc("stadium_continues"), left, drawY, TEXT_LIMIT, "center", nil, nil, 4)
  GraphicsUtil.printf(stadium.continues, left, drawY + 20, TEXT_LIMIT, "center", nil, nil, 4)

  if not self.match.isPaused then
    for _, stack in ipairs(self.match.stacks) do
      if stack.player then
        stack:drawPlayerName()
      end
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

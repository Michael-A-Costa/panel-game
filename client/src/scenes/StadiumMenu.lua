local LocalModeMenu = require("client.src.scenes.LocalModeMenu")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local GameModes = require("common.data.GameModes")
local StadiumLadder = require("common.data.StadiumLadder")
local Stadium = require("client.src.Stadium")
local StadiumProgress = require("client.src.StadiumProgress")
local CharacterSelectStadium = require("client.src.scenes.CharacterSelectStadium")

-- Scene picking the difficulty of a 1P Stadium run, 2D or 3D, and whether to resume its saved run
---@class StadiumMenu : LocalModeMenu
---@field dimension StadiumDimension
---@field stadiumProgress StadiumProgress
---@field difficultyStepper Stepper
---@field resumeItem MenuItem? present while the picked difficulty has a saved run
---@field infoLabel Label what the picked difficulty needs to unlock or how often it was cleared
local StadiumMenu = class(
  function(self, sceneParams)
    self.dimension = Stadium.getDimension(GameModes.getPreset(self.gameModeId))
    self.stadiumProgress = sceneParams and sceneParams.progress or StadiumProgress.load()
    self.resumeItem = nil
    self:load(sceneParams)
  end,
  LocalModeMenu
)

StadiumMenu.name = "StadiumMenu"
StadiumMenu.DEFAULT_GAME_MODE_ID = GameModes.IDs.ONE_PLAYER_STADIUM

-- the difficulty picked last, offered again
local lastDifficulty = StadiumLadder.EASY

---@param difficulty integer
---@return boolean
function StadiumMenu:isUnlocked(difficulty)
  return Stadium.isUnlocked(self.stadiumProgress, self.dimension, difficulty)
end

---@return Label[]
---@return integer[]
function StadiumMenu:createDifficultyLabels()
  local labels = {}
  local values = {}
  for difficulty, ladder in ipairs(StadiumLadder.difficulties) do
    if self:isUnlocked(difficulty) then
      labels[difficulty] = ui.Label({text = ladder.nameKey})
    else
      labels[difficulty] = ui.Label({text = "stadium_locked", replacements = {loc(ladder.nameKey)}})
    end
    values[difficulty] = difficulty
  end
  return labels, values
end

---@param resume boolean
function StadiumMenu:goToCharacterSelect(resume)
  local difficulty = self.difficultyStepper.value
  if not self:isUnlocked(difficulty) then
    GAME.theme:playCancelSfx()
    return
  end

  GAME.theme:playValidationSfx()
  lastDifficulty = difficulty
  GAME.battleRoom = Stadium.create(difficulty, self.gameModeId, {resume = resume, progress = self.stadiumProgress})
  if GAME.battleRoom then
    GAME.navigationStack:push(CharacterSelectStadium({battleRoom = GAME.battleRoom}))
  end
end

function StadiumMenu:load(sceneParams)
  local labels, values = self:createDifficultyLabels()
  self.difficultyStepper = ui.Stepper({
    labels = labels,
    values = values,
    selectedIndex = lastDifficulty,
    width = 70,
    height = 25,
    onChange = function(value)
      GAME.theme:playMoveSfx()
      self:refreshDifficulty()
    end
  })

  local menuItems = {
    ui.MenuItem.createStepperMenuItem("difficulty", nil, nil, self.difficultyStepper),
    ui.MenuItem.createButtonMenuItem("stadium_new_game", nil, nil, function()
      self:goToCharacterSelect(false)
    end),
    ui.MenuItem.createButtonMenuItem("back", nil, nil, LocalModeMenu.exitMenu)
  }

  self.menu = ui.Menu.createCenteredMenu(menuItems)
  self.uiRoot:addChild(self.menu)

  local title = self.dimension == "3d" and "mm_1_stadium_3d" or "mm_1_stadium"
  self.uiRoot:addChild(ui.Label({text = title, hAlign = "center", vAlign = "top", y = 60, fontSize = 24}))
  self.infoLabel = ui.Label({text = "", translate = false, hAlign = "center", vAlign = "bottom", y = -80})
  self.uiRoot:addChild(self.infoLabel)

  self:refreshDifficulty()
end

-- offers "resume" only for a difficulty with a saved run, and says what a locked one needs
function StadiumMenu:refreshDifficulty()
  if self.resumeItem then
    self.menu:removeMenuItem(self.resumeItem.id)
    self.resumeItem = nil
  end

  local difficulty = self.difficultyStepper.value
  local ladder = StadiumLadder.getDifficulty(difficulty)
  local progress = self.stadiumProgress:get(self.dimension, difficulty)
  if not self:isUnlocked(difficulty) then
    local unlockedBy = StadiumLadder.getDifficulty(ladder.unlockedBy)
    self.infoLabel:setText(loc("stadium_unlock_hint", loc(unlockedBy.nameKey)), nil, false)
  elseif progress.clears > 0 then
    self.infoLabel:setText(loc("stadium_record", tostring(progress.clears), tostring(progress.bestContinues)), nil, false)
  else
    self.infoLabel:setText("", nil, false)
  end

  if self:isUnlocked(difficulty) and progress.lastStageBeaten > 0 then
    local nextStage = StadiumLadder.getResumeStage(difficulty, progress.lastStageBeaten)
    self.resumeItem = ui.MenuItem.createButtonMenuItem("stadium_resume", {nextStage, #ladder.stages}, nil, function()
      self:goToCharacterSelect(true)
    end)
    self.menu:addMenuItem(2, self.resumeItem)
  end
end

-- called when the menu becomes active again, e.g. after a run ended or unlocked a difficulty
function StadiumMenu:refresh()
  local labels, values = self:createDifficultyLabels()
  self.difficultyStepper:setLabels(labels, values, self.difficultyStepper.selectedIndex)
  self:refreshDifficulty()
end

return StadiumMenu

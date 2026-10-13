local CharacterSelect = require("client.src.scenes.CharacterSelect")
local CharacterSelectChallenge = require("client.src.scenes.CharacterSelectChallenge")
local class = require("common.lib.class")
local ui = require("client.src.ui")

-- The character select of 1P vs CPU: challenge mode's screen plus the human's level, which the CPU plays on too
---@class CharacterSelectVsCpu : CharacterSelectChallenge
local CharacterSelectVsCpu = class(
  function(self, sceneParams)
  end,
  CharacterSelectChallenge
)

CharacterSelectVsCpu.name = "CharacterSelectVsCpu"

---@return Player human
---@return CpuPlayer cpu
function CharacterSelectVsCpu:getParticipants()
  local human, cpu
  for _, player in ipairs(self.battleRoom.players) do
    if player.isCpu then
      cpu = player
    elseif player.human then
      human = player
    end
  end
  return human, cpu
end

function CharacterSelectVsCpu:loadUserInterface()
  CharacterSelectChallenge.loadUserInterface(self)

  local human = self:getParticipants()
  self.ui.levelSelection = ui.MultiPlayerSelectionWrapper({hFill = true, alignment = "top", hAlign = "center", vAlign = "top"})
  self.ui.levelSelection:setTitle("level")
  local height = self.ui.grid.unitSize - self.ui.grid.unitMargin * 2 - self.ui.levelSelection.height
  local levelSlider = self:createLevelSlider(human, 15, height)
  self.ui.levelSelection:addElement(levelSlider, human)
  self.ui.grid:createElementAt(7, 2, 2, 1, "levelSelection", self.ui.levelSelection)
end

function CharacterSelectVsCpu:onLevelDataChanged(levelData, player)
  CharacterSelect.onLevelDataChanged(self, levelData, player)
  local _, cpu = self:getParticipants()
  if cpu then
    cpu:copyLevelFrom(player)
  end
end

return CharacterSelectVsCpu

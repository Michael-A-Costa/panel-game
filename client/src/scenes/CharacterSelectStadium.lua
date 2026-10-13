local CharacterSelectChallenge = require("client.src.scenes.CharacterSelectChallenge")
local class = require("common.lib.class")
local ui = require("client.src.ui")
local Stadium = require("client.src.Stadium")

-- The character select between Stadium matches: challenge mode's screen with a line naming the next stage.
-- Readying up plays it; leaving ends the run, which stays saved for "resume".
---@class CharacterSelectStadium : CharacterSelectChallenge
---@field battleRoom Stadium
local CharacterSelectStadium = class(
  function(self, sceneParams)
  end,
  CharacterSelectChallenge
)

CharacterSelectStadium.name = "CharacterSelectStadium"

function CharacterSelectStadium:loadUserInterface()
  CharacterSelectChallenge.loadUserInterface(self)

  self.ui.stadiumInfo = ui.Label({text = "", translate = false, hAlign = "center", vAlign = "center"})
  self.ui.grid:createElementAt(2, 1, 7, 1, "stadiumInfo", self.ui.stadiumInfo)
end

-- called whenever the scene becomes active again, after every match
function CharacterSelectStadium:refresh()
  local stadium = self.battleRoom
  if self.ui.stadiumInfo and stadium then
    local stage = stadium:getStage()
    local text = stadium.difficultyName .. "   " .. loc("stadium_stage", tostring(stage.index), tostring(#stadium.ladder.stages)) .. ": "
        .. Stadium.getStageTitle(stage) .. "   " .. loc("stadium_continues") .. " " .. stadium.continues
    self.ui.stadiumInfo:setText(text, nil, false)
  end
end

return CharacterSelectStadium

local class = require("common.lib.class")
local consts = require("common.engine.consts")
local Player = require("client.src.Player")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
-- registers itself with ComputerPlayer
require("common.engine.computerPlayers.PplCpu.PplCpu")

local DEFAULT_CPU = "PplCpu"

---@class CpuPlayerSettings : PlayerSettings
---@field cpuName string the registered ComputerPlayer implementation that plays
---@field cpuOptions CpuStrength its options without the seed, which every match derives anew

-- A player whose inputs come from a computer player: its stack is a regular engine Stack that the CPU feeds one input
-- per frame (see ClientMatch:run), so a match against it records and replays like any other.
---@class CpuPlayer : Player
---@field settings CpuPlayerSettings
---@field cpuOptions CpuOptions? the options the last match's CPU was created with, seed included
---@overload fun(name: string): CpuPlayer
local CpuPlayer = class(
---@param self CpuPlayer
---@param name string
function(self, name)
  self.human = false
  self.isCpu = true
  self.isLocal = true
  self.settings.wantsReady = true
  self.settings.cpuName = DEFAULT_CPU
  self.settings.cpuOptions = {level = 1}
  self.cpuOptions = nil
  self:setCharacter(consts.RANDOM_CHARACTER_SPECIAL_VALUE)
  self:setStage(consts.RANDOM_STAGE_SPECIAL_VALUE)
end,
Player)

CpuPlayer.TYPE = "CpuPlayer"

---@param cpuName string a registered ComputerPlayer implementation
---@param cpuOptions CpuStrength
function CpuPlayer:setCpu(cpuName, cpuOptions)
  assert(ComputerPlayer.isRegistered(cpuName), "No CPU implementation named " .. tostring(cpuName))
  self.settings.cpuName = cpuName
  self.settings.cpuOptions = cpuOptions
end

-- plays on the same level as player, so the CPU's own level alone decides how hard the match is
---@param player Player
function CpuPlayer:copyLevelFrom(player)
  self:setStyle(player.settings.style)
  self:setLevel(player.settings.level)
  self:setDifficulty(player.settings.difficulty)
  self:setLevelData(deepcpy(player.settings.levelData))
end

-- Creates the CPU that plays engineStack for the coming match. The match owns it, so it never outlives the stack it
-- reads; the player only keeps its options for the replay.
---@param engineStack Stack
---@param seed integer
---@return CpuImplementation
function CpuPlayer:createComputerPlayer(engineStack, seed)
  local strength = self.settings.cpuOptions
  ---@type CpuOptions
  local options = {seed = seed, level = strength.level, difficulty = strength.difficulty, stage = strength.stage}
  self.cpuOptions = options
  return ComputerPlayer.create(self.settings.cpuName, engineStack, options)
end

-- CPUs are always ready
function CpuPlayer:setWantsReady(wantsReady)
  self.settings.wantsReady = true
  self:emitSignal("wantsReadyChanged", true)
end

function CpuPlayer:getInfo()
  local info = Player.getInfo(self)
  info.cpuName = self.settings.cpuName
  return info
end

return CpuPlayer

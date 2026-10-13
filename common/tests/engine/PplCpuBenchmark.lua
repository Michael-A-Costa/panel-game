-- Frame cost of the PPL CPU's getInput on busy boards: CPU vs CPU at the strongest preset, 2D and 3D, with the JIT
-- on and off (Android runs without it). Not part of the default test run; start it by name:
--   love ./testLauncher.lua PplCpuBenchmark
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
require("common.engine.computerPlayers.PplCpu.PplCpu")

-- frames played before measuring, so the stacks have grown and garbage is falling
local WARM_UP_FRAMES = 480
local MEASURED_CALLS = 6000
-- PA's fastest modern level, so the boards stay high and busy
local STACK_LEVEL = 10

---@param gameModeId GameModeID
---@param seed integer
---@return Match
---@return CpuImplementation[]
local function createMatch(gameModeId, seed)
  local match = Match(GeneratorSource(seed, true), GameModes.getPreset(gameModeId).matchRules)
  local cpus = {}
  for i = 1, 2 do
    local stack = match:createStackWithSettings(LevelPresets.getModern(STACK_LEVEL), true, "controller")
    ---@cast stack Stack
    cpus[i] = ComputerPlayer.create("PplCpu", stack, {seed = ComputerPlayer.deriveSeed(seed, i), level = ComputerPlayer.LEVEL_COUNT})
  end
  match:addTarget(match.stacks[1], match.stacks[2])
  match:addTarget(match.stacks[2], match.stacks[1])
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  return match, cpus
end

---@param gameModeId GameModeID
---@param jitOn boolean
local function measure(gameModeId, jitOn)
  if not jitOn then
    jit.off()
    jit.flush()
  end
  local seed = 1
  local match, cpus = createMatch(gameModeId, seed)
  local frame = 0
  local calls = 0
  local total = 0
  local slowest = 0
  local durations = {}
  while calls < MEASURED_CALLS do
    if match:hasEnded() then
      seed = seed + 1
      match, cpus = createMatch(gameModeId, seed)
      frame = 0
    end
    frame = frame + 1
    for i, stack in ipairs(match.stacks) do
      ---@cast stack Stack
      if not stack:game_ended() and #stack.confirmedInput == stack.clock then
        local start = love.timer.getTime()
        local input = cpus[i]:getInput()
        local duration = love.timer.getTime() - start
        if frame > WARM_UP_FRAMES then
          calls = calls + 1
          total = total + duration
          durations[calls] = duration
          slowest = math.max(slowest, duration)
        end
        stack:receiveConfirmedInput(input)
      end
    end
    match:run()
  end
  if not jitOn then
    jit.on()
  end
  table.sort(durations)
  print(string.format("PplCpu getInput %s, JIT %s: %d calls over %d games, mean %.4f ms, p99 %.4f ms, max %.4f ms",
                      gameModeId, jitOn and "on" or "off", calls, seed, total / calls * 1000,
                      durations[math.ceil(calls * 0.99)] * 1000, slowest * 1000))
end

for _, gameModeId in ipairs({GameModes.IDs.ONE_PLAYER_VS_CPU, GameModes.IDs.ONE_PLAYER_VS_CPU_3D}) do
  measure(gameModeId, true)
  measure(gameModeId, false)
end

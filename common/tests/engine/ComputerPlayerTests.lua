local json = require("common.lib.dkjson")
local tableUtils = require("common.lib.tableUtils")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local Match = require("common.engine.Match")
local GeneratorSource = require("common.engine.GeneratorSource")
local ReplayV3 = require("common.data.ReplayV3")
local ComputerPlayer = require("common.engine.computerPlayers.ComputerPlayer")
-- registers itself with ComputerPlayer
require("common.engine.computerPlayers.PplCpu.PplCpu")

local MAX_FRAMES = 60 * 60 * 5

---@param actual any
---@param expected any
---@param what string
local function expect(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

---@param f function
---@param messagePart string
---@param what string
local function expectError(f, messagePart, what)
  local success, err = pcall(f)
  assert(not success, what .. ": expected an error")
  assert(string.find(tostring(err), messagePart, 1, true),
         what .. ": expected an error about '" .. messagePart .. "', got " .. tostring(err))
end

-- everything about a stack that a replay has to reproduce
---@param stack Stack
---@return string
local function snapshot(stack)
  ---@type (integer | string)[]
  local parts = {stack.clock, stack.game_over_clock, stack.score, stack.cur_row, stack.cur_col, stack.rotationTimer,
                 stack.chain_counter, stack.panels_cleared, stack.swapCount}
  for row = 0, #stack.panels do
    for column = 1, stack.width do
      local panel = stack.panels[row][column]
      parts[#parts + 1] = panel.color .. (panel.isGarbage and "g" .. panel.x_offset or "") .. panel.state
    end
  end
  return table.concat(parts, ",")
end

-- two local stacks against each other, built like ClientMatch builds a 1P vs CPU match, each played by a PplCpu
---@param gameModeId GameModeID
---@param seed integer
---@param cpuLevels integer[]
---@param stackLevel integer
---@return Match
---@return CpuImplementation[]
local function createCpuMatch(gameModeId, seed, cpuLevels, stackLevel)
  local gameMode = GameModes.getPreset(gameModeId)
  local match = Match(GeneratorSource(seed, true), gameMode.matchRules)
  local cpus = {}
  for i = 1, 2 do
    local stack = match:createStackWithSettings(LevelPresets.getModern(stackLevel), true, "controller")
    ---@cast stack Stack
    cpus[i] = ComputerPlayer.create("PplCpu", stack, {seed = ComputerPlayer.deriveSeed(seed, i), level = cpuLevels[i]})
  end
  match:addTarget(match.stacks[1], match.stacks[2])
  match:addTarget(match.stacks[2], match.stacks[1])
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  return match, cpus
end

-- what ClientMatch:run does for CPU stacks: one input for each caught up stack, then one step of the match
---@param match Match
---@param cpus CpuImplementation[]
local function runFrame(match, cpus)
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    if not stack:game_ended() and #stack.confirmedInput == stack.clock then
      stack:receiveConfirmedInput(cpus[i]:getInput())
    end
  end
  match:run()
end

---@param match Match
---@param cpus CpuImplementation[]
local function playToEnd(match, cpus)
  local frames = 0
  while not match:hasEnded() do
    frames = frames + 1
    assert(frames <= MAX_FRAMES, "a CPU vs CPU match should end within " .. MAX_FRAMES .. " frames")
    runFrame(match, cpus)
  end
end

---@param match Match
---@return integer? winnerIndex
local function winnerIndex(match)
  local winners = match:getWinners()
  if #winners == 1 then
    return tableUtils.indexOf(match.stacks, winners[1])
  end
end

-- writes the replay the way the game saves it and reads it back; the stacks are plain, no CPU is attached
---@param replay ReplayV3
---@return Match
local function reloadReplay(replay)
  local loaded = ReplayV3.createFromTable(json.decode(json.encode(replay)), true)
  local match = Match.createFromReplay(loaded)
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  return match
end

local function registryTest()
  expect(ComputerPlayer.isRegistered("PplCpu"), true, "PplCpu registers itself")
  expectError(function()
    ComputerPlayer.create("NoSuchCpu", {}, {seed = 1, level = 1})
  end, "No CPU implementation named NoSuchCpu", "unknown CPUs are refused")
  expectError(function()
    ComputerPlayer.register("PplCpu", function() end)
  end, "already registered", "a name can't be taken twice")

  local created = {}
  ComputerPlayer.register("TestCpu", function(stack, options)
    created.stack = stack
    created.options = options
    return {getInput = function()
      return KeyDataEncoding.idle
    end}
  end)
  local fakeStack = {}
  local options = {seed = 3, difficulty = 2, stage = 14}
  local cpu = ComputerPlayer.create("TestCpu", fakeStack, options)
  expect(created.stack, fakeStack, "the implementation gets the stack")
  expect(created.options, options, "the implementation gets the options")
  expect(cpu:getInput(), KeyDataEncoding.idle, "create returns the implementation's instance")

  ComputerPlayer.register("BrokenCpu", function()
    return {}
  end)
  expectError(function()
    ComputerPlayer.create("BrokenCpu", fakeStack, {seed = 1, level = 1})
  end, "does not implement getInput", "implementations must have getInput")
end

local function optionValidationTest()
  local invalid = {
    {options = nil, error = "must be a table"},
    {options = {level = 1}, error = "integer seed"},
    {options = {seed = 1.5, level = 1}, error = "integer seed"},
    {options = {seed = 1}, error = "a level or a difficulty"},
    {options = {seed = 1, level = 0}, error = "CPU level must be"},
    {options = {seed = 1, level = 11}, error = "CPU level must be"},
    {options = {seed = 1, level = 2.5}, error = "CPU level must be"},
    {options = {seed = 1, level = 3, difficulty = 1, stage = 1}, error = "not both"},
    {options = {seed = 1, difficulty = 0, stage = 1}, error = "a level or a difficulty"},
    {options = {seed = 1, difficulty = 6, stage = 1}, error = "a level or a difficulty"},
    {options = {seed = 1, difficulty = 1}, error = "has stages 1 to 11"},
    {options = {seed = 1, difficulty = 1, stage = 12}, error = "has stages 1 to 11"},
    {options = {seed = 1, difficulty = 3, stage = 16}, error = "has stages 1 to 15"},
    {options = {seed = 1, difficulty = 5, stage = 17}, error = "has stages 1 to 16"},
  }
  for i, case in ipairs(invalid) do
    expectError(function()
      ComputerPlayer.validateOptions(case.options)
    end, case.error, "invalid options " .. i)
  end

  ComputerPlayer.validateOptions({seed = 0, level = 10})
  ComputerPlayer.validateOptions({seed = 4294967295, difficulty = 4, stage = 16})
  ComputerPlayer.validateOptions({seed = 7, difficulty = 1, stage = 11})

  -- the DemoCPU table (AI-SPEC §3.5) and a Stadium preset passing through
  local difficulty, stage = ComputerPlayer.getPreset({seed = 1, level = 1})
  expect(difficulty * 100 + stage, 101, "level 1 is Easy stage 1")
  difficulty, stage = ComputerPlayer.getPreset({seed = 1, level = 8})
  expect(difficulty * 100 + stage, 510, "level 8 is Super Hard stage 10")
  difficulty, stage = ComputerPlayer.getPreset({seed = 1, level = 10})
  expect(difficulty * 100 + stage, 515, "level 10 is Super Hard stage 15")
  difficulty, stage = ComputerPlayer.getPreset({seed = 1, difficulty = 3, stage = 7})
  expect(difficulty * 100 + stage, 307, "a Stadium preset is used as it is")

  local seed1 = ComputerPlayer.deriveSeed(123456, 1)
  local seed2 = ComputerPlayer.deriveSeed(123456, 2)
  assert(seed1 ~= seed2, "each player of a match gets its own seed")
  expect(ComputerPlayer.deriveSeed(123456, 1), seed1, "the seed only depends on the match seed and the player")
  assert(seed1 >= 0 and seed1 < 2 ^ 32 and seed1 == math.floor(seed1), "seeds are 32 bit integers")
end

registryTest()
optionValidationTest()

local randomAndClocks = {
  {math, "random"}, {love.math, "random"}, {os, "time"}, {os, "clock"}, {love.timer, "getTime"},
}

---@param cpu CpuImplementation
---@return string
local function getInputWithoutRandomOrClocks(cpu)
  local originals = {}
  for i, entry in ipairs(randomAndClocks) do
    originals[i] = entry[1][entry[2]]
    entry[1][entry[2]] = function()
      error("a CPU must not use " .. entry[2])
    end
  end
  local success, result = pcall(cpu.getInput, cpu)
  for i, entry in ipairs(randomAndClocks) do
    entry[1][entry[2]] = originals[i]
  end
  assert(success, result)
  return result
end

-- getInput only reads: the stack's whole rollback state, panel generator included, is the same before and after
---@param gameModeId GameModeID
local function getInputIsReadOnlyTest(gameModeId)
  local match, cpus = createCpuMatch(gameModeId, 4321, {10, 8}, 6)
  local before = {}
  local after = {}
  local actionsChecked = 0
  for _ = 1, 900 do
    if match:hasEnded() then
      break
    end
    for i, stack in ipairs(match.stacks) do
      ---@cast stack Stack
      if not stack:game_ended() and #stack.confirmedInput == stack.clock then
        stack:saveIntoRollbackCopy(before)
        local inputCount = #stack.confirmedInput
        local input = getInputWithoutRandomOrClocks(cpus[i])
        stack:saveIntoRollbackCopy(after)
        assert(tableUtils.deep_content_equal(before, after), "getInput changed stack " .. i .. " at clock " .. stack.clock)
        expect(#stack.confirmedInput, inputCount, "getInput adds no inputs itself")
        if input ~= KeyDataEncoding.idle then
          actionsChecked = actionsChecked + 1
        end
        stack:receiveConfirmedInput(input)
      end
    end
    match:run()
  end
  assert(actionsChecked > 20, "the check covered the CPU's moves and swaps, not only idle frames")
end

getInputIsReadOnlyTest(GameModes.IDs.ONE_PLAYER_VS_CPU)
getInputIsReadOnlyTest(GameModes.IDs.ONE_PLAYER_VS_CPU_3D)

-- CPU vs CPU plays to a result, the same one every time, and its replay plays back without any CPU.
-- On Stadium Hard's stack level, slow enough that the weaker CPU clears panels too before it loses.
---@param gameModeId GameModeID
---@param seed integer
local function cpuVsCpuTest(gameModeId, seed)
  local match, cpus = createCpuMatch(gameModeId, seed, {5, 10}, 4)
  local replay = match:createNewReplay()
  playToEnd(match, cpus)
  local winner = winnerIndex(match)
  assert(winner, "the match has a winner")
  for i, stack in ipairs(match.stacks) do
    assert(stack.panels_cleared > 0, "CPU " .. i .. " made matches")
  end

  local again, againCpus = createCpuMatch(gameModeId, seed, {5, 10}, 4)
  playToEnd(again, againCpus)
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    local againStack = again.stacks[i]
    ---@cast againStack Stack
    expect(table.concat(againStack.confirmedInput), table.concat(stack.confirmedInput), "CPU " .. i .. " plays the same inputs again")
    expect(snapshot(againStack), snapshot(stack), "stack " .. i .. " ends the same again")
  end
  expect(winnerIndex(again), winner, "the same CPU wins again")

  ReplayV3.finalizeReplay(match, replay)
  expect(replay.metadata.winnerIndex, winner, "the replay records the winner")
  local replayed = reloadReplay(replay)
  local frames = 0
  while not replayed:hasEnded() do
    frames = frames + 1
    assert(frames <= MAX_FRAMES, "the replay should end")
    replayed:run()
  end
  for i, stack in ipairs(match.stacks) do
    ---@cast stack Stack
    local replayedStack = replayed.stacks[i]
    ---@cast replayedStack Stack
    expect(replayedStack.cylinder, stack.cylinder, "the replay rebuilds the same kind of stack")
    expect(snapshot(replayedStack), snapshot(stack), "replayed stack " .. i .. " ends exactly like the recorded one")
  end
  expect(winnerIndex(replayed), winner, "the replay has the same winner")
end

cpuVsCpuTest(GameModes.IDs.ONE_PLAYER_VS_CPU, 2024)
cpuVsCpuTest(GameModes.IDs.ONE_PLAYER_VS_CPU_3D, 2025)

-- getInput allocates nothing once warmed up, as gameplay loop code must not
---@param gameModeId GameModeID
local function noAllocationTest(gameModeId)
  local match, cpus = createCpuMatch(gameModeId, 99, {10, 10}, 1)
  for _ = 1, 600 do
    runFrame(match, cpus)
  end

  -- interpreted, as on Android, so LuaJIT compiling traces doesn't count as garbage of the CPU's; flushed, so a side
  -- exit of an older trace rebuilding the tables it sank doesn't either
  jit.off()
  jit.flush()
  collectgarbage("collect")
  collectgarbage("stop")
  local allocated = 0
  local calls = 0
  while calls < 600 and not match:hasEnded() do
    for i, stack in ipairs(match.stacks) do
      ---@cast stack Stack
      if not stack:game_ended() and #stack.confirmedInput == stack.clock then
        local memoryBefore = collectgarbage("count")
        local input = cpus[i]:getInput()
        allocated = allocated + collectgarbage("count") - memoryBefore
        calls = calls + 1
        stack:receiveConfirmedInput(input)
      end
    end
    match:run()
  end
  collectgarbage("restart")
  jit.on()

  expect(calls, 600, "the match lasted for the measurement")
  assert(allocated == 0, string.format("getInput allocated %.2f KB over %d calls", allocated, calls))
end

noAllocationTest(GameModes.IDs.ONE_PLAYER_VS_CPU)
noAllocationTest(GameModes.IDs.ONE_PLAYER_VS_CPU_3D)

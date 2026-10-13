-- The entry point for computer players: a registry of CPU implementations and the contract they share.
-- A CPU is an input device: it reads the stack it plays and hands back one input per frame, nothing else.
-- See computerPlayer.md for the rules an implementation has to follow.

-- how strong a CPU plays, which players and ladders keep; a match adds the seed to make CpuOptions
---@class CpuStrength
---@field level integer? 1-10 on Pokémon Puzzle League's DemoCPU scale (AI-SPEC §3.5); excludes difficulty and stage
---@field difficulty integer? 1-5, Stadium difficulty Easy to Super Hard (AI-SPEC §3.4); needs stage
---@field stage integer? 1 to ComputerPlayer.STAGE_COUNTS[difficulty], the opponent's place in the Stadium ladder

---@class CpuOptions : CpuStrength
---@field seed integer seeds the CPU's own random generator; derive it with ComputerPlayer.deriveSeed

---@class CpuImplementation
---@field getInput fun(self: CpuImplementation): string one KeyDataEncoding character for the stack's next frame

---@alias CpuImplementationClass fun(stack: Stack, options: CpuOptions): CpuImplementation

-- The strength scales are Pokémon Puzzle League's, so its preset tables are the one source of their sizes
local PplPresets = require("common.engine.computerPlayers.PplCpu.PplPresets")

local ComputerPlayer = {}

ComputerPlayer.LEVEL_COUNT = PplPresets.LEVEL_COUNT
-- stages per Stadium difficulty, the lengths of PPL's per-difficulty AI tables (STADIUM-SPEC §1)
ComputerPlayer.STAGE_COUNTS = {}
for difficulty = PplPresets.EASY, PplPresets.SUPER_HARD do
  ComputerPlayer.STAGE_COUNTS[difficulty] = PplPresets.stageCount(difficulty)
end

---@type table<string, CpuImplementationClass>
local implementations = {}

---@param name string unique name the CPU is created by, e.g. "PplCpu"
---@param implClass CpuImplementationClass constructor taking (stack, options)
function ComputerPlayer.register(name, implClass)
  assert(type(name) == "string" and name ~= "", "a CPU implementation needs a name")
  assert(implClass, "CPU implementation " .. name .. " is nil")
  assert(implementations[name] == nil or implementations[name] == implClass,
         "another CPU implementation is already registered as " .. name)
  implementations[name] = implClass
end

---@param name string
---@return boolean
function ComputerPlayer.isRegistered(name)
  return implementations[name] ~= nil
end

---@param value any
---@param minimum integer
---@param maximum integer
---@return boolean
local function isIntegerBetween(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

-- errors with a readable message if options don't follow the CpuOptions contract
---@param options CpuOptions
function ComputerPlayer.validateOptions(options)
  assert(type(options) == "table", "CPU options must be a table")
  assert(type(options.seed) == "number" and options.seed == math.floor(options.seed),
         "CPU options need an integer seed, got " .. tostring(options.seed))
  if options.level ~= nil then
    assert(options.difficulty == nil and options.stage == nil, "CPU options take a level or a difficulty and stage, not both")
    assert(isIntegerBetween(options.level, 1, ComputerPlayer.LEVEL_COUNT),
           "CPU level must be an integer from 1 to " .. ComputerPlayer.LEVEL_COUNT .. ", got " .. tostring(options.level))
  else
    local difficultyCount = #ComputerPlayer.STAGE_COUNTS
    assert(isIntegerBetween(options.difficulty, 1, difficultyCount),
           "CPU options need a level or a difficulty from 1 to " .. difficultyCount .. ", got " .. tostring(options.difficulty))
    local stageCount = ComputerPlayer.STAGE_COUNTS[options.difficulty]
    assert(isIntegerBetween(options.stage, 1, stageCount),
           "CPU difficulty " .. options.difficulty .. " has stages 1 to " .. stageCount .. ", got " .. tostring(options.stage))
  end
end

-- A seed per player that is stable for a given match, so CPU vs CPU games replay the same way from the same seed.
---@param matchSeed integer the seed of the match's panel source
---@param playerNumber integer the stack's index in the match
---@return integer seed between 0 and 2^32 - 1
function ComputerPlayer.deriveSeed(matchSeed, playerNumber)
  return (matchSeed * 7919 + playerNumber * 104729) % 4294967296
end

-- Creates the CPU that is going to play stack.
-- Call its getInput once per frame, only while the stack is caught up (#stack.confirmedInput == stack.clock) and
-- before that frame runs; the input it returns is the stack's input for that frame.
---@param name string a registered implementation
---@param stack Stack the stack the CPU plays; the CPU only ever reads it
---@param options CpuOptions
---@return CpuImplementation
function ComputerPlayer.create(name, stack, options)
  local implClass = implementations[name]
  if not implClass then
    local names = {}
    for registeredName, _ in pairs(implementations) do
      names[#names + 1] = registeredName
    end
    table.sort(names)
    error("No CPU implementation named " .. tostring(name) .. " (registered: " .. table.concat(names, ", ") .. ")")
  end
  assert(stack, "a CPU needs the stack it plays")
  ComputerPlayer.validateOptions(options)

  local cpu = implClass(stack, options)
  assert(type(cpu.getInput) == "function", "CPU implementation " .. name .. " does not implement getInput")
  return cpu
end

return ComputerPlayer

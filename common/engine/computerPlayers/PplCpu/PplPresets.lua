-- PPL's CPU strength settings (USA): AISetLevel(game, stage) for the Stadium ladder (AI-SPEC §3.4, §6.1-6.3) and
-- the DemoCPU levels 1-10 the vs-CPU menu uses (§3.5).

local EASY = 1
local NORMAL = 2
local HARD = 3
local VERY_HARD = 4
local SUPER_HARD = 5
local UNLIMITED_CHAIN = -99

-- characteristic[] per difficulty (ai.c:56-140); their lengths are the ladder lengths
local CHARACTER_BY_STAGE = {
  [EASY] = {0x00, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x07, 0x07, 0x07},
  [NORMAL] = {0x01, 0x03, 0x03, 0x03, 0x03, 0x07, 0x07, 0x07, 0x07, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F},
  [HARD] = {0x23, 0x27, 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xBF, 0xBF, 0xEF, 0xBF, 0xFF, 0xBF, 0xBF, 0xBF},
  [VERY_HARD] = {0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF},
  [SUPER_HARD] = {0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF},
}

-- AISetCharacter(stage): chainLimit before the difficulty adjusts it (ai.c:175-232). Stage 16 has no case on NTSC
-- and keeps the brain's previous value; in the Stadium ladder that is stage 15's -99, which is used here.
local CHAIN_LIMIT_BY_STAGE = {-1, -2, -3, -4, 0, -5, -6, -7, 0, -8, 0, -9, -10, UNLIMITED_CHAIN, UNLIMITED_CHAIN,
                              UNLIMITED_CHAIN}

-- DemoCPU(level) -> AISetLevel(game, stage) (tetris.c:187-232)
local DEMO_LEVELS = {
  {EASY, 1}, {EASY, 9}, {NORMAL, 3}, {NORMAL, 12}, {HARD, 6},
  {HARD, 14}, {VERY_HARD, 3}, {SUPER_HARD, 10}, {VERY_HARD, 15}, {SUPER_HARD, 15},
}

local PplPresets = {
  EASY = EASY,
  NORMAL = NORMAL,
  HARD = HARD,
  VERY_HARD = VERY_HARD,
  SUPER_HARD = SUPER_HARD,
  LEVEL_COUNT = #DEMO_LEVELS,
}

-- stages in each difficulty's ladder: 11, 14, 15, 16, 16
---@param difficulty integer
---@return integer
function PplPresets.stageCount(difficulty)
  return #CHARACTER_BY_STAGE[difficulty]
end

---@param stage integer
---@return integer
local function veryHardSpeed(stage)
  if stage < 3 then
    return 11
  elseif stage < 5 then
    return 10
  elseif stage < 7 then
    return 9
  elseif stage < 9 then
    return 8
  else
    return 7
  end
end

---@param stage integer
---@return integer
local function superHardSpeed(stage)
  if stage < 5 then
    return 7
  elseif stage < 9 then
    return 6
  elseif stage < 13 then
    return 5
  else
    return 4
  end
end

-- AISetLevel(game, stage): the brain settings of a Stadium opponent.
---@param difficulty integer 1 Easy .. 5 Super Hard (PPL's game)
---@param stage integer 1 .. stageCount(difficulty)
---@return PplBrainSettings
function PplPresets.forStage(difficulty, stage)
  local characters = CHARACTER_BY_STAGE[difficulty]
  assert(characters, "PPL CPU difficulty must be 1-5, got " .. tostring(difficulty))
  assert(characters[stage], "PPL CPU difficulty " .. difficulty .. " has no stage " .. tostring(stage))

  local chainLimit = CHAIN_LIMIT_BY_STAGE[stage]
  local speed
  local think = 0
  -- (stage - 1) / 2 is C integer division
  local halfStage = math.floor((stage - 1) / 2)
  if difficulty == EASY then
    speed = 35 - halfStage
    think = -1
  elseif difficulty == NORMAL then
    speed = 20 - halfStage
    chainLimit = math.max(chainLimit, -3)
  elseif difficulty == HARD then
    speed = 16 - halfStage
    if chainLimit ~= UNLIMITED_CHAIN and chainLimit ~= 0 then
      chainLimit = chainLimit - 1
    end
  elseif difficulty == VERY_HARD then
    speed = veryHardSpeed(stage)
    if chainLimit ~= UNLIMITED_CHAIN and chainLimit ~= 0 then
      chainLimit = chainLimit - 2
    end
    if stage >= 9 then
      think = -1
    end
  else
    speed = superHardSpeed(stage)
    chainLimit = UNLIMITED_CHAIN
    think = -1
  end

  return {speed = speed, character = characters[stage], chainLimit = chainLimit, think = think}
end

-- DemoCPU(level): the brain settings of vs-CPU level 1-10.
---@param level integer
---@return PplBrainSettings
function PplPresets.forLevel(level)
  local entry = DEMO_LEVELS[level]
  assert(entry, "PPL CPU level must be 1-" .. #DEMO_LEVELS .. ", got " .. tostring(level))
  return PplPresets.forStage(entry[1], entry[2])
end

return PplPresets

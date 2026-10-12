local ClientMatch = require("client.src.ClientMatch")
local GameModes = require("common.data.GameModes")
local Player = require("client.src.Player")
local GeneratorSource = require("common.engine.GeneratorSource")
local LevelPresets = require("common.data.LevelPresets")

---@param cylinder boolean
---@return PlayerStack
local function createStack(cylinder)
  local player = Player.createLocalPlayerFromConfig()
  player.isLocal = false
  player:setLevel(5)
  player:setLevelData(LevelPresets.getModern(5))
  player:setStyle(GameModes.Styles.MODERN)
  player:setInputMethod("controller")
  player.playerNumber = 1
  local gameMode = GameModes.getPreset(GameModes.IDs.ONE_PLAYER_ENDLESS)
  gameMode.matchRules.stackSetupModifications.cylinder = cylinder
  local match = ClientMatch.createFromGameMode({player}, gameMode, GeneratorSource(1, false), false)
  match:start()
  return match.stacks[1]
end

local function onlyCylindersGetTheRendererTest()
  assert(createStack(true).cylinderRenderer)
  assert(createStack(false).cylinderRenderer == nil)
end

onlyCylindersGetTheRendererTest()

local function cursorIsCenteredOnTheFrontPairTest()
  local stack = createStack(true)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  local center = stack.frameOriginX + stack.baseWidth / 2

  local leftX = renderer:popEffectOrigin(engine.cur_col, engine.cur_row)
  local rightX = renderer:popEffectOrigin(engine.cur_col % engine.width + 1, engine.cur_row)
  assert(leftX and rightX, "the cursor pair is on the front")
  assert(math.abs((leftX + rightX) / 2 + 8 - center) < 1e-6, "the pair is on either side of the middle")

  local cursorX, cursorWidth = renderer:getCursorPlacement()
  assert(math.abs(stack.frameOriginX + cursorX + cursorWidth / 2 - center) < 1e-6, "the cursor is in the middle")
  assert(cursorWidth > rightX - leftX, "the cursor covers the pair")
end

cursorIsCenteredOnTheFrontPairTest()

local function effectsStayOnTheFrontTest()
  local stack = createStack(true)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  local backColumn = (engine.cur_col + engine.width / 2 - 1) % engine.width + 1
  assert(renderer:popEffectOrigin(backColumn, 5) == nil, "no explosions on the back")
  local cardX = renderer:cardOrigin(backColumn, 5)
  assert(cardX >= stack.frameOriginX and cardX <= stack.frameOriginX + stack.baseWidth, "cards are pulled to the front")
end

effectsStayOnTheFrontTest()

-- half way through a turn to the right the middle of the view is the middle of the right panel of the pair,
-- also when the turn crosses the seam
local function viewFollowsTheTurnTest()
  local stack = createStack(true)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  local center = stack.frameOriginX + stack.baseWidth / 2
  for _, column in ipairs({5, 18}) do
    engine.cur_col = column
    engine.rotationTimer = 2
    engine.rotationDirection = 1
    local x = renderer:popEffectOrigin(column % engine.width + 1, engine.cur_row)
    assert(x and math.abs(x + 8 - center) < 1e-6, "turning right from column " .. column)
  end
end

viewFollowsTheTurnTest()

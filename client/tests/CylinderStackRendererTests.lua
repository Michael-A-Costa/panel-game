local ClientMatch = require("client.src.ClientMatch")
local GameModes = require("common.data.GameModes")
local Player = require("client.src.Player")
local GeneratorSource = require("common.engine.GeneratorSource")
local LevelPresets = require("common.data.LevelPresets")

---@param gameModeId GameModeID
---@return PlayerStack
local function createStack(gameModeId)
  local player = Player.createLocalPlayerFromConfig()
  player.isLocal = false
  player:setLevel(5)
  player:setLevelData(LevelPresets.getModern(5))
  player:setStyle(GameModes.Styles.MODERN)
  player:setInputMethod("controller")
  player.playerNumber = 1
  local match = ClientMatch.createFromGameMode({player}, GameModes.getPreset(gameModeId), GeneratorSource(1, false), false)
  match:start()
  return match.stacks[1]
end

local function onlyCylinderStacksGetTheRenderer()
  assert(createStack(GameModes.IDs.ONE_PLAYER_ENDLESS_3D).cylinderRenderer, "a 3D stack should draw as a tower")
  assert(createStack(GameModes.IDs.ONE_PLAYER_ENDLESS).cylinderRenderer == nil, "a 2D stack keeps the flat well")
end

onlyCylinderStacksGetTheRenderer()

local function cursorPairIsCentredOnTheTower()
  local stack = createStack(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  local center = stack.frameOriginX + stack.baseWidth / 2
  local row = engine.cur_row

  local leftX = renderer:popEffectOrigin(engine.cur_col, row)
  local rightX = renderer:popEffectOrigin(engine.cur_col % engine.width + 1, row)
  assert(leftX and rightX, "the cursor pair is on the front")
  assert(math.abs((leftX + rightX) / 2 - (center - 8)) < 1e-6, "the pair straddles the centre of the tower")

  local cursorX, cursorWidth = renderer:getCursorPlacement()
  assert(math.abs(stack.frameOriginX + cursorX + cursorWidth / 2 - center) < 1e-6, "the cursor sits at the centre")
  assert(cursorWidth > rightX - leftX, "the cursor covers the pair")
end

cursorPairIsCentredOnTheTower()

local function effectsStayOnTheFront()
  local stack = createStack(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  -- half way round the ring from the cursor is the back of the tower
  local backColumn = (engine.cur_col + engine.width / 2 - 1) % engine.width + 1
  assert(renderer:popEffectOrigin(backColumn, 5) == nil, "no explosions on the back")
  local cardX = renderer:cardOrigin(backColumn, 5)
  assert(cardX >= stack.frameOriginX and cardX <= stack.frameOriginX + stack.baseWidth, "cards are pulled to the front")
end

effectsStayOnTheFront()

local function rotationMovesTheViewSmoothly()
  local stack = createStack(GameModes.IDs.ONE_PLAYER_ENDLESS_3D)
  local renderer = stack.cylinderRenderer
  ---@cast renderer CylinderStackRenderer
  local engine = stack.engine
  local center = stack.frameOriginX + stack.baseWidth / 2
  local rightColumn = engine.cur_col % engine.width + 1

  -- half way through a turn to the right the right panel of the pair faces the camera
  engine.rotationTimer = 2
  engine.rotationDirection = 1
  local x = renderer:popEffectOrigin(rightColumn, engine.cur_row)
  assert(x and math.abs(x + 8 - center) < 1e-6, "the view centre follows getCylinderViewCenter")
  engine.rotationTimer = 0
  engine.rotationDirection = 0
end

rotationMovesTheViewSmoothly()

local class = require("common.lib.class")
local consts = require("common.engine.consts")
local system = require("client.src.system")
local prof = require("common.lib.zoneProfiler")

-- Draws a cylinder stack as Pokémon Puzzle League's 3D tower (docs/3d-mode/SPEC.md §7).
-- Every quad is rebuilt each frame from the stack state, so rollback and rewind need nothing extra.
-- Like PPL it paints back to front instead of using a depth buffer: back walls, back faces, front walls, front faces.
-- The groups never overlap among themselves, so within a group quads are batched per texture in any order.

local sin, cos, min, rad = math.sin, math.cos, math.min, math.rad

-- camera of Draw3DTetris (src/main/draw3d.c): guPerspective(33°, 0.88, 10, 3000), eye at (0, 0, 900) looking at the origin
local FIELD_OF_VIEW = rad(33)
local ASPECT = 0.88
local NEAR = 10
local FAR = 3000
local EYE_DISTANCE = 900
local FOCAL = 1 / math.tan(FIELD_OF_VIEW / 2)

-- tower geometry of src/assets/vertex/cylinder_3d.c in PPL model units
local COLUMN_COUNT = consts.CYLINDER_WIDTH
local COLUMN_ANGLE = rad(360 / COLUMN_COUNT)
local OUTER_RADIUS = 81
local INNER_RADIUS = 66
local OUTER_FACE_HEIGHT = 33
local INNER_FACE_HEIGHT = 32
local ROW_HEIGHT = 32
-- bottom edge of Panel Attack's row 1 (PPL row 0); the incoming row 0 sits one row lower at -240
local ROW_ONE_BOTTOM = -208
-- back panels show their inner face at vertex colour 100/255
local BACK_BRIGHTNESS = 100 / 255

-- a face points at the eye if the eye is in front of its plane; the planes are chords, cos(half a column) from the radius
local OUTER_FACING = OUTER_RADIUS * cos(COLUMN_ANGLE / 2) / EYE_DISTANCE
local INNER_FACING = INNER_RADIUS * cos(COLUMN_ANGLE / 2) / EYE_DISTANCE

-- Panel Attack draws rows 16 units tall; scale PPL's projection so rows on the front of the tower keep that height
-- and line up with the flat cursor, the HUD and the 2D row positions
local PANEL_SIZE = 16
local INTRO_ROWS = 6
local UNITS_PER_NDC_Y = PANEL_SIZE * (EYE_DISTANCE - OUTER_RADIUS) / (ROW_HEIGHT * FOCAL)
local MODEL_TO_UNITS_Y = UNITS_PER_NDC_Y * FOCAL
-- PPL maps normalized device coordinates onto its 4:3 screen, stretching the tower to about 1.5 times the width of a
-- true cylinder. At this row height that is 113 units, wider than the theme frame and the HUD placed around it, so the
-- silhouette is scaled to the 96 unit wide 2D well instead: still stretched, 14% less than in PPL.
local WELL_WIDTH = 96
local SILHOUETTE_SLOPE = OUTER_RADIUS / math.sqrt(EYE_DISTANCE * EYE_DISTANCE - OUTER_RADIUS * OUTER_RADIUS)
local MODEL_TO_UNITS_X = WELL_WIDTH / 2 / SILHOUETTE_SLOPE
local UNITS_PER_NDC_X = MODEL_TO_UNITS_X * ASPECT / FOCAL

-- PPL draws explosions only on the 8 front columns and combo/chain icons only on the middle 6 (src/main/explode3d.c)
local POP_EFFECT_MAX_ANGLE = 4 * COLUMN_ANGLE
local CARD_MAX_ANGLE = 2.5 * COLUMN_ANGLE

-- the cursor sprite overlaps the pair by the same share as in 2D, where it is 40 units wide over 32
local CURSOR_WIDTH_PER_PAIR = 40 / 32

-- the glass tube around the tower; PPL has its own art for it, this is a plain stand-in drawn with primitives
local TUBE_RADIUS = 86
local TUBE_COLORS = {
  {base = {0.16, 0.36, 0.86}, light = {0.56, 0.76, 1}, dark = {0.05, 0.13, 0.42}},
  {base = {0.84, 0.16, 0.16}, light = {1, 0.62, 0.56}, dark = {0.42, 0.05, 0.05}},
}

local VERTEX_FORMAT
if system.meetsLoveVersionRequirement(12, 0) then
  VERTEX_FORMAT = {
    {location = 0, format = "floatvec3"},
    {location = 1, format = "floatvec2"},
    {location = 2, format = "unorm8vec4"},
  }
else
  VERTEX_FORMAT = {
    {"VertexPosition", "float", 3},
    {"VertexTexCoord", "float", 2},
    {"VertexColor", "byte", 4},
  }
end

local SHADER_CODE = [[
uniform mat4 cylinderClip;
// xy: where the eye lands on the stack, zw: stack units per unit of normalized device coordinates
uniform vec4 screenMap;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vec4 clip = cylinderClip * vertex_position;
  // stays homogeneous (no divide by w) so the GPU keeps texturing perspective-correct
  vec4 stackPosition = vec4(screenMap.x * clip.w + screenMap.z * clip.x, screenMap.y * clip.w - screenMap.w * clip.y, 0.0, clip.w);
  return transform_projection * stackPosition;
}
]]

---@type love.Shader?
local shader

---@return love.Shader
local function getShader()
  if not shader then
    shader = love.graphics.newShader(SHADER_CODE)
    local depthScale = (FAR + NEAR) / (NEAR - FAR)
    local depthOffset = 2 * FAR * NEAR / (NEAR - FAR)
    -- perspective times the view translation to the eye at z = 900
    shader:send("cylinderClip", "row", {
      {FOCAL / ASPECT, 0, 0, 0},
      {0, FOCAL, 0, 0},
      {0, 0, depthScale, depthOffset - depthScale * EYE_DISTANCE},
      {0, 0, -1, EYE_DISTANCE},
    })
  end
  return shader
end

local QUADS_PER_MESH = 64

---@param capacity integer number of quads
---@return love.Mesh
local function newQuadMesh(capacity)
  local mesh = love.graphics.newMesh(VERTEX_FORMAT, capacity * 4, "triangles", "stream")
  local vertexMap = {}
  for quad = 0, capacity - 1 do
    local first = quad * 4
    vertexMap[#vertexMap + 1] = first + 1
    vertexMap[#vertexMap + 1] = first + 2
    vertexMap[#vertexMap + 1] = first + 3
    vertexMap[#vertexMap + 1] = first + 1
    vertexMap[#vertexMap + 1] = first + 3
    vertexMap[#vertexMap + 1] = first + 4
  end
  mesh:setVertexMap(vertexMap)
  return mesh
end

-- The quads of one paint layer sharing a texture, kept in a persistent mesh that is refilled every frame
---@class CylinderQuadBatch
---@field texture love.Texture?
---@field mesh love.Mesh
---@field capacity integer how many quads the mesh can hold
---@field count integer how many quads were added this frame

-- One painter's layer of the tower
---@class CylinderLayer
---@field batches CylinderQuadBatch[] in order of first use
---@field batchByTexture table<love.Texture|false, CylinderQuadBatch> untextured quads are keyed by false

---@return CylinderLayer
local function newLayer()
  return {batches = {}, batchByTexture = {}}
end

---@param layer CylinderLayer
local function clearLayer(layer)
  for i = 1, #layer.batches do
    layer.batches[i].count = 0
  end
end

---@param batch CylinderQuadBatch
local function growBatch(batch)
  local capacity = batch.capacity * 2
  local mesh = newQuadMesh(capacity)
  for vertex = 1, batch.count * 4 do
    mesh:setVertex(vertex, batch.mesh:getVertex(vertex))
  end
  if batch.texture then
    mesh:setTexture(batch.texture)
  end
  batch.mesh:release()
  batch.mesh = mesh
  batch.capacity = capacity
end

---@param layer CylinderLayer
---@param texture love.Texture?
---@return CylinderQuadBatch
local function getBatch(layer, texture)
  local key = texture or false
  local batch = layer.batchByTexture[key]
  if not batch then
    batch = {texture = texture, mesh = newQuadMesh(QUADS_PER_MESH), capacity = QUADS_PER_MESH, count = 0}
    if texture then
      batch.mesh:setTexture(texture)
    end
    layer.batches[#layer.batches + 1] = batch
    layer.batchByTexture[key] = batch
  elseif batch.count == batch.capacity then
    growBatch(batch)
  end
  return batch
end

---@param layer CylinderLayer
local function drawLayer(layer)
  for i = 1, #layer.batches do
    local batch = layer.batches[i]
    if batch.count > 0 then
      batch.mesh:setDrawRange(1, batch.count * 6)
      love.graphics.draw(batch.mesh)
    end
  end
end

-- adds a textured chord quad between two angles of the ring; angles run from the camera axis toward screen right
---@param layer CylinderLayer
---@param texture love.Texture
---@param startAngle number
---@param endAngle number
---@param radius number
---@param bottom number
---@param height number
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param brightness number
local function addFace(layer, texture, startAngle, endAngle, radius, bottom, height, u0, v0, u1, v1, brightness)
  local batch = getBatch(layer, texture)
  local mesh = batch.mesh
  local vertex = batch.count * 4
  local x0, z0 = radius * sin(startAngle), radius * cos(startAngle)
  local x1, z1 = radius * sin(endAngle), radius * cos(endAngle)
  local top = bottom + height
  mesh:setVertex(vertex + 1, x0, bottom, z0, u0, v1, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 2, x1, bottom, z1, u1, v1, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 3, x1, top, z1, u1, v0, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 4, x0, top, z0, u0, v0, brightness, brightness, brightness, 1)
  batch.count = batch.count + 1
end

-- adds the flat coloured side wall between an outer and an inner face along one column edge
---@param layer CylinderLayer
---@param angle number
---@param bottom number
---@param color number[]
local function addWall(layer, angle, bottom, color)
  local batch = getBatch(layer, nil)
  local mesh = batch.mesh
  local vertex = batch.count * 4
  local s, c = sin(angle), cos(angle)
  local r, g, b = color[1], color[2], color[3]
  mesh:setVertex(vertex + 1, INNER_RADIUS * s, bottom, INNER_RADIUS * c, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 2, OUTER_RADIUS * s, bottom, OUTER_RADIUS * c, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 3, OUTER_RADIUS * s, bottom + OUTER_FACE_HEIGHT, OUTER_RADIUS * c, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 4, INNER_RADIUS * s, bottom + INNER_FACE_HEIGHT, INNER_RADIUS * c, 0, 0, r, g, b, 1)
  batch.count = batch.count + 1
end

-- angle of a column's left edge relative to the screen centre, wrapped into [-180°, 180°)
---@param column integer
---@param viewCenter number
---@param width integer
---@return number
local function columnStartAngle(column, viewCenter, width)
  local offset = (column - 1 - viewCenter) % width
  if offset >= width / 2 then
    offset = offset - width
  end
  return offset * COLUMN_ANGLE
end

-- UV rectangle of one frame on a panel sheet, pulled in by half a texel so filtering never picks up the neighbour frame
---@param texture love.Texture
---@param size number frame size in texture units
---@param frameColumn integer
---@param frameRow integer
---@return number u0
---@return number v0
---@return number u1
---@return number v1
local function sheetFrame(texture, size, frameColumn, frameRow)
  local width, height = texture:getDimensions()
  local pixelWidth, pixelHeight = texture:getPixelDimensions()
  local insetU, insetV = 0.5 / pixelWidth, 0.5 / pixelHeight
  local u0 = (frameColumn - 1) * size / width
  local v0 = (frameRow - 1) * size / height
  return u0 + insetU, v0 + insetV, u0 + size / width - insetU, v0 + size / height - insetV
end

---@param panel Panel
---@return boolean # if the cell hides the side walls of its neighbours
local function occupiesCell(panel)
  return panel.color ~= 0 and panel.state ~= "popped" and panel.state ~= "swapping"
end

local function shouldFlashForFrame(frame)
  local flashFrames = 2
  return frame % (flashFrames * 2) < flashFrames
end

-- the side walls get a flat dark tone per colour like PPL's (src/main/draw3d.c Draw3DTetrisBlockSide);
-- Panel Attack's panel sets differ in colour, so the tone is taken from the panel set's own normal frame
---@type table<Panels, number[][]>
local sideColorCache = setmetatable({}, {__mode = "k"})
local SIDE_BRIGHTNESS = 0.42

---@param panelSet Panels
---@return number[][]
local function getSideColors(panelSet)
  local colors = sideColorCache[panelSet]
  if colors then
    return colors
  end

  colors = {}
  local size = math.max(1, math.floor(panelSet.size))
  local canvas = love.graphics.newCanvas(size, size, {dpiscale = 1})
  for color = 1, 8 do
    love.graphics.push("all")
    love.graphics.reset()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    panelSet:drawPanelFrame(color, "normal", 0, 0, size)
    love.graphics.pop()

    local imageData
    if system.meetsLoveVersionRequirement(12, 0) then
      imageData = love.graphics.readbackTexture(canvas)
    else
      ---@diagnostic disable-next-line: undefined-field
      imageData = canvas:newImageData()
    end
    local red, green, blue, weight = 0, 0, 0, 0
    for y = 0, size - 1 do
      for x = 0, size - 1 do
        local r, g, b, a = imageData:getPixel(x, y)
        red, green, blue, weight = red + r * a, green + g * a, blue + b * a, weight + a
      end
    end
    imageData:release()
    weight = math.max(weight, 1e-6)
    red, green, blue = red / weight, green / weight, blue / weight
    -- normalise to one brightness so every colour reads as a shaded side, whatever the art's own lightness
    local scale = SIDE_BRIGHTNESS / math.max(red, green, blue, 1e-6)
    colors[color] = {red * scale, green * scale, blue * scale}
  end
  canvas:release()
  -- grey panels (colour 9) use PPL's default side tone
  colors[9] = {68 / 255, 68 / 255, 68 / 255}

  sideColorCache[panelSet] = colors
  return colors
end

---@class CylinderStackRenderer
---@field stack PlayerStack
---@field backWalls CylinderLayer
---@field backFaces CylinderLayer
---@field frontWalls CylinderLayer
---@field frontFaces CylinderLayer
---@field screenMap number[] persistent uniform value so a frame allocates nothing
---@field centerX number x of the tower's axis relative to the stack frame
---@field tubeHalfWidth number half the on-screen width of the glass tube
---@overload fun(stack: PlayerStack): CylinderStackRenderer
local CylinderStackRenderer = class(
---@param self CylinderStackRenderer
---@param stack PlayerStack
function(self, stack)
  assert(stack.engine.width == COLUMN_COUNT, "the 3D tower expects " .. COLUMN_COUNT .. " columns")
  self.stack = stack
  self.backWalls = newLayer()
  self.backFaces = newLayer()
  self.frontWalls = newLayer()
  self.frontFaces = newLayer()
  self.screenMap = {0, 0, UNITS_PER_NDC_X, UNITS_PER_NDC_Y}
  self.centerX = stack.baseWidth / 2
  -- the tube's silhouette: the tangent from the eye to a circle of TUBE_RADIUS
  self.tubeHalfWidth = MODEL_TO_UNITS_X * TUBE_RADIUS / math.sqrt(EYE_DISTANCE * EYE_DISTANCE - TUBE_RADIUS * TUBE_RADIUS)
end)

-- like PPL's blue and red tubes the colour follows the side of the screen
---@return {base: number[], light: number[], dark: number[]}
function CylinderStackRenderer:getTubeColors()
  return TUBE_COLORS[self.stack.renderIndex] or TUBE_COLORS[1]
end

-- y of the eye level (model y = 0) relative to the stack frame; rising moves the whole projected tower like PPL's
-- screen space translation, so it rides on the displacement
---@return number
function CylinderStackRenderer:eyeLevel()
  local stack = self.stack
  return stack.panelOriginYOffset + (stack.engine.height - 1) * PANEL_SIZE + ROW_ONE_BOTTOM * PANEL_SIZE / ROW_HEIGHT
      + stack.engine.displacement + self:introDrop()
end

-- PPL's 3D countdown raises the tower from INTRO_ROWS rows low into place over its first frames (DoCountDown.s);
-- the engine keeps the board where it is, so the rise is drawn here from the countdown clock
---@return number
function CylinderStackRenderer:introDrop()
  local countdownTimer = self.stack.engine.countdown_timer
  if not countdownTimer then
    return 0
  end
  local countdownFrame = consts.COUNTDOWN_LENGTH - countdownTimer
  if countdownFrame >= consts.CYLINDER_INTRO_FRAMES then
    return 0
  end
  return (consts.CYLINDER_INTRO_FRAMES - countdownFrame) / consts.CYLINDER_INTRO_FRAMES * INTRO_ROWS * PANEL_SIZE
end

---@param texture love.Texture
---@param startAngle number
---@param endAngle number
---@param bottom number
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
---@param frontOnly boolean
function CylinderStackRenderer:addCellFace(texture, startAngle, endAngle, bottom, u0, v0, u1, v1, frontOnly)
  local facing = cos((startAngle + endAngle) / 2)
  if facing > OUTER_FACING then
    addFace(self.frontFaces, texture, startAngle, endAngle, OUTER_RADIUS, bottom, OUTER_FACE_HEIGHT, u0, v0, u1, v1, 1)
  elseif facing < INNER_FACING and not frontOnly then
    -- the inner face keeps u running with the angle, so seen through a gap the back panel is mirrored as in PPL
    addFace(self.backFaces, texture, startAngle, endAngle, INNER_RADIUS, bottom, INNER_FACE_HEIGHT, u0, v0, u1, v1,
            BACK_BRIGHTNESS)
  end
end

---@param panelSet Panels
---@param panel Panel
---@param startAngle number
---@param bottom number
---@param frontOnly boolean
function CylinderStackRenderer:addPanel(panelSet, panel, startAngle, bottom, frontOnly)
  local stack = self.stack
  if panel.color == 9 then
    self:addCellFace(panelSet.greyPanel, startAngle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, frontOnly)
  else
    local conf, frame, swapOffset = panelSet:getDrawProps(panel, 0, 0, stack.danger_col, stack.danger_timer,
                                                          stack.engine.stop_time)
    if conf then
      local sheet = panelSet.sheets[panel.color]
      local u0, v0, u1, v1 = sheetFrame(sheet, panelSet.size, frame, conf.row)
      -- a swap slides the panel along the surface: the 2D offset of 4 units per frame becomes 5° per frame
      local angle = startAngle + swapOffset / PANEL_SIZE * COLUMN_ANGLE
      self:addCellFace(sheet, angle, angle + COLUMN_ANGLE, bottom, u0, v0, u1, v1, frontOnly)
    end
  end
end

-- shock garbage is built from 8 unit wide pieces in 2D: caps at both ends of the block, middle pieces in between
---@param left love.Texture
---@param right love.Texture
---@param startAngle number
---@param bottom number
function CylinderStackRenderer:addHalves(left, right, startAngle, bottom)
  local middle = startAngle + COLUMN_ANGLE / 2
  self:addCellFace(left, startAngle, middle, bottom, 0, 0, 1, 1, false)
  self:addCellFace(right, middle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
end

-- The 2D renderer draws a garbage block in one piece from its bottom right panel; here every cell shows its own piece
-- of the same prerendered texture, so blocks that wrap around the ring continue across the seam.
---@param panel Panel
---@param startAngle number
---@param bottom number
---@param garbageCharacter Character
---@param metalPanelSet Panels
---@param panelSet Panels
function CylinderStackRenderer:addGarbage(panel, startAngle, bottom, garbageCharacter, metalPanelSet, panelSet)
  local metals = metalPanelSet.images.metals
  if panel.state == "matched" then
    local flashTime = panel.initial_time - panel.timer
    if flashTime < self.stack.engine.levelData.frameConstants.FLASH then
      if shouldFlashForFrame(flashTime) then
        local flashImage = panel.metal and metals.flash or garbageCharacter.images.flash
        self:addCellFace(flashImage, startAngle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
      elseif panel.metal then
        self:addHalves(metals.left, metals.right, startAngle, bottom)
      else
        self:addCellFace(garbageCharacter.images.pop, startAngle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
      end
      return
    elseif panel.timer > panel.pop_time then
      if panel.metal then
        self:addHalves(metals.left, metals.right, startAngle, bottom)
      else
        self:addCellFace(garbageCharacter.images.pop, startAngle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
      end
      return
    elseif panel.y_offset == -1 then
      -- the bottom row turns into panels
      self:addPanel(panelSet, panel, startAngle, bottom, false)
      return
    end
    -- the rows above have already shrunk into the remaining block and draw as part of it
  end

  if panel.metal then
    local left = panel.x_offset == 0 and metals.left or metals.mid
    local right = panel.x_offset == panel.width - 1 and metals.right or metals.mid
    self:addHalves(left, right, startAngle, bottom)
  else
    -- as in 2D, chain garbage taller than the board shares a texture with a block of matching filler pattern
    local drawHeight = min(panel.height, 28 + panel.height % 4)
    if panel.y_offset >= drawHeight then
      return
    end
    -- a full ring has no ends: cut it from a texture two panels wider so the side borders fall outside
    local fullRing = panel.width >= COLUMN_COUNT
    local textureWidth = fullRing and panel.width + 2 or panel.width
    local textureColumn = fullRing and panel.x_offset + 1 or panel.x_offset
    local texture = garbageCharacter:getGarbageTexture(textureWidth, drawHeight)
    local u0 = textureColumn / textureWidth
    local v0 = (drawHeight - 1 - panel.y_offset) / drawHeight
    self:addCellFace(texture, startAngle, startAngle + COLUMN_ANGLE, bottom, u0, v0, u0 + 1 / textureWidth,
                     v0 + 1 / drawHeight, false)
  end
end

-- PPL draws a side wall where a gap next to a panel lets the camera see along the panel's edge
---@param panelRow Panel[]
---@param panel Panel
---@param startAngle number
---@param bottom number
---@param sideColors number[][]
function CylinderStackRenderer:addWalls(panelRow, panel, startAngle, bottom, sideColors)
  local color = sideColors[panel.color]
  if not color then
    return
  end
  -- a wall faces the camera when the camera is on its side of the plane through the axis
  if sin(startAngle) > 0 and not occupiesCell(panelRow[(panel.column - 2) % COLUMN_COUNT + 1]) then
    addWall(cos(startAngle) >= 0 and self.frontWalls or self.backWalls, startAngle, bottom, color)
  end
  local endAngle = startAngle + COLUMN_ANGLE
  if sin(endAngle) < 0 and not occupiesCell(panelRow[panel.column % COLUMN_COUNT + 1]) then
    addWall(cos(endAngle) >= 0 and self.frontWalls or self.backWalls, endAngle, bottom, color)
  end
end

-- Draws the tower's panels and garbage, relative to the stack frame
---@param garbageCharacter Character
---@param metalPanelSet Panels
---@param shakeOffset number
function CylinderStackRenderer:drawTower(garbageCharacter, metalPanelSet, shakeOffset)
  prof.push("CylinderStackRenderer:drawTower")
  local stack = self.stack
  local engine = stack.engine
  local panelSet = panels[stack.panels_dir]
  local sideColors = getSideColors(panelSet)
  local viewCenter = engine:getCylinderViewCenter()

  clearLayer(self.backWalls)
  clearLayer(self.backFaces)
  clearLayer(self.frontWalls)
  clearLayer(self.frontFaces)

  for row = 0, engine.height do
    local panelRow = engine.panels[row]
    local bottom = ROW_ONE_BOTTOM + (row - 1) * ROW_HEIGHT
    -- like PPL's incoming row, row 0 is only drawn on the front
    local frontOnly = row == 0
    for column = 1, COLUMN_COUNT do
      local panel = panelRow[column]
      if panel.color ~= 0 and panel.state ~= "popped" then
        local startAngle = columnStartAngle(column, viewCenter, COLUMN_COUNT)
        if panel.isGarbage then
          self:addGarbage(panel, startAngle, bottom, garbageCharacter, metalPanelSet, panelSet)
        else
          self:addPanel(panelSet, panel, startAngle, bottom, frontOnly)
          if not frontOnly and panel.state ~= "swapping" then
            self:addWalls(panelRow, panel, startAngle, bottom, sideColors)
          end
        end
      end
    end
  end

  local screenMap = self.screenMap
  screenMap[1] = self.centerX
  screenMap[2] = self:eyeLevel() - shakeOffset
  local towerShader = getShader()
  towerShader:send("screenMap", screenMap)

  love.graphics.push("transform")
  love.graphics.scale(stack.gfxScale)
  love.graphics.setShader(towerShader)
  drawLayer(self.backWalls)
  drawLayer(self.backFaces)
  drawLayer(self.frontWalls)
  drawLayer(self.frontFaces)
  love.graphics.setShader()
  love.graphics.pop()
  prof.pop("CylinderStackRenderer:drawTower")
end

-- Clips to the inside of the tube and translates to the stack frame, the counterpart of ClientStack:setDrawArea.
-- Undo with ClientStack:resetDrawArea.
---@param xOffset integer? additional x offset, e.g. from a translation, as scissors work in canvas coordinates
---@param yOffset integer? additional y offset
function CylinderStackRenderer:setDrawArea(xOffset, yOffset)
  local stack = self.stack
  local scale = stack.gfxScale
  local left = stack.frameOriginX + self.centerX - self.tubeHalfWidth
  love.graphics.setScissor((xOffset or 0) + left * scale, (yOffset or 0) + stack.frameOriginY * scale,
                           2 * self.tubeHalfWidth * scale, stack.baseHeight * scale)
  love.graphics.push("transform")
  love.graphics.translate(stack.frameOriginX * scale, stack.frameOriginY * scale)
end

-- the inside of the tube: darkens the stage behind the tower so the dim back panels still read
function CylinderStackRenderer:drawTubeBack()
  local scale = self.stack.gfxScale
  local dark = self:getTubeColors().dark
  love.graphics.setColor(dark[1] * 0.3, dark[2] * 0.3, dark[3] * 0.3, 0.55)
  love.graphics.rectangle("fill", (self.centerX - self.tubeHalfWidth) * scale, 0, 2 * self.tubeHalfWidth * scale,
                          self.stack.baseHeight * scale)
  love.graphics.setColor(1, 1, 1, 1)
end

-- glass highlights and the caps at the top and bottom of the tube; lifts the clip because the caps reach past it
function CylinderStackRenderer:drawTubeFront()
  local stack = self.stack
  local colors = self:getTubeColors()
  local base, light, dark = colors.base, colors.light, colors.dark
  local halfWidth = self.tubeHalfWidth
  local left = self.centerX - halfWidth
  -- the base stands where the 2D wall is drawn, covering the incoming row the same way
  local bottom = stack.panelOriginYOffset + stack.engine.height * PANEL_SIZE

  love.graphics.setScissor()
  love.graphics.push("transform")
  love.graphics.scale(stack.gfxScale)

  -- glass edges and a soft reflection
  love.graphics.setColor(light[1], light[2], light[3], 0.5)
  love.graphics.rectangle("fill", left - 1, 0, 2, bottom)
  love.graphics.rectangle("fill", left + 2 * halfWidth - 1, 0, 2, bottom)
  love.graphics.setColor(1, 1, 1, 0.1)
  love.graphics.rectangle("fill", left + halfWidth * 0.18, 0, halfWidth * 0.12, bottom)
  love.graphics.setColor(1, 1, 1, 0.05)
  love.graphics.rectangle("fill", left + halfWidth * 0.34, 0, halfWidth * 0.05, bottom)

  -- top cap: a band with the underside of its rim showing below it; it stays below the frame's top edge because
  -- the opponent's telegraph is drawn above it before this stack
  local capLeft = left - 4
  local capWidth = 2 * halfWidth + 8
  local capTop = -2
  local capBottom = stack.panelOriginYOffset + 1
  love.graphics.setColor(dark[1], dark[2], dark[3], 1)
  love.graphics.ellipse("fill", self.centerX, capBottom, halfWidth + 3, 3.5)
  love.graphics.setColor(base[1], base[2], base[3], 1)
  love.graphics.rectangle("fill", capLeft, capTop, capWidth, capBottom - capTop, 3, 3)
  love.graphics.setColor(light[1], light[2], light[3], 1)
  love.graphics.rectangle("fill", capLeft + 3, capTop + 1, capWidth - 6, 1.5, 0.75, 0.75)

  -- bottom cap: a band with the top of its rim seen from above
  love.graphics.setColor(base[1], base[2], base[3], 1)
  love.graphics.rectangle("fill", capLeft, bottom - 1, capWidth, 12, 4, 4)
  love.graphics.setColor(dark[1], dark[2], dark[3], 1)
  love.graphics.rectangle("fill", capLeft + 2, bottom + 8, capWidth - 4, 2, 1, 1)
  love.graphics.setColor(light[1], light[2], light[3], 1)
  love.graphics.ellipse("fill", self.centerX, bottom - 1, halfWidth + 3, 4)
  love.graphics.setColor(base[1], base[2], base[3], 1)
  love.graphics.ellipse("fill", self.centerX, bottom - 1, halfWidth, 2.5)

  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.pop()
end

-- Where the flat cursor goes: centred over the pair at the screen centre of the tower, it never moves sideways (SPEC §2)
---@return number x left edge relative to the stack frame
---@return number width
function CylinderStackRenderer:getCursorPlacement()
  -- the pair spans one column either side of the centre at the front of the tower
  local x = OUTER_RADIUS * sin(COLUMN_ANGLE)
  local depth = EYE_DISTANCE - OUTER_RADIUS * cos(COLUMN_ANGLE)
  local width = 2 * MODEL_TO_UNITS_X * x / depth * CURSOR_WIDTH_PER_PAIR
  return self.centerX - width / 2, width
end

-- Projects the centre of a cell's outer face, ignoring shake like the 2D effects do
---@param column integer
---@param row integer
---@param maxAngle number
---@param clamp boolean if a cell beyond maxAngle is pulled to the nearest allowed column instead of hidden
---@return number? x centre in unscaled canvas units, nil if hidden
---@return number? y
function CylinderStackRenderer:projectFrontCell(column, row, maxAngle, clamp)
  local stack = self.stack
  local engine = stack.engine
  local angle = columnStartAngle(column, engine:getCylinderViewCenter(), COLUMN_COUNT) + COLUMN_ANGLE / 2
  if angle > maxAngle or angle < -maxAngle then
    if not clamp then
      return nil, nil
    end
    angle = angle > 0 and maxAngle or -maxAngle
  end
  local depth = EYE_DISTANCE - OUTER_RADIUS * cos(angle)
  local y = ROW_ONE_BOTTOM + (row - 0.5) * ROW_HEIGHT
  local x = self.centerX + MODEL_TO_UNITS_X * OUTER_RADIUS * sin(angle) / depth
  y = self:eyeLevel() - MODEL_TO_UNITS_Y * y / depth
  return stack.frameOriginX + x, stack.frameOriginY + y
end

-- Top left corner of a 16 unit box around a front cell for pop effects; nil on the back of the tower
---@param column integer
---@param row integer
---@return number? x in unscaled canvas units
---@return number? y
function CylinderStackRenderer:popEffectOrigin(column, row)
  local x, y = self:projectFrontCell(column, row, POP_EFFECT_MAX_ANGLE, false)
  if x then
    return x - PANEL_SIZE / 2, y - PANEL_SIZE / 2
  end
  return nil, nil
end

-- Top left corner of a 16 unit box for a combo/chain card or attack origin, always on the middle columns
---@param column integer
---@param row integer
---@return number x in unscaled canvas units
---@return number y
function CylinderStackRenderer:cardOrigin(column, row)
  local x, y = self:projectFrontCell(column, row, CARD_MAX_ANGLE, true)
  ---@cast x number
  ---@cast y number
  return x - PANEL_SIZE / 2, y - PANEL_SIZE / 2
end

return CylinderStackRenderer

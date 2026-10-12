local class = require("common.lib.class")
local consts = require("common.engine.consts")
local system = require("client.src.system")
local prof = require("common.lib.zoneProfiler")

-- Draws a cylinder stack as the tower of Pokémon Puzzle League's 3D mode, with its camera and geometry.
-- Everything is rebuilt from the stack state each frame, so rollback and rewind need nothing extra.
-- Like the original it paints back to front instead of using a depth buffer: back walls, back faces, front walls,
-- front faces. Quads within one of these layers never overlap, so a layer is batched per texture.

local sin, cos, min, rad = math.sin, math.cos, math.min, math.rad

-- the tower in Pokémon Puzzle League's model units (cylinder_3d.c, draw3d.c)
local COLUMN_COUNT = consts.CYLINDER_WIDTH
local COLUMN_ANGLE = rad(360 / COLUMN_COUNT)
local OUTER_RADIUS = 81
local INNER_RADIUS = 66
local OUTER_FACE_HEIGHT = 33
local INNER_FACE_HEIGHT = 32
local ROW_HEIGHT = 32
-- bottom edge of row 1
local ROW_ONE_BOTTOM = -208
local EYE_DISTANCE = 900
-- back panels show their inner face at vertex color 100/255
local BACK_BRIGHTNESS = 100 / 255

-- a face points at the eye if the eye is in front of its plane; the planes are chords, cos(half a column) from the axis
local OUTER_FACING = OUTER_RADIUS * cos(COLUMN_ANGLE / 2) / EYE_DISTANCE
local INNER_FACING = INNER_RADIUS * cos(COLUMN_ANGLE / 2) / EYE_DISTANCE

-- The projection is scaled so that rows on the front are as tall as Panel Attack's rows and the tower is as wide as
-- the 2D well, which lines it up with the cursor and the HUD around it. The original stretches the tower sideways to
-- 1.5 times its true width; at this row height that would be wider than the well, so it is stretched 14% less.
-- With these scales the original's field of view and aspect ratio drop out.
local PANEL_SIZE = 16
local WELL_WIDTH = 96
local MODEL_TO_UNITS_Y = PANEL_SIZE * (EYE_DISTANCE - OUTER_RADIUS) / ROW_HEIGHT

-- the slope of the tangent from the eye to a circle around the tower's axis, where the circle's silhouette is
---@param radius number
---@return number
local function silhouetteSlope(radius)
  return radius / math.sqrt(EYE_DISTANCE * EYE_DISTANCE - radius * radius)
end

local MODEL_TO_UNITS_X = WELL_WIDTH / 2 / silhouetteSlope(OUTER_RADIUS)

-- screen offset from the tower's axis and distance from the eye of a point on the outer surface
---@param angle number
---@return number x
---@return number depth
local function projectOuter(angle)
  local depth = EYE_DISTANCE - OUTER_RADIUS * cos(angle)
  return MODEL_TO_UNITS_X * OUTER_RADIUS * sin(angle) / depth, depth
end

-- explosions only show on the 8 front columns and combo/chain cards on the middle 6 (explode3d.c)
local POP_EFFECT_MAX_ANGLE = 4 * COLUMN_ANGLE
local CARD_MAX_ANGLE = 2.5 * COLUMN_ANGLE

-- the flat cursor sprite stays centred on the front pair and overlaps it as in 2D, where it is 40 units wide over 32
local CURSOR_WIDTH = 2 * projectOuter(COLUMN_ANGLE) * 40 / 32

-- a plain glass tube around the tower in place of the theme's frame, which is narrower than the tower
local TUBE_HALF_WIDTH = MODEL_TO_UNITS_X * silhouetteSlope(86)
local TUBE_COLORS = {
  {base = {0.16, 0.36, 0.86}, light = {0.56, 0.76, 1}, dark = {0.05, 0.13, 0.42}},
  {base = {0.84, 0.16, 0.16}, light = {1, 0.62, 0.56}, dark = {0.42, 0.05, 0.05}},
}

-- the tower rises from this many rows low during the countdown (DoCountDown.s)
local INTRO_ROWS = 6

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

-- vertices hold x and y around the tower's axis and their distance from the eye as z
local SHADER_CODE = [[
// xy: where the axis is at eye level, zw: units per model unit at a distance of 1
uniform vec4 screenMap;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  float depth = vertex_position.z;
  // no divide by depth here so the GPU keeps texturing perspective-correct
  vec4 screenPosition = vec4(screenMap.x * depth + screenMap.z * vertex_position.x,
                             screenMap.y * depth - screenMap.w * vertex_position.y, 0.0, depth);
  return transform_projection * screenPosition;
}
]]

---@type love.Shader?
local shader

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

-- the quads of a layer that share a texture, in a mesh that is kept and refilled every frame
---@class CylinderQuadBatch
---@field texture love.Texture?
---@field mesh love.Mesh
---@field capacity integer how many quads the mesh can hold
---@field count integer how many quads were added this frame

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

-- the batch to add the next quad with this texture to
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

-- adds a textured quad on the chord between two angles; angles run from the camera axis toward screen right
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
  local x0, depth0 = radius * sin(startAngle), EYE_DISTANCE - radius * cos(startAngle)
  local x1, depth1 = radius * sin(endAngle), EYE_DISTANCE - radius * cos(endAngle)
  local top = bottom + height
  mesh:setVertex(vertex + 1, x0, bottom, depth0, u0, v1, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 2, x1, bottom, depth1, u1, v1, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 3, x1, top, depth1, u1, v0, brightness, brightness, brightness, 1)
  mesh:setVertex(vertex + 4, x0, top, depth0, u0, v0, brightness, brightness, brightness, 1)
  batch.count = batch.count + 1
end

-- adds the flat colored side wall between an outer and an inner face along one column edge
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
  local innerDepth, outerDepth = EYE_DISTANCE - INNER_RADIUS * c, EYE_DISTANCE - OUTER_RADIUS * c
  mesh:setVertex(vertex + 1, INNER_RADIUS * s, bottom, innerDepth, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 2, OUTER_RADIUS * s, bottom, outerDepth, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 3, OUTER_RADIUS * s, bottom + OUTER_FACE_HEIGHT, outerDepth, 0, 0, r, g, b, 1)
  mesh:setVertex(vertex + 4, INNER_RADIUS * s, bottom + INNER_FACE_HEIGHT, innerDepth, 0, 0, r, g, b, 1)
  batch.count = batch.count + 1
end

-- the board column in the middle of the view, fractional while the tower turns;
-- column c spans [c - 1, c), so at rest the middle is cur_col, between the cursor's two panels
---@param engine Stack
---@return number
local function getViewCenter(engine)
  local progress = (consts.CYLINDER_ROTATION_FRAMES - engine.rotationTimer) / consts.CYLINDER_ROTATION_FRAMES
  return engine.cur_col + engine.rotationDirection * progress
end

-- angle of a column's left edge from the middle of the view, wrapped into [-180°, 180°)
---@param column integer
---@param viewCenter number
---@return number
local function columnStartAngle(column, viewCenter)
  local offset = (column - 1 - viewCenter) % COLUMN_COUNT
  if offset >= COLUMN_COUNT / 2 then
    offset = offset - COLUMN_COUNT
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

-- The side walls get a flat dark tone per color like the original's. Panel sets differ in color, so the tone is
-- taken from the panel set's own normal frame.
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
    -- one brightness for all so every color reads as a shaded side, however light the art is
    local scale = SIDE_BRIGHTNESS / math.max(red, green, blue, 1e-6)
    colors[color] = {red * scale, green * scale, blue * scale}
  end
  canvas:release()
  -- the original's side tone for grey panels
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
---@field screenMap number[] kept so that sending the uniform allocates nothing
---@field centerX number x of the tower's axis in the stack frame
---@overload fun(stack: PlayerStack): CylinderStackRenderer
local CylinderStackRenderer = class(
---@param self CylinderStackRenderer
---@param stack PlayerStack
function(self, stack)
  self.stack = stack
  self.backWalls = newLayer()
  self.backFaces = newLayer()
  self.frontWalls = newLayer()
  self.frontFaces = newLayer()
  self.screenMap = {0, 0, MODEL_TO_UNITS_X, MODEL_TO_UNITS_Y}
  self.centerX = stack.baseWidth / 2
end)

-- blue for player 1 and red for player 2, like the original's tubes
---@return {base: number[], light: number[], dark: number[]}
function CylinderStackRenderer:getTubeColors()
  return TUBE_COLORS[self.stack.renderIndex]
end

-- y of the eye level in the stack frame; the whole tower rises with the stack like in the original
---@return number
function CylinderStackRenderer:eyeLevel()
  local stack = self.stack
  return stack.panelOriginYOffset + (stack.engine.height - 1) * PANEL_SIZE + ROW_ONE_BOTTOM * PANEL_SIZE / ROW_HEIGHT
      + stack.engine.displacement + self:introDrop()
end

-- the countdown raises the tower into place while the engine turns it
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
    -- u keeps running with the angle, so seen through a gap the back panel is mirrored as in the original
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
      -- the 2D swap offset of 4 units per frame becomes 5° per frame along the surface
      local angle = startAngle + swapOffset / PANEL_SIZE * COLUMN_ANGLE
      self:addCellFace(sheet, angle, angle + COLUMN_ANGLE, bottom, u0, v0, u1, v1, frontOnly)
    end
  end
end

-- metal garbage is drawn in half panel pieces as in 2D
---@param left love.Texture
---@param right love.Texture
---@param startAngle number
---@param bottom number
function CylinderStackRenderer:addHalves(left, right, startAngle, bottom)
  local middle = startAngle + COLUMN_ANGLE / 2
  self:addCellFace(left, startAngle, middle, bottom, 0, 0, 1, 1, false)
  self:addCellFace(right, middle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
end

-- 2D draws a garbage block in one piece; here every cell shows its part of the same texture, so blocks wrapping
-- around the seam continue across it
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
    local flashing = flashTime < self.stack.engine.levelData.frameConstants.FLASH
    if flashing and flashTime % 4 < 2 then
      local flashImage = panel.metal and metals.flash or garbageCharacter.images.flash
      self:addCellFace(flashImage, startAngle, startAngle + COLUMN_ANGLE, bottom, 0, 0, 1, 1, false)
      return
    elseif flashing or panel.timer > panel.pop_time then
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
    -- the rows above have shrunk into the remaining block and draw as part of it
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
    local fullRing = panel.width == COLUMN_COUNT
    local textureWidth = fullRing and panel.width + 2 or panel.width
    local textureColumn = fullRing and panel.x_offset + 1 or panel.x_offset
    local texture = garbageCharacter:getGarbageTexture(textureWidth, drawHeight)
    local u0 = textureColumn / textureWidth
    local v0 = (drawHeight - 1 - panel.y_offset) / drawHeight
    self:addCellFace(texture, startAngle, startAngle + COLUMN_ANGLE, bottom, u0, v0, u0 + 1 / textureWidth,
                     v0 + 1 / drawHeight, false)
  end
end

-- side walls show where a gap next to a panel lets the camera see along its edge
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

-- draws the tower's panels and garbage in the stack frame
---@param garbageCharacter Character
---@param metalPanelSet Panels
---@param shakeOffset number
function CylinderStackRenderer:drawTower(garbageCharacter, metalPanelSet, shakeOffset)
  prof.push("CylinderStackRenderer:drawTower")
  local stack = self.stack
  local engine = stack.engine
  local panelSet = panels[stack.panels_dir]
  local sideColors = getSideColors(panelSet)
  local viewCenter = getViewCenter(engine)

  clearLayer(self.backWalls)
  clearLayer(self.backFaces)
  clearLayer(self.frontWalls)
  clearLayer(self.frontFaces)

  for row = 0, engine.height do
    local panelRow = engine.panels[row]
    local bottom = ROW_ONE_BOTTOM + (row - 1) * ROW_HEIGHT
    -- like the original's incoming row, row 0 is only drawn on the front
    local frontOnly = row == 0
    for column = 1, COLUMN_COUNT do
      local panel = panelRow[column]
      if panel.color ~= 0 and panel.state ~= "popped" then
        local startAngle = columnStartAngle(column, viewCenter)
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
  shader = shader or love.graphics.newShader(SHADER_CODE)
  shader:send("screenMap", screenMap)

  love.graphics.push("transform")
  love.graphics.scale(stack.gfxScale)
  love.graphics.setShader(shader)
  drawLayer(self.backWalls)
  drawLayer(self.backFaces)
  drawLayer(self.frontWalls)
  drawLayer(self.frontFaces)
  love.graphics.setShader()
  love.graphics.pop()
  prof.pop("CylinderStackRenderer:drawTower")
end

-- ClientStack:setDrawArea for the tower: clips to the inside of the tube instead of the frame
---@param xOffset integer?
---@param yOffset integer?
function CylinderStackRenderer:setDrawArea(xOffset, yOffset)
  local stack = self.stack
  local scale = stack.gfxScale
  local left = stack.frameOriginX + self.centerX - TUBE_HALF_WIDTH
  love.graphics.setScissor((xOffset or 0) + left * scale, (yOffset or 0) + stack.frameOriginY * scale,
                           2 * TUBE_HALF_WIDTH * scale, stack.baseHeight * scale)
  love.graphics.push("transform")
  love.graphics.translate(stack.frameOriginX * scale, stack.frameOriginY * scale)
end

-- darkens the stage behind the tower so the dim back panels still read
function CylinderStackRenderer:drawTubeBack()
  local scale = self.stack.gfxScale
  local dark = self:getTubeColors().dark
  love.graphics.setColor(dark[1] * 0.3, dark[2] * 0.3, dark[3] * 0.3, 0.55)
  love.graphics.rectangle("fill", (self.centerX - TUBE_HALF_WIDTH) * scale, 0, 2 * TUBE_HALF_WIDTH * scale,
                          self.stack.baseHeight * scale)
  love.graphics.setColor(1, 1, 1, 1)
end

-- glass highlights and the caps at the top and bottom of the tube; lifts the clip because the caps reach past it
function CylinderStackRenderer:drawTubeFront()
  local stack = self.stack
  local colors = self:getTubeColors()
  local base, light, dark = colors.base, colors.light, colors.dark
  local halfWidth = TUBE_HALF_WIDTH
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

  -- top cap: a band with the underside of its rim below it; it stays below the frame's top edge because
  -- the opponent's telegraph is drawn there before this stack
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

---@return number x left edge in the stack frame
---@return number width
function CylinderStackRenderer:getCursorPlacement()
  return self.centerX - CURSOR_WIDTH / 2, CURSOR_WIDTH
end

-- projects the middle of a cell's outer face, without shake like the 2D effects
---@param column integer
---@param row integer
---@param maxAngle number
---@param clamp boolean if a cell beyond maxAngle is pulled in to it instead of hidden
---@return number? x in unscaled canvas units, nil if hidden
---@return number? y
function CylinderStackRenderer:projectFrontCell(column, row, maxAngle, clamp)
  local stack = self.stack
  local angle = columnStartAngle(column, getViewCenter(stack.engine)) + COLUMN_ANGLE / 2
  if angle > maxAngle or angle < -maxAngle then
    if not clamp then
      return nil, nil
    end
    angle = angle > 0 and maxAngle or -maxAngle
  end
  local x, depth = projectOuter(angle)
  local y = ROW_ONE_BOTTOM + (row - 0.5) * ROW_HEIGHT
  return stack.frameOriginX + (self.centerX + x), stack.frameOriginY + (self:eyeLevel() - MODEL_TO_UNITS_Y * y / depth)
end

-- top left corner of a panel sized box for pop effects; nil on the back of the tower
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

-- top left corner of a panel sized box for combo and chain cards and attack origins, always on the middle columns
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

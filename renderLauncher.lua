---@diagnostic disable: duplicate-set-field
-- Dev harness for the stack renderers: builds local matches from the game mode presets, scripts them into set states
-- and writes screenshots, without menus or input devices.
-- Like testLauncher.lua it relies on love 12 running the lua file passed as first argument in place of main.lua:
--   love ./renderLauncher.lua [outputDirectory]       scripted 3D and 2D match shots
--   love ./renderLauncher.lua game [outputDirectory]  boots the real game and captures it after a few seconds
--   love ./renderLauncher.lua live                    runs a 2P 3D match on screen for a few seconds and prints the fps
-- Screenshots are 1280x720 PNGs written to outputDirectory (absolute path) or "renderShots" in the save directory.
-- It opens a window and plays audio like the game; run it under xvfb-run with SDL_AUDIO_DRIVER=dummy and
-- ALSOFT_DRIVERS=null (as CI runs the tests) to keep both off your desktop.

require("common.lib.mathExtensions")
local util = require("common.lib.util")
util.addToCPath("./common/lib/??")
local logger = require("common.lib.logger")
logger.setLogLevel(logger.levels.INFO)

local mode = "shots"
if arg[2] == "game" or arg[2] == "live" then
  mode = arg[2]
end
local outputDirectory = mode == "shots" and arg[2] or arg[3]

local function savePng(imageData, name)
  local fileData = imageData:encode("png")
  if outputDirectory then
    local path = outputDirectory .. "/" .. name
    local file = assert(io.open(path, "wb"))
    file:write(fileData:getString())
    file:close()
    print("wrote " .. path)
  else
    love.filesystem.createDirectory("renderShots")
    love.filesystem.write("renderShots/" .. name, fileData)
    print("wrote " .. love.filesystem.getSaveDirectory() .. "/renderShots/" .. name)
  end
end

if mode == "game" then
  -- boot the real game through main.lua and capture what it shows once it settled, then skip any first-run setup
  -- scenes (language, input, community) and capture the main menu
  require("main")
  local gameDraw = love.draw
  local start
  local step = 1
  love.draw = function()
    gameDraw()
    start = start or love.timer.getTime()
    local elapsed = love.timer.getTime() - start
    if step == 1 and elapsed > 4 then
      savePng(love.graphics.readbackTexture(GAME.globalCanvas), "game_boot.png")
      local navigationStack = GAME.navigationStack
      for i = #navigationStack.scenes, 2, -1 do
        navigationStack.scenes[i] = nil
      end
      navigationStack:replace(require("client.src.scenes.MainMenu")())
      step = 2
    elseif step == 2 and elapsed > 7 then
      savePng(love.graphics.readbackTexture(GAME.globalCanvas), "game_main_menu.png")
      love.event.quit()
    end
  end
  return
end

require("client.src.globals")
local Game = require("client.src.Game")
local consts = require("common.engine.consts")
local GameModes = require("common.data.GameModes")
local LevelPresets = require("common.data.LevelPresets")
local GeneratorSource = require("common.engine.GeneratorSource")
local KeyDataEncoding = require("common.data.KeyDataEncoding")
local ClientMatch = require("client.src.ClientMatch")
local Player = require("client.src.Player")

local IDLE = KeyDataEncoding.base64encode[1]
local SWAP = KeyDataEncoding.base64encode[16 + 1]
local LEFT = KeyDataEncoding.base64encode[2 + 1]
local RIGHT = KeyDataEncoding.right

function love.load()
  GAME = Game()
  GAME:load()
  GAME.muteSound = true

  local cr = coroutine.create(GAME.setupRoutine)
  while coroutine.status(cr) ~= "dead" do
    local success, status = coroutine.resume(cr, GAME)
    if not success then
      GAME.crashTrace = debug.traceback(cr)
      error(status)
    end
  end
  -- renderers pick sprites per frame on the clock, keep the shots deterministic
  config.popfx = true
  config.renderTelegraph = true
  config.renderAttacks = true
end

---@param gameModeId GameModeID
---@param playerCount integer
---@param sceneName string
---@param withCountdown boolean? play the countdown (and the 3D tower's intro) instead of starting right away
---@return ClientMatch match
---@return GameBase scene
local function createMatch(gameModeId, playerCount, sceneName, withCountdown)
  local gameMode = GameModes.getPreset(gameModeId)
  local players = {}
  for i = 1, playerCount do
    local player = Player.createLocalPlayerFromConfig()
    -- inputs come from the script instead of devices
    player.isLocal = false
    player.name = "P" .. i
    player:setLevel(5)
    player:setLevelData(LevelPresets.getModern(5))
    player:setStyle(GameModes.Styles.MODERN)
    player:setInputMethod("controller")
    player.playerNumber = i
    players[#players + 1] = player
  end

  local match = ClientMatch.createFromGameMode(players, gameMode, GeneratorSource(4242, false), false)
  match.engine:setCountdown(withCountdown == true)
  match:start()
  for _, stack in ipairs(match.stacks) do
    stack:setMaxRunsPerFrame(1)
  end
  local scene = require("client.src.scenes." .. sceneName)({match = match})
  scene:load()
  return match, scene
end

---@param match ClientMatch
---@param frames integer
---@param inputsByFrame table<integer, string[]>? per stack index: inputs by frame offset (1-based), idle when missing
local function runFrames(match, frames, inputsByFrame)
  for frame = 1, frames do
    for i, stack in ipairs(match.stacks) do
      local input = inputsByFrame and inputsByFrame[i] and inputsByFrame[i][frame] or IDLE
      stack:receiveConfirmedInput(input)
    end
    match:run()
  end
end

-- a board without accidental matches: neighbours differ horizontally and vertically
---@param engine Stack
---@param rows integer
---@param skip (fun(row: integer, column: integer): boolean)? cells to leave empty
local function fillBoard(engine, rows, skip)
  for row = 1, #engine.panels do
    for column = 1, engine.width do
      local panel = engine.panels[row][column]
      panel:clear(true, true)
      if row <= rows and not (skip and skip(row, column)) then
        panel.color = (column + 2 * row) % 5 + 1
      end
    end
  end
end

local garbageId = 1000

---@param engine Stack
---@param row integer bottom row
---@param startColumn integer left column; the block wraps around the ring
---@param width integer
---@param height integer
---@param metal boolean?
local function placeGarbage(engine, row, startColumn, width, height, metal)
  garbageId = garbageId + 1
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local panel = engine.panels[row + y][(startColumn - 1 + x) % engine.width + 1]
      panel:clear(true, true)
      panel.color = 9
      panel.isGarbage = true
      panel.metal = metal
      panel.garbageId = garbageId
      panel.x_offset = x
      panel.y_offset = y
      panel.width = width
      panel.height = height
      panel.shake_time = 0
    end
  end
end

---@param stack PlayerStack
---@param timer integer frames left in the rotation step
---@param direction integer
local function setRotation(stack, timer, direction)
  stack.engine.rotationTimer = timer
  stack.engine.rotationDirection = direction
end

-- swapping the cursor pair (columns 9 and 10, row 3) makes a 5 combo: columns 7-9 of row 3 and rows 3-5 of column 9
---@param engine Stack
local function setUpCombo(engine)
  fillBoard(engine, 6)
  engine.cur_row = 3
  engine.cur_col = 9
  engine.panels[3][6].color = 5
  engine.panels[3][7].color = 3
  engine.panels[3][8].color = 3
  engine.panels[3][9].color = 1
  engine.panels[3][10].color = 3
  engine.panels[4][9].color = 3
  engine.panels[5][9].color = 3
end

-- a 6x2 garbage block on columns 7-12 resting on 3 rows; swapping the pair (columns 10 and 11, row 3) matches
-- columns 8-10 of row 3 right under it
---@param engine Stack
local function setUpGarbageClear(engine)
  fillBoard(engine, 3)
  placeGarbage(engine, 4, 7, 6, 2)
  engine.cur_row = 3
  engine.cur_col = 10
  engine.panels[3][7].color = 5
  engine.panels[3][8].color = 3
  engine.panels[3][9].color = 3
  engine.panels[3][10].color = 1
  engine.panels[3][11].color = 3
  engine.panels[3][12].color = 2
end

-- each shot prepares a match state and returns the scene to draw
local shots = {
  {
    name = "3d_1p_endless_start.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 90)
      return scene
    end
  },
  {
    -- halfway through turning right: view centre half a column right of the cursor
    name = "3d_1p_rotation.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 90)
      setRotation(match.stacks[1], 2, 1)
      return scene
    end
  },
  {
    -- gaps in the front rows let the back panels' inner faces show through, with side walls next to the gaps
    name = "3d_1p_back_faces.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 10, function(row, column)
        return row >= 4 and (column + row) % 3 == 0
      end)
      return scene
    end
  },
  {
    -- swap at the cursor pair, two frames in: both panels cross at the centre
    name = "3d_1p_swap.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 7)
      engine.cur_row = 5
      engine.panels[5][engine.cur_col].color = 1
      engine.panels[5][engine.cur_col + 1].color = 5
      runFrames(match, 3, {{SWAP}})
      return scene
    end
  },
  {
    -- a 5 combo (3 across, 3 down) right of the cursor, flashing
    name = "3d_1p_match_flash.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      setUpCombo(engine)
      runFrames(match, 20, {{SWAP}})
      return scene
    end
  },
  {
    -- the same combo popping, with pop effects and the combo card on the front
    name = "3d_1p_match_pop.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      setUpCombo(engine)
      local frames = 1
      repeat
        runFrames(match, 1, frames == 1 and {{SWAP}} or nil)
        frames = frames + 1
      until engine.panels[5][9].state == "popped" or frames > 200
      return scene
    end
  },
  {
    -- a match under a 2 row garbage block: the block flashes
    name = "3d_1p_garbage_clear_flash.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      setUpGarbageClear(match.stacks[1].engine)
      runFrames(match, 12, {{SWAP}})
      return scene
    end
  },
  {
    -- later: the bottom row of the block turns into panels while the rest of the block shrinks back
    name = "3d_1p_garbage_clear_reveal.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      setUpGarbageClear(engine)
      local frames = 1
      repeat
        runFrames(match, 1, frames == 1 and {{SWAP}} or nil)
        frames = frames + 1
        local corner = engine.panels[4][12]
      until (corner.isGarbage and corner.state == "matched" and corner.timer <= corner.pop_time) or frames > 300
      runFrames(match, 8)
      return scene
    end
  },
  {
    -- garbage: a 6 wide block wrapping the seam, a 12 wide block, a full ring and shock garbage
    name = "3d_1p_garbage.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 3)
      placeGarbage(engine, 4, 15, 6, 1)
      placeGarbage(engine, 4, 3, 4, 1, true)
      placeGarbage(engine, 5, 12, 12, 1)
      placeGarbage(engine, 6, 1, 18, 2)
      placeGarbage(engine, 8, 17, 5, 3)
      return scene
    end
  },
  {
    -- the same garbage seen after turning the tower a quarter turn and a bit, so the wrapped blocks are on the side
    name = "3d_1p_garbage_turned.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 3)
      placeGarbage(engine, 4, 15, 6, 1)
      placeGarbage(engine, 4, 3, 4, 1, true)
      placeGarbage(engine, 5, 12, 12, 1)
      placeGarbage(engine, 6, 1, 18, 2)
      placeGarbage(engine, 8, 17, 5, 3)
      engine.cur_col = 8
      setRotation(match.stacks[1], 3, -1)
      return scene
    end
  },
  {
    -- stack near the top: danger bounce
    name = "3d_1p_danger.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 11, function(row, column)
        return row >= 9 and column % 4 == 0
      end)
      runFrames(match, 9)
      return scene
    end
  },
  {
    name = "3d_1p_time_attack.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_TIME_ATTACK_3D, 1, "TimeAttackGame")
      runFrames(match, 200)
      return scene
    end
  },
  {
    -- two towers, P2 mid-rotation, garbage of 6, 12 and 18 wide on its way to P2 in the telegraph
    name = "3d_2p_vs.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.TWO_PLAYER_VS_3D, 2, "GameBase")
      runFrames(match, 120)
      local p1 = match.stacks[1].engine
      local clock = p1.clock
      p1.outgoingGarbage:push({width = 6, height = 1, isMetal = false, isChain = false, frameEarned = clock - 70,
                               rowEarned = 6, colEarned = 3})
      p1.outgoingGarbage:push({width = 12, height = 1, isMetal = false, isChain = false, frameEarned = clock - 69,
                               rowEarned = 6, colEarned = 3})
      p1.outgoingGarbage:push({width = 18, height = 2, isMetal = false, isChain = true, frameEarned = clock - 68,
                               rowEarned = 6, colEarned = 3})
      placeGarbage(match.stacks[2].engine, 9, 16, 6, 1)
      setRotation(match.stacks[2], 2, -1)
      return scene
    end
  },
  {
    name = "2d_endless.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS, 1, "EndlessGame")
      runFrames(match, 90)
      return scene
    end
  },
  -- the live_ shots get everything from the engine's 3D rules and scripted inputs; nothing is placed by hand
  -- beyond a starting board
  {
    -- PPL's countdown intro, 20 frames in: the tower rises into the tube from 6 rows low while it turns left
    name = "live_3d_intro.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame", true)
      runFrames(match, 20)
      return scene
    end
  },
  {
    -- two frames after a Left press: the tower is half a column into its turn, the cursor stays in front
    name = "live_3d_turning.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      runFrames(match, 2, {{LEFT}})
      return scene
    end
  },
  {
    -- with the cursor on columns 1 and 2, swapping them lines up columns 17, 18 and 1: a match across the seam
    name = "live_3d_seam_match.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_ENDLESS_3D, 1, "EndlessGame")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 6)
      -- fillBoard's row 1 has 4 on column 16 and 1 on column 3, so 5s on 17, 18 and 2 only match once column 1 is a 5
      engine.panels[1][17].color = 5
      engine.panels[1][18].color = 5
      engine.panels[1][1].color = 2
      engine.panels[1][2].color = 5
      engine.cur_row = 1
      engine.cur_col = 1
      runFrames(match, 12, {{SWAP}})
      return scene
    end
  },
  {
    -- garbage of a x3 chain (12 wide) and a x4 chain (full ring) arriving on P1: both drop in front of the player
    -- and wrap around the back of the tower
    name = "live_3d_chain_garbage.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.TWO_PLAYER_VS_3D, 2, "GameBase")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 4)
      engine.incomingGarbage:push({width = 6, height = 2, isChain = true, isMetal = false, frameEarned = 0,
                                   rowEarned = 1, colEarned = 1})
      engine.incomingGarbage:push({width = 6, height = 3, isChain = true, isMetal = false, frameEarned = 0,
                                   rowEarned = 1, colEarned = 1})
      runFrames(match, 120)
      return scene
    end
  },
  {
    -- 1P vs yourself on the tower: a 5 combo sends its garbage to the same stack, where it drops in front
    name = "live_3d_vs_self_garbage.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.ONE_PLAYER_VS_SELF_3D, 1, "VsSelfGame")
      runFrames(match, 30)
      setUpCombo(match.stacks[1].engine)
      runFrames(match, 240, {{SWAP}})
      return scene
    end
  },
  {
    -- the same garbage after P1 held Left for a while: landed garbage turns with the tower
    name = "live_3d_chain_garbage_turned.png",
    prepare = function()
      local match, scene = createMatch(GameModes.IDs.TWO_PLAYER_VS_3D, 2, "GameBase")
      runFrames(match, 30)
      local engine = match.stacks[1].engine
      fillBoard(engine, 4)
      engine.incomingGarbage:push({width = 6, height = 2, isChain = true, isMetal = false, frameEarned = 0,
                                   rowEarned = 1, colEarned = 1})
      engine.incomingGarbage:push({width = 6, height = 3, isChain = true, isMetal = false, frameEarned = 0,
                                   rowEarned = 1, colEarned = 1})
      runFrames(match, 120)
      local holdLeft = {}
      for frame = 1, 34 do
        holdLeft[frame] = LEFT
      end
      runFrames(match, 34, {holdLeft})
      return scene
    end
  },
}

local canvas
local shotIndex = 0
local currentScene
local perfMeasured = {}

-- CPU time and garbage of drawing the stacks of a scene, the part the 3D renderer adds to
---@param scene GameBase
local function measurePerformance(scene)
  local runs = 300
  -- warm up first so LuaJIT's trace compilation doesn't count as per frame garbage
  for _ = 1, runs do
    for _, stack in ipairs(scene.match.stacks) do
      stack:render(false)
    end
  end
  collectgarbage("collect")
  collectgarbage("stop")
  local memoryBefore = collectgarbage("count")
  local start = love.timer.getTime()
  for _ = 1, runs do
    for _, stack in ipairs(scene.match.stacks) do
      stack:render(false)
    end
  end
  local elapsed = love.timer.getTime() - start
  local memoryAfter = collectgarbage("count")
  collectgarbage("restart")
  print(string.format("perf: %d stacks, %.3f ms CPU per frame to draw, %.2f KB allocated per frame",
                      #scene.match.stacks, elapsed / runs * 1000, (memoryAfter - memoryBefore) / runs))
end

if mode == "live" then
  local LIVE_SECONDS = 5
  local liveMatch, liveScene
  local frameTimes = {}
  local liveStart

  function love.update()
    if not liveMatch then
      liveMatch, liveScene = createMatch(GameModes.IDs.TWO_PLAYER_VS_3D, 2, "GameBase")
      liveStart = love.timer.getTime()
    end
    -- P1 holds Left and P2 holds Right so both towers keep turning and every frame rebuilds rotated geometry
    runFrames(liveMatch, 1, {{LEFT}, {RIGHT}})
    if love.timer.getTime() - liveStart > LIVE_SECONDS then
      table.sort(frameTimes)
      print(string.format("live: %d frames in %.1f s, %.1f fps, median frame %.2f ms, slowest %.2f ms",
                          #frameTimes, LIVE_SECONDS - 0.5, #frameTimes / (LIVE_SECONDS - 0.5),
                          frameTimes[math.ceil(#frameTimes / 2)] * 1000, frameTimes[#frameTimes] * 1000))
      love.event.quit()
    end
  end

  function love.draw()
    if liveScene then
      liveScene:draw()
      -- the first frames include loading the match assets
      if love.timer.getTime() - liveStart > 0.5 then
        frameTimes[#frameTimes + 1] = love.timer.getDelta()
      end
    end
  end
  return
end

function love.update()
  shotIndex = shotIndex + 1
  if shots[shotIndex] then
    currentScene = shots[shotIndex].prepare()
  end
end

function love.draw()
  local shot = shots[shotIndex]
  if not shot then
    love.event.quit()
    return
  end
  canvas = canvas or love.graphics.newCanvas(consts.CANVAS_WIDTH, consts.CANVAS_HEIGHT, {dpiscale = 1})
  love.graphics.setCanvas({canvas, stencil = true})
  love.graphics.clear(0, 0, 0, 1)
  currentScene:draw()
  if (shot.name == "3d_2p_vs.png" or shot.name == "2d_endless.png") and not perfMeasured[shot.name] then
    perfMeasured[shot.name] = true
    measurePerformance(currentScene)
    love.graphics.clear(0, 0, 0, 1)
    currentScene:draw()
  end
  love.graphics.setCanvas()
  savePng(love.graphics.readbackTexture(canvas), shot.name)
  currentScene.match:deinit()
end

function love.errorhandler(msg)
  print(debug.traceback("render harness failed: " .. tostring(msg), 2))
  os.exit(1)
end

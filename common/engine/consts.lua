--[[
   TODO:
   consts is currently kind of the "all over the place" collection
   it should get split into 
   1. constants decisively important for the engine
   2. constants decisively important for the client
]]
require("common.lib.util")
local tableUtils = require("common.lib.tableUtils")

local consts = {
  CANVAS_WIDTH = 1280,
  CANVAS_HEIGHT = 720,
  DEFAULT_THEME_DIR = "Panel Attack",
  RANDOM_CHARACTER_SPECIAL_VALUE = "__RandomCharacter",
  RANDOM_STAGE_SPECIAL_VALUE = "__RandomStage",
  MOUSE_POINTER_TIMEOUT = 1.5, --seconds
  KEY_NAMES = {"Up", "Down", "Left", "Right", "Swap1", "Swap2", "TauntUp", "TauntDown", "Raise1", "Raise2", "Start"},
  FRAME_RATE = 1 / 60,
  KEY_DELAY = .25,
  KEY_REPEAT_PERIOD = .05,
  MENU_PADDING = 10
}

-- The values in this file are constants (except in this file perhaps) and are expected never to change during the game, not to be confused with globals!

consts.ENGINE_VERSIONS = {}
consts.ENGINE_VERSIONS.PRE_TELEGRAPH = "045"
consts.ENGINE_VERSIONS.TELEGRAPH_COMPATIBLE = "046"
consts.ENGINE_VERSIONS.TOUCH_COMPATIBLE = "047"
consts.ENGINE_VERSIONS.LEVELDATA = "048"
consts.ENGINE_VERSIONS.WIGGLE_PUNISH = "049"

consts.ENGINE_VERSION = consts.ENGINE_VERSIONS.WIGGLE_PUNISH -- The current engine version
consts.VERSION_MIN_VIEW = consts.ENGINE_VERSIONS.LEVELDATA -- The lowest version number that can be watched
-- Matches on the 3D cylinder record this instead of ENGINE_VERSION so that clients without it refuse their replays rather
-- than play them 6 wide: it sorts after every numeric version ("3" > "0"), which is what replayCanBeViewed compares.
-- 2D matches keep ENGINE_VERSION.
consts.ENGINE_VERSIONS.CYLINDER = "3d-049"

consts.COUNTDOWN_CURSOR_SPEED = 4 --one move every this many frames
consts.COUNTDOWN_START = 8
consts.COUNTDOWN_LENGTH = 180 --3 seconds at 60 fps

consts.PUZZLES_SAVE_DIRECTORY = "puzzles"
consts.PUZZLES_LOAD_DIRECTORY = "client/assets/default_data/puzzles"

consts.SERVER_SAVE_DIRECTORY = "servers/"
consts.LEGACY_SERVER_LOCATION = "18.188.43.50"
consts.SERVER_LOCATION = "panelattack.com"

consts.SUPER_SELECTION_DURATION = 0.5 -- seconds
consts.SUPER_SELECTION_START = 0.1 -- time held at which super enable is considered started

consts.DEFAULT_THEME_DIRECTORY = "Panel Attack Modern"

consts.SCOREMODE_TA    = 1
consts.SCOREMODE_PDP64 = 2 -- currently not used

-- Yes, 2 is slower than 1 and 50..99 are the same.
consts.SPEED_TO_RISE_TIME = tableUtils.map(
   {942, 983, 838, 790, 755, 695, 649, 604, 570, 515,
    474, 444, 394, 370, 347, 325, 306, 289, 271, 256,
    240, 227, 213, 201, 189, 178, 169, 158, 148, 138,
    129, 120, 112, 105,  99,  92,  86,  82,  77,  73,
     69,  66,  62,  59,  56,  54,  52,  50,  48,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47,  47,
     47,  47,  47,  47,  47,  47,  47,  47,  47},
     function(x) return x/16 end)

-- Pokémon Puzzle League's 2P VS pace, played by stacks with the pplVersus setup modification
-- (docs/cpu-ai/STADIUM-SPEC.md §2 "Speed during a match"); both tables verbatim from the decomp.
-- st_RaiseTimer: its values are 16ths of a frame per row, so /256 gives frames per displacement step
consts.PPL_SPEED_TO_RISE_TIME = tableUtils.map(
  {15376, 14576, 12976, 12336, 11696, 10800, 10064, 9328, 8752, 7936,
    7280,  6784,  5968,  5584,  5232,  4896,  4592, 4304, 4032, 3776,
    3536,  3312,  3104,  2912,  2720,  2544,  2384, 2224, 2064, 1904,
    1760,  1616,  1488,  1376,  1280,  1168,  1072, 1008,  928,  864,
     800,   752,   688,   640,   592,   560,   528,  496,  464,  448,
     432,   416,   400,   384,   368,   356,   344,  332,  320,  308,
     296,   288,   280,   272,   264,   256,   248,  244,  240,  236,
     232,   228,   224,   220,   216,   212,   208,  204,  200,  196,
     192,   188,   184,   180,   176,   172,   168,  164,  160,  156,
     152,   148,   144,   140,   136,   134,   132,  130,  128},
     function(x) return x/256 end)

-- st_AdvanceLevel: frames until the next speed increase, by speed levels gained so far (the last entry repeats)
consts.PPL_SPEED_INCREASE_FRAMES = {
  900, 900, 900, 900, 600, 600, 600, 600, 540, 540, 540, 540, 480, 480, 480, 480, 420, 420, 420, 420,
  420, 420, 420, 420, 360, 360, 360, 360, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300}

-- Stage clear seems to use a variant of vs mode's speed system,
-- except that the amount of time between increases is not constant.
-- on stage 1, the increases occur at increments of:
-- 20, 15, 15, 15, 10, 10, 10

consts.ATTACK_TYPE = { combo=0, chain=1, shock=2 }

-- Pokémon Puzzle League's 3D tower (docs/3d-mode/SPEC.md §1-2)
consts.CYLINDER_WIDTH = 18
consts.CYLINDER_ROTATION_FRAMES = 4 -- frames to turn the tower by one column
-- once a held direction's first delay is over PPL repeats it every 3 frames (controller.c), not every frame
consts.CYLINDER_INPUT_REPEAT_FRAMES = 3
-- 0-based view column of the cursor's left panel; view columns count around the tower from its left silhouette (0),
-- so 1-8 face the player
consts.CYLINDER_CURSOR_VIEW_COLUMN = 4
-- countdown frames of PPL's 3D intro, in which the tower rises from 6 rows low and turns left a column at a time
-- (DoCountDown.s: translation starts at -0.768 and gains 0.016 per frame)
consts.CYLINDER_INTRO_FRAMES = 48

return consts
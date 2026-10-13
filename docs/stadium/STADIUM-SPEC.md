# 1P Stadium spec (Pokémon Puzzle League)

What Pokémon Puzzle League (N64) does in 1P Stadium, its ladder against CPU opponents, read from the matching decomp
[AngheloAlf/puzzleleague64](https://github.com/AngheloAlf/puzzleleague64), and how this fork could build it on Panel
Attack. Companion docs: `docs/3d-mode/SPEC.md` (rules shared with VS, garbage), `docs/stadium/INTEGRATION.md` (where a
CPU and a new mode plug into this codebase). The CPU's internal algorithm (`ai.c`) is documented separately; this doc
only records which parameters each stage hands it.

Citations are paths inside the decomp repo, USA version. Tags: **[R]** read directly in matched C, asm or data.
**[R, draft]** read in an m2c draft of unmatched asm (`#if 0` blocks in `src/` or drafts made from
`asm/usa/nonmatchings/...`). **[I]** inferred from code. **[U]** memory of the game, unverified. **[W]** web source
(URL given); the decomp wins where they disagree.

Internal names used below: the mode is `gSelection == SELECTION_96` (2P VS is `SELECTION_A0`). `gTheGame.menu[0]`
holds the run: `.game` = difficulty 1–5, `.stage` = ladder position 1–16 (plus the special values 0x11–0x13 in §3),
`.speed` = continues used, `.misc` = the player's Pokémon pick (`include/menu_t.h`). The save fields are named in the
GameCube DWARF (`player_t` in `/Users/mcosta/projects/decomp-tools/puzzle_collection_dwarf/PANEPON_dwarf.h:59624`):
`kPLAYER1V_kEASY/kNORMAL/kHARD/kSHARD/kULTRA` and `kPLAYER1V_k*_continue`.

## 1. Ladder

### Difficulties

| `game` | Save name | Player-facing [W] | Stages | Last opponent | Ending |
|---|---|---|---|---|---|
| 1 | kEASY | Easy | 11 | Giovanni | `ENDING-1` screen |
| 2 | kNORMAL | Normal | 14 | Bruno | `ENDING-2` screen |
| 3 | kHARD | Hard | 15 | Gary (2nd time) | `GAMEEND.HVQM` movie, credits, `CHEATCODE2` |
| 4 | kSHARD | Very Hard | 16 | Mewtwo | `YOUWIN.HVQM`, `RESULT-DONE`, credits, `CHEATCODE3` |
| 5 | kULTRA | Super Hard | 16 | Mewtwo | as Very Hard, then `CHEATCODE6` |

- **[R]** Stage counts: the per-difficulty AI tables have exactly 11/14/15/16/16 entries (`src/main/ai.c:55-173`), and
  the stage-select screen caps the stage at 0xB/0xE/0xF/0x10/0x10 per difficulty (`src/main/story.c:60-109`).
- **[R]** Endings, decided on the result screen after a win, when `stage` has already moved past the beaten stage
  (`src/main/041780.c:526-543`): stage 12 on Easy → `(5, 0xA)` = `ENDING-1`; stage 15 on Normal → `(5, 0xB)` =
  `ENDING-2`; stage 16 on any difficulty ≥ Hard → `(5, 7)`. `(5, 7)` plays `GAMEEND.HVQM` and the credits on Hard, and
  on Very/Super Hard plays `MEWINTRO.HVQM` and starts the Mewtwo match directly (no pre-match screen, no Pokémon pick)
  (`src/main/044E80.c:899-915`). Screens and movies: `src/main/044E80.c:986-1045`, `src/main/041780.c:595-612`.
- **[W]** Final opponent per difficulty (Easy Giovanni, Normal Bruno, Hard Gary, Very/Super Hard Mewtwo) and the story
  order: Wikipedia, https://en.wikipedia.org/wiki/Pok%C3%A9mon_Puzzle_League. Agrees with the decomp.

### Opponent order

The decomp has no opponent-name table for Stadium. The order below combines the opponents' Pokémon trios, indexed by
stage (`D_800B6874_usa[stage * 3 + i]`, `src/main/043D10.c:63-74`, read at `:139-142`; row 0 is the player's trio),
the named story screens, and the web.

| Stage | Opponent | Pokémon trio (decomp) | Easy | Normal | Hard | V/S Hard |
|---|---|---|---|---|---|---|
| — | player (Ash) | pikachu, squirtle, bulbasr | | | | |
| 1 | Gary | nidoran, growlith, krabby | ✓ | ✓ | ✓ | ✓ |
| 2 | Brock | geodude, vulpix, zubat | ✓ | ✓ | ✓ | ✓ |
| 3 | Misty | horsea, psyduck, staryu | ✓ | ✓ | ✓ | ✓ |
| 4 | Lt. Surge | raichu, jolteon, magneton | ✓ | ✓ | ✓ | ✓ |
| 5 | Erika | tangela, weepinbell, gloom | ✓ | ✓ | ✓ | ✓ |
| 6 | Koga | venomoth, voltorb, golbat | ✓ | ✓ | ✓ | ✓ |
| 7 | Sabrina | abra, hypno, alakazam | ✓ | ✓ | ✓ | ✓ |
| 8 | Blaine | arcanineb, charmeleon, magmar | ✓ | ✓ | ✓ | ✓ |
| 9 | Tracey | marrill, venonat, scyther | ✓ | ✓ | ✓ | ✓ |
| 10 | Team Rocket | weezing, arbok, golbatr | ✓ | ✓ | ✓ | ✓ |
| 11 | Giovanni | persian, sandslash, nidoking | ✓ (last) | ✓ | ✓ | ✓ |
| 12 | Ritchie | sparky, charmander, butterfree | | ✓ | ✓ | ✓ |
| 13 | Lorelei | cloyster, polywirl, dewgong | | ✓ | ✓ | ✓ |
| 14 | Bruno | onix, hitmonchan, primape | | ✓ (last) | ✓ | ✓ |
| 15 | Gary | nidoqueen, arcanineg, kingler | | | ✓ (last) | ✓ |
| 16 | Mewtwo | (row repeats the player's trio; no pick screen) | | | | ✓ (last) |

- **[R]** Trios and the per-stage index: as cited. **[I]** Names from the trios (each matches the trainer's anime team)
  plus these screens: `GARYLOSE` after stage 1, `TRACEYLOSE` after stage 9, `TEAMROCKETLOSE` after stage 10
  (`src/main/story.c:405-416` pushes them when entering stage 2, 0xA, 0xB; screen names `src/main/043000.c:293-309`),
  and `ELITEFOUR` shown on reaching stage 12 on Normal and up (`src/main/041780.c:529-535`, `:605-606`).
- **[W]** "Ash challenges Gary, his first rival, before defeating seven of the eight of the Kanto region gym leaders
  … Tracey and Team Rocket … Giovanni … the Elite Four, including Gary"; on Hard and up Gary's Pokémon are "fully
  evolved into Nidoqueen, Arcanine, and Kingler" (Wikipedia, URL above). Matches stages 1–15 and the stage-15 trio.
- **[R]** The CPU's own stage background comes from `D_800B67E4_usa = {0, 5, 6, 7, 1, 0xA, 2, 9, 0, 3, 4, 2, 8, 0xB}`
  for stages 1–14, world 0 from stage 15 (`src/main/041780.c:79`, `src/main/043000.c:276-288`); Mewtwo has its own
  (`src/main/bonus.c:319-330`). Cosmetic.

### Unlocks

- **[R]** Stadium progress unlocks 2P characters: `menuFindCharacterMax` takes the max over all five `kPLAYER1V_k*`
  progress values, at least 8, at most 14 (`src/main/menu.c:4722-4737`).
- **[R]** Each `CHEATCODE*` screen is shown after an achievement: 1 Marathon ≥ 50000 (`src/main/041780.c:491-497`),
  2 Hard ending, 3 Very Hard ending, 4 a clear-line reward, 5 all puzzles, 6 Super Hard ending
  (`src/main/044E80.c:734-985`). What each code unlocks is in the screen assets, not the code. **Open.**
- **[W]** Very Hard and Super Hard are entered by codes on the 1P Stadium difficulty screen: hold Z and press L, L, A,
  B (Very Hard) or R, L, A, B (Super Hard) (SuperCheats, https://www.supercheats.com/nintendo64/pokemon-puzzle-league/5799/unlockables/,
  search-result snippet; the page itself returned 403). **[R, draft]** The difficulty screen is a 3×2 grid: row 0 =
  Easy, Normal, Hard; row 1 columns 1, 2 = Very Hard, Super Hard (`asm/usa/nonmatchings/main/menu/func_80017E18_usa.s`,
  m2c draft). How row 1 becomes selectable was not traced. **Open.**
- **[R]** A hidden stage-select screen (`CHEAT.SBF`, story screen type 1) lets the player step `stage` from 1 to the
  difficulty's cap and start there (`src/main/story.c:60-109`). Nothing in matched code pushes it. **Open:** how it is
  reached.

## 2. Per-stage match parameters

### Stack level (both sides)

Stadium uses the 2P VS level table `st_Player2State` for **both** stacks and picks the row from the difficulty only,
not the stage (`asm/usa/nonmatchings/main/dlist/InitGameStateVar.s`, **[R, draft]**; the switch reads
`tetrisWell[0].menu.game` for both wells):

| Difficulty | VS level row (`extra.level`) | Start speed | Colours (`state.rand`) | `state.newBlock` |
|---|---|---|---|---|
| Easy | 1 (0) | 1 | 5 (−1) | 0 |
| Normal | 2 (1) | 5 | 5 (−1) | 1 |
| Hard | 4 (3) | 13 | 5 (−1) | 1 |
| Very Hard | 4 (3) | 13 | 5 (−1) | 3 |
| Super Hard | 4 (3) | 13 | 5 (−1) | 3 |

- **[R]** `state.rand != 0` → panel colours 1–5, else 1–6 (`RandomBlock`, `src/main/tetris.c:36-55`). Stadium always
  sets −1: five colours on every difficulty **[R, draft]**. (2P VS uses five colours for levels 1–8 and six for 9–10,
  same draft.)
- **[R]** `state.newBlock` controls the incoming row (`Init2DNewRow`, `src/main/init2d.c:20-95`): normal generation
  never puts the same colour next to its right neighbour or on top of the panel above; `newBlock < 2` instead copies
  the right neighbour's colour into one random column (a ready-made pair). 0 = every row, 1/2 toggles = every other
  row, 3 = never. So Easy gets a free pair in each new row, Normal and Hard every other row, Very/Super Hard none.
- **[R]** Player and CPU get identical rows: the difficulty is the CPU's brain (below), not a handicap on the stacks.
  **[R]** Board start: the CPU copies the player's starting board when both use the same colour count
  (`src/main/tetris.c:355-370`); Stadium always does, so both start with the same board **[I]**.

`st_Player2State[10][10]` verbatim (`asm/usa/data/main/0B75B0.data.s:1000-1101`, decimal). Column use **[R]** from
`InitGameStateVar` (draft), `src/main/update.c:316-347`, `src/main/animate.c:430-495`, `src/main/init2d.c:31-41`:

| Level | 0 flash | 1 face | 2 pop | 3 hover | 4 `state+0x10` | 5 start speed | 6 topout grace | 7 `extra+0x10` | 8 panels per `!` | 9 max `!` |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 46 | 24 | 9 | 12 | 40 | 1 | 121 | 5 | 12 | 21 |
| 2 | 46 | 22 | 9 | 12 | 35 | 5 | 101 | 8 | 14 | 18 |
| 3 | 44 | 21 | 8 | 11 | 30 | 9 | 81 | 11 | 16 | 18 |
| 4 | 44 | 20 | 8 | 10 | 25 | 13 | 66 | 14 | 19 | 15 |
| 5 | 40 | 19 | 8 | 9 | 20 | 17 | 51 | 17 | 23 | 15 |
| 6 | 38 | 18 | 8 | 8 | 15 | 21 | 41 | 20 | 26 | 12 |
| 7 | 36 | 17 | 8 | 7 | 12 | 25 | 31 | 23 | 29 | 9 |
| 8 | 34 | 16 | 7 | 7 | 9 | 29 | 21 | 26 | 33 | 6 |
| 9 | 32 | 15 | 7 | 6 | 6 | 27 | 11 | 29 | 37 | 6 |
| 10 | 30 | 14 | 7 | 6 | 3 | 32 | 1 | 32 | 41 | 3 |

- Columns 0–3 go to `state.comboFlash/comboFace/comboExplode/blockDropDelay` (DWARF names). Column 4 (an unnamed
  `state` field; matches Panel Attack's garbage hover ±1) and column 7 (`extra.unk_4410`) are not traced **[I]**.
- Level 9's start speed (27) is below level 8's (29). Verbatim; Panel Attack copies it (§6).

### Speed during a match

- **[R]** Rise: each frame not frozen, `timer += 0x01000000 / st_RaiseTimer[level − 1]` and every 0x10000 is one rise
  unit; a 2D row is 16 units (`src/main/update.c:353-359`, `src/main/tetris.c:503-529`). So **frames per row =
  `st_RaiseTimer[level − 1] / 16`** **[I]**. Rise is frozen while the cursor has stop time (`extra_wait`), a swap or
  drop delay is running, or the topout counter is running (`src/main/tetris.c:503-505`).
- **[R]** Speed level climbs on a timer, every frame of play including stop time (`UpdateNextLevel`, called each frame
  at `src/main/tetris.c:575`): when `nextLevel` hits 0, `level++` (max 99) and `nextLevel =
  st_AdvanceLevel[min(level − startSpeed, 39)]` (`src/main/update.c:312-331`). Initial `nextLevel` =
  `st_AdvanceLevel[0]` **[R, draft]**. Each stack counts its own.
- `st_AdvanceLevel` verbatim (frames; `0B75B0.data.s:1225-1266`): 900 ×4, 600 ×4, 540 ×4, 480 ×4, 420 ×8, 360 ×4,
  300 ×12 (and 300 after). So: +1 level every 15 s for the first 4 steps, then 10 s, 9 s, 8 s, 7 s, 6 s, 5 s.
- `st_RaiseTimer` verbatim (99 entries, levels 1–99, `0B75B0.data.s:750-850`); frames per row in brackets:
  15376 (961), 14576 (911), 12976 (811), 12336 (771), 11696 (731), 10800 (675), 10064 (629), 9328 (583), 8752 (547),
  7936 (496), 7280 (455), 6784 (424), 5968 (373), 5584 (349), 5232 (327), 4896 (306), 4592 (287), 4304 (269),
  4032 (252), 3776 (236), 3536 (221), 3312 (207), 3104 (194), 2912 (182), 2720 (170), 2544 (159), 2384 (149),
  2224 (139), 2064 (129), 1904 (119), 1760 (110), 1616 (101), 1488 (93), 1376 (86), 1280 (80), 1168 (73), 1072 (67),
  1008 (63), 928 (58), 864 (54), 800 (50), 752 (47), 688 (43), 640 (40), 592 (37), 560 (35), 528 (33), 496 (31),
  464 (29), 448 (28), 432 (27), 416 (26), 400 (25), 384 (24), 368 (23), 356, 344, 332, 320, 308, 296, 288, 280, 272,
  264, 256, 248, 244, 240, 236, 232, 228, 224, 220, 216, 212, 208, 204, 200, 196, 192, 188, 184, 180, 176, 172, 168,
  164, 160, 156, 152, 148, 144, 140, 136, 134, 132, 130, 128 (level 99: 8 frames per row).

### `!` (shock) panels

- **[R]** Stadium and 2P VS only (`src/main/update.c:334-347`, `:1363-1366`): every popped panel decrements
  `clearGarbage`; at 0 one `!` panel (`BLOCKTYPE_7`) is queued and `clearGarbage += col 8`, until `maxGarbage`
  (col 9) runs out. The incoming row takes two queued `!` if at most 4 are on the board, one if at most 8
  (`src/main/init2d.c:31-41`). Stadium: one `!` per 12 (Easy) / 14 (Normal) / 19 (Hard+) panels, at most 21/18/15
  per match.

### Stop time (shared with 2P VS)

- **[R]** With two stacks, combos and chains award stop time from the 2P tables indexed by `extra.level`
  (`src/main/update.c:364-396`, `:466-533`); the larger of current and new wins. Verbatim
  (`0B75B0.data.s:1105-1221`), per level 1–10:

| Table | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| NormalComboDelay2A | 60 | 56 | 52 | 48 | 45 | 42 | 39 | 36 | 33 | 30 |
| NormalComboDelay2B | 20 | 18 | 16 | 14 | 12 | 10 | 8 | 6 | 4 | 2 |
| NormalChainDelay2A | 120 | 113 | 106 | 99 | 92 | 85 | 78 | 72 | 66 | 60 |
| NormalChainDelay2B | 20 | 18 | 16 | 14 | 12 | 10 | 8 | 6 | 4 | 2 |
| DangerComboDelay2A | 120 | 113 | 106 | 99 | 92 | 85 | 78 | 72 | 66 | 60 |
| DangerComboDelay2B | 80 | 71 | 62 | 53 | 44 | 35 | 26 | 18 | 10 | 2 |
| DangerChainDelay2A | 180 | 170 | 160 | 150 | 140 | 130 | 120 | 110 | 100 | 90 |
| DangerChainDelay2B | 20 | 18 | 16 | 14 | 12 | 10 | 8 | 6 | 4 | 2 |

  Formulas (combo = panels cleared, capped 30; chain = chain length, capped 13):
  - normal combo: `A + B·(combo − 4)`; normal chain: `A + B·(chain − 2)`
  - danger combo: `A + B·k`, k = 0 for combo < 9, 1 for < 11, 2 for < 13, 3 for < 15, else 4
  - danger chain: `A + B·k`, k = 0/1/2/4 for a 2/3/4/5+ chain (`src/main/update.c:498-525`).

### Topout (losing)

- **[R]** `CheckGameOver` (`src/main/animate.c:430-495`): the stack is topped out when a panel sits in the top row. The
  death counter only runs while there is no stop time, no swap or drop delay, no panel in motion anywhere on the
  board, and no manual-raise state; once the top row clears it resets to 0. Topped-out frames needed with two stacks
  (Stadium included): more than `value`, where G = column 6 of the level row (121 / 101 / 66 for Easy / Normal /
  Hard+), and `m` = match minutes:

| Match time | `value` |
|---|---|
| m < 10 | (1 − 0.05·m) · G |
| 10 ≤ m < 20 | (1 − 0.05·(m − 10)) · G/2 |
| 20 ≤ m < 30 | (1 − 0.05·(m − 20)) · G/4 |
| m ≥ 30, or any hour | G/8 |

  (1P modes lose after 2 topped-out frames.)
- **[R]** In 2P VS the match ends with a win count chosen in options (`GAME_STATUS_GET_WIN_RECORD`, default 3 at boot,
  `src/main/title.c:597`). **[R, draft]** Stadium ignores it: **one game per match** (`end.c` 2D game-over draft,
  `src/main/end.c:1726-1757`). Outcomes when a button is pressed after the game:
  - **both topped out the same frame** (draw): replay the same stage at no cost.
  - **player won** (`cursorBlock[0].state == 7` or `cursorBlock[1].state == 8`): `stage++`, back to the story screens.
  - **player lost:** continue screen. Exception: losing to Mewtwo (stage 16) sets `stage = 0x11` and goes to the story
    screens (§3).
- **[R]** No time limit: the clock counts up (`UpdateTime`, `src/main/update.c:153-218`) and is reset after every
  match (`end.c` draft `:2065-2070`). Score is reset each match too [R, draft] and isn't saved for Stadium. Saved are
  the best combo and chain per profile (`unk_0EF`/`unk_0F0`, `src/main/update.c:1072-1074`).

### CPU parameters per stage

- **[R]** At match init the CPU brain gets `AISetLevel(&brainbrain[1], menu[0].game, menu[0].stage)`, 2D only
  (`src/main/tetris.c:350-354`); the player's brain is switched off (`brainbrain->speed = -1`,
  `src/main/043D10.c:432`). `AISetLevel` dispatches to `AISetEasy/Normal/Hard/SHard/Ultra(stage)`
  (`src/main/ai.c:234-261`). Each sets four fields; what they do is the ai.c doc's job. Names here are the decomp's.
  - `unk_014` = `characteristic[stage − 1]`, a per-difficulty byte table (likely a bitmask of techniques **[I]**)
  - `speed` = the number of frames the CPU waits between actions (`InitAI` seeds `delay = speed`, `src/main/ai.c:30`)
    **[I]**
  - `unk_018` from `AISetCharacter(stage)` (`src/main/ai.c:175-215`), then adjusted per difficulty
  - `unk_008` = a flag
- **[R]** `InitAI` in Stadium queues an opening move with probability 1/2 + 1/4 (`src/main/ai.c:44-52`).

Verbatim per difficulty (USA; PAL notes after the table). `unk_018` values shown after the difficulty's adjustment.

| Stage | Easy chr / spd / 018 | Normal | Hard | Very Hard | Super Hard |
|---|---|---|---|---|---|
| 1 | 0x00 / 35 / −1 | 0x01 / 20 / −1 | 0x23 / 16 / −2 | 0x27 / 11 / −3 | 0x27 / 7 / −99 |
| 2 | 0x01 / 35 / −2 | 0x03 / 20 / −2 | 0x27 / 16 / −3 | 0x2F / 11 / −4 | 0x2F / 7 / −99 |
| 3 | 0x03 / 34 / −3 | 0x03 / 19 / −3 | 0x27 / 15 / −4 | 0x2F / 10 / −5 | 0x2F / 7 / −99 |
| 4 | 0x03 / 34 / −4 | 0x03 / 19 / −3 | 0x2F / 15 / −5 | 0xAF / 10 / −6 | 0xAF / 7 / −99 |
| 5 | 0x03 / 33 / 0 | 0x03 / 18 / 0 | 0x2F / 14 / 0 | 0xAF / 9 / 0 | 0xAF / 6 / −99 |
| 6 | 0x03 / 33 / −5 | 0x07 / 18 / −3 | 0xAF / 14 / −6 | 0xAF / 9 / −7 | 0xAF / 6 / −99 |
| 7 | 0x03 / 32 / −6 | 0x07 / 17 / −3 | 0xAF / 13 / −7 | 0xEF / 8 / −8 | 0xEF / 6 / −99 |
| 8 | 0x03 / 32 / −7 | 0x07 / 17 / −3 | 0xBF / 13 / −8 | 0xFF / 8 / −9 | 0xFF / 6 / −99 |
| 9 | 0x07 / 31 / 0 | 0x07 / 16 / 0 | 0xBF / 12 / 0 | 0xAF / 7 / 0 | 0xAF / 5 / −99 |
| 10 | 0x07 / 31 / −8 | 0x0F / 16 / −3 | 0xEF / 12 / −9 | 0xEF / 7 / −10 | 0xEF / 5 / −99 |
| 11 | 0x07 / 30 / 0 | 0x0F / 15 / 0 | 0xBF / 11 / 0 | 0xFF / 7 / 0 | 0xFF / 5 / −99 |
| 12 | | 0x0F / 15 / −3 | 0xFF / 11 / −10 | 0xBF / 7 / −11 | 0xBF / 5 / −99 |
| 13 | | 0x0F / 14 / −3 | 0xBF / 10 / −11 | 0xBF / 7 / −12 | 0xBF / 4 / −99 |
| 14 | | 0x0F / 14 / −3 | 0xBF / 10 / −99 | 0xBF / 7 / −99 | 0xBF / 4 / −99 |
| 15 | | | 0xBF / 9 / −99 | 0xBF / 7 / −99 | 0xBF / 4 / −99 |
| 16 | | | | 0xBF / 7 / (kept) | 0xBF / 4 / −99 |
| `unk_008` | −1 | 0 | 0 | 0 (stages 1–8), −1 (9–16) | −1 |

- Formulas **[R]**: Easy `speed = 35 − (stage − 1)/2`; Normal `20 − (stage − 1)/2` and `unk_018` clamped to ≥ −3;
  Hard `16 − (stage − 1)/2` and `unk_018 −= 1` unless 0 or −99; Very Hard `speed` 11/10/9/8/7 for stages 1–2, 3–4,
  5–6, 7–8, 9+, and `unk_018 −= 2` unless 0 or −99; Super Hard `speed` 7/6/5/4 for stages 1–4, 5–8, 9–12, 13+,
  `unk_018 = −99` always (`src/main/ai.c:55-173`). The table above applies them (integer division).
- `AISetCharacter` base values **[R]**: stage 1 −1, 2 −2, 3 −3, 4 −4, 6 −5, 7 −6, 8 −7, 10 −8, 12 −9, 13 −10;
  5, 9, 11 → 0; 14, 15 → −99. Stage 16 has no case on NTSC, so Very Hard's Mewtwo keeps the brain's previous value
  (−99 after a stage-15 match **[I]**). PAL adds 16 → −99.
- Stages 5, 9, 11 (Erika, Tracey, Giovanni) have `unk_018 = 0` on every difficulty below Super Hard: a deliberate
  per-opponent personality **[I]**.
- PAL (`#if REGION_PAL` branches) slows Very Hard to 13/12/11/10/9/8 and Super Hard to 11/10/9/8/7, then
  `ADJUST_FRAMERATE` scales every `speed` for 50 Hz (`src/main/ai.c:103-168`, `:258-260`). Use USA.
- Reference: the title demo and the menu's vs-CPU path use a 10-step scale `DemoCPU(level)` → (difficulty, stage):
  1 (E,1), 2 (E,9), 3 (N,3), 4 (N,12), 5 (H,6), 6 (H,14), 7 (VH,3), 8 (SH,10), 9 (VH,15), 10 (SH,15)
  (`src/main/tetris.c:187-232`). **[R, draft]** The menu passes level 10 whenever the match is 3D
  (`func_80017E18_usa.s`, m2c draft).

### 2D vs 3D

- **[R]** Stadium is 2D only. Every path into a Stadium match sets `dimension = DIMENSION_2D` (Pokémon pick
  `src/main/043D10.c:426-439`, Mewtwo `src/main/044E80.c:906-912`, `src/main/043000.c:236-243`), and only the 2D init
  calls `AISetLevel` (`src/main/tetris.c:350`; the 3D branch from `:382` has no Stadium case). This settles
  `docs/3d-mode/SPEC.md` §6's open "unsure about Stadium".
- **[W]** "AI opponents' abilities are limited when using the 3D gameplay style" (Wikipedia, URL above). That is about
  the 3D VS CPU, not Stadium.

## 3. Flow

Story screens are a stack of `(type, arg)` entries (`func_8002B85C_usa`, `src/main/story.c:137-145`): 1 = stage
select (`CHEAT.SBF`), 2 = result screen (`RESULT.SBF`), 3 = pre-match/dialogue (`OPPONENT.SBF`), 4 = Pokémon pick
(`POKEMON.SBF`), 5 = movie/credits/ending (`CREDITS.SBF`) (`src/main/story.c:174-195`; GameCube names
`storyTickPick/Open/Isle/Keys/Done`, `:290-301`). B backs out of some screens (`:242-266`).

1. **Menu → difficulty** **[R, draft]** (`func_80017E18_usa.s`): pick the difficulty in the grid, plus a second
   cursor (`0x65`). If it is 1, the save for that difficulty is wiped (`kPLAYER1V_k* = 0`, continues = 0). Then
   `stage = saved progress + 1` (capped at 15), `speed` (continues) = saved continue count, `misc = 0`,
   `gMain = GMAIN_STORY` **[I]**. So the second cursor is "new game" vs "resume", and resuming keeps the continue count.
2. **Opening** (`InitStory`, `src/main/story.c:359-419`, with `misc == 0`): stage 1 → result screen 0 (`RESULT0`, the
   intro); stage 2–15 → pre-match screen for that stage; stage 12 → `ELITEFOUR`; stage 16 → `(5, 7)`.
3. **Pre-match** (`TRANSITION<stage>`, `src/main/043000.c:229-253`): portraits slide in, dialogue text pages on A,
   Start skips. Then the Pokémon pick.
4. **Pokémon pick** (`1PPK-PICK`, `src/main/043D10.c:392-529`): the player picks one of three Pokémon
   (`menu[0].misc`); the CPU "picks" index 2 on Easy, 1 on Normal, 0 on Hard, a pseudo-random one on Very/Super Hard
   (`:454-462`). Then the match starts (2D, 2 players). **[I]** Cosmetic: no gameplay code reads `menu.misc` in
   Stadium (it feeds character graphics and sound). **Open:** whether the pick changes anything in play.
5. **Match:** single game, rules in §2.
6. **Win:** progress saved as the beaten stage number, `UpdatePlayerCPU(game, stage)` (`src/main/update.c:1017-1043`,
   called from `asm/usa/nonmatchings/main/end/DoGameOver2D.s:695-706` only for a Stadium win); `stage++`; story:
   - after stages 1, 9, 10 a rival's "lose" scene (`GARYLOSE`, `TRACEYLOSE`, `TEAMROCKETLOSE`), else the result screen
     `RESULT<stage − 1>`;
   - then the endings of §1, or the next pre-match screen.
7. **Lose → continue screen** (`DoBonus`, `src/main/bonus.c:493-547`): "Try again?" Yes/No (`DoGameOverTryAgain`,
   `src/main/end.c:1000-1090`). Yes: `menu[0].speed++` (continues, max 99) and the difficulty's saved continue count
   ++ (max 99), save, and rematch the same stage directly (no story screens). No: back to the menu. The counter shows
   as two digits on the screen. **Unlimited continues; the only cost is the counter.** No code found that reads the
   count for anything else **[I]** (`kPLAYER1V_k*_continue` may show on the profile screen). **Open.**
8. **Mewtwo (stage 16):**
   - Win: `stage = 0x11` → `YOUWIN.HVQM` → `RESULT-DONE` → credits → `CHEATCODE3` (VH) / `CHEATCODE6` (SH) → title
     (`src/main/story.c:397-402`, `src/main/044E80.c:918-925`, `src/main/041780.c:521-527`).
   - Loss: no continue screen first: `stage = 0x11` → `YOULOSE.HVQM` → `stage = 0x12`, continue screen
     (`src/main/044E80.c:927-935`). Yes → `stage = 0x13` → story sets `stage = 0xF` and shows `GARYWIN`, then the
     pick screen and **a rematch against stage 15 (Gary)**; beat Gary again to get back to Mewtwo
     (`src/main/bonus.c:538-545`, `src/main/story.c:394-396`, `src/main/043000.c:229-247`).
   - **[W]** "If the player loses to Mewtwo, they must re-battle Gary until they can beat him and Mewtwo
     consecutively" (search snippet of Bulbapedia, https://m.bulbapedia.bulbagarden.net/wiki/Pok%C3%A9mon_Attack). Agrees.
9. **Save and passwords:** no passwords. Progress lives in the player profile on the cartridge save: per difficulty the
   last stage beaten and the continues used (`kPLAYER1V_k*`, `kPLAYER1V_k*_continue`), written on wins and continues
   (`SaveRom`, `src/main/end.c:3894-3896`) **[R]**. **Open:** what resume does after an ending (e.g. Easy saved 11 →
   resume at stage 12, which Easy never plays), unless something resets the save.

## 4. VS rules that differ from Panel Attack's VS

From the decomp, compared with this fork's Panel Attack engine:

- **Speed ramp:** PPL steps faster over time (`st_AdvanceLevel`: 15 s ×4, 10 s ×4, 9, 8, 7, 6, then 5 s). Panel
  Attack's time-interval mode is a flat 900 frames (`common/engine/Stack.lua:55`, `DT_SPEED_INCREASE = 15 * 60`). **[R]**
- **Rise times:** PPL frames per row (961, 911, 811, …, monotonic) differ from Panel Attack's `SPEED_TO_RISE_TIME`
  (942, 983, 838, …; "2 is slower than 1", `common/engine/consts.lua:59-71`), which comes from the earlier games.
  **[R]** both tables.
- **Topout grace decays with match time** (§2 Topout). Panel Attack's `maxHealth` is the same base number (121 at
  level 1) but does not decay with match minutes **[I]** (not checked in `Stack.lua` beyond the preset).
- **Adjacent colours:** PPL's helper pair per row (`newBlock`) vs Panel Attack's `adjacentDenialFrequency` fraction
  (level 1: 0, level 2: 1/7, …, 8–10: 1). Different mechanisms with a similar aim **[I]**.
- **Single game per match** in Stadium vs best-of in 2P VS (§2).
- **Garbage** (combo/chain shapes) and the `!` panels are shared with 2P VS (`docs/3d-mode/SPEC.md` §4 for 3D shapes);
  attack exchange runs only in Stadium and 2P VS (`src/main/tetris.c:563-568`). With two stacks, attacks of types 5–8
  are deleted every frame (`HackGame`, `src/main/tetris.c:607-622`); meaning unknown. **Open.**

## 5. Tables

All tables needed to rebuild the mode are verbatim above:

- ladder, stage caps, endings: §1
- `st_Player2State`, `st_AdvanceLevel`, `st_RaiseTimer`, the 2P stop-time tables, the topout decay: §2
- the AI `characteristic`/`speed`/`unk_018`/`unk_008` per difficulty and stage, and the `DemoCPU` scale: §2

Only the per-difficulty AI `characteristic` arrays, copied as declared (`src/main/ai.c:56`, `:65-67`, `:79-81`,
`:93-95`, `:140-142`):

```c
Easy:   { 0, 1, 3, 3, 3, 3, 3, 3, 7, 7, 7 }
Normal: { 1, 3, 3, 3, 3, 7, 7, 7, 7, 15, 15, 15, 15, 15 }
Hard:   { 0x23, 0x27, 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xBF, 0xBF, 0xEF, 0xBF, 0xFF, 0xBF, 0xBF, 0xBF }
SHard:  { 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF }
Ultra:  same as SHard
```

## 6. Mapping to Panel Attack

**Panel Attack's levels 1–10 are PPL's VS level table.** `common/data/LevelPresets.lua` `modern[1..10]` match
`st_Player2State` rows column for column: `startingSpeed` = column 5 (1, 5, 9, 13, 17, 21, 25, 29, 27, 32, including
level 9's dip), `shockFrequency` = column 8, `shockCap` = column 9, `maxHealth` = column 6, `colors` 5 for levels 1–8
and 6 for 9–10 (PPL's `rand` rule), `HOVER` = column 3, `POP` = column 2. `FLASH` = column 0 − 2, `FACE` =
column 1 − 4 and `GARBAGE_HOVER` = column 4 + 1 (PPL counts its timers differently). Level 1's stop constants
re-base PPL's 2P tables (combo −20 + 20·c = 60 + 20·(c − 4)). **[I]** from comparing the two tables. Level 11 has no
PPL counterpart. So **Stadium's stack levels map directly: Easy → PA level 1, Normal → level 2, Hard / Very Hard /
Super Hard → level 4**, the same level for player and CPU.

**Mirror:**

- 5 difficulties with 11 / 14 / 15 / 16 / 16 stages. Final-boss stage only on the top two. Stage count and the
  per-stage CPU table drive difficulty; the stack level stays fixed per difficulty.
- The CPU table of §2 as the config source: `speed` (frames between CPU actions) is the main knob (35 → 30 on Easy,
  down to 4 on Super Hard); `characteristic` gates techniques. Port the numbers once the ai.c doc says what each bit
  means. The 10-step `DemoCPU` scale is a ready-made "vs CPU level 1–10" for a plain VS-CPU option.
- One game per match. A draw replays the stage free; a loss offers a continue (unlimited, counted, shown on the HUD).
  This is exactly `ChallengeMode:recordStageResult` (`client/src/ChallengeMode.lua:164-187`: tie → same stage, no
  cost; loss → `continues + 1`).
- Losing the final boss sends the player back one stage (the stage-15 rival), and both must be beaten back to back.
- Save per difficulty: last stage beaten and continues used; "new game" vs "resume" on the difficulty screen.
- Progress unlocks 2P characters (PPL: max stage reached, at least 8, at most 14) and finishing Hard unlocks the
  next difficulties (PPL uses codes shown at the endings; a plain "beat Hard to unlock Very Hard, beat Very Hard to
  unlock Super Hard" is the adapted version).
- Five colours on every Stadium difficulty, and PPL's helper pair per row (Easy every row, Normal/Hard every other,
  Very/Super Hard none) if we want the PPL feel; otherwise PA's level adjacency rule.
- 2D. The PPL CPU in 2D is the reference.

**Adapt:**

- **Opponents:** Panel Attack characters instead of trainers. `ChallengeModePlayer.characterForStageNumber`
  (`client/src/ChallengeModePlayer.lua:29-52`) already assigns a character per stage; Stadium needs a fixed,
  authored order per difficulty with a recurring rival (stage 1 and the final pre-boss stage) and a boss character for
  stage 16. No Pokémon names, art or the Pokémon-pick screen; at most a cosmetic choice.
- **Opponent kind:** ChallengeMode fights a `SimulatedStack` (attack-pattern files plus a health bar,
  `ChallengeMode.lua:48-145`); Stadium needs a real CPU stack. The plumbing (CPU as an input source, mode presets,
  scenes copied from ChallengeMode) is in `docs/stadium/INTEGRATION.md` §A1-A4.
- **Speed ramp and rise times:** decide between PPL-accurate (`st_AdvanceLevel` schedule, PPL rise table) behind a
  Stadium-only rule, or Panel Attack's existing level behaviour. The PPL schedule is notably harsher after a minute
  (level +1 every 10 s, then faster). A new `speedIncreaseMode` would keep 2D VS and old replays untouched.
- **Topout decay with match minutes:** not in Panel Attack; optional, and Stadium matches rarely run 10 minutes.
- **Story screens:** replace rival dialogue and movies with a simple pre-match card (portraits + one line) and a
  result card; keep the ending/credits gate per difficulty.
- **3D:** PPL has no 3D Stadium. A "Stadium 3D" is our addition (INTEGRATION.md §A4 recipe); expect the CPU to be
  weaker there (PPL's 3D CPU loses quick moves, `docs/3d-mode/SPEC.md` §8; the menu's 3D vs-CPU path always uses
  `DemoCPU` level 10).

## Open questions

1. How Very Hard and Super Hard become selectable on the difficulty grid (codes per [W]; the menu asm was not traced).
2. What each `CHEATCODE*` screen unlocks (asset text, not code).
3. How the stage-select screen (`CHEAT.SBF`) is reached.
4. Resume after an ending: does progress reset, or can Easy resume at stage 12?
5. Does the Pokémon pick change gameplay (character graphics only, as far as the code shows)?
6. Meaning of `st_Player2State` columns 4 and 7, and of the attack types `HackGame` deletes in VS.
7. Whether the continue count feeds anything beyond the counter and the profile.
8. What the AI fields (`unk_014` bits, `unk_018`, `unk_008`) do: see the ai.c doc.

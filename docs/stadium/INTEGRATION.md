# CPU opponent + 1P Stadium: integration map

Research for adding (1) a CPU opponent and (2) a Pokémon Puzzle League style 1P "Stadium" ladder (a run of CPU
opponents with difficulty levels) to this fork. Part A maps the codebase; Part B is prior art. Paths are relative to
the repo root; line numbers are for branch `3d-mode` at `035d30f5`.

---

# Part A: the codebase

## A1. The existing computer-player stub

**What is there** (`common/engine/computerPlayers/`):

- `computerPlayer.lua`: global `CPUConfig` (`:5`) and global `ComputerPlayer` (`:16`), built with
  `(cpuName, configName, stack)`; only knows `"DummyCpu"` (`:18`). `run(stack)` (`:67-72`) asks the implementation
  for one input and calls `stack:receiveConfirmedInput(nextInput)` if the stack hasn't ended. `validateImplementation`
  (`:38`) is never called (its own comment says it "does actually not seem to work").
- `DummyCpu/DummyCpu.lua`: global `DummyCpu` that returns `KeyDataEncoding.base64encode[21]` every frame (`:12`),
  i.e. value 20 = swap (16) + down (4). `setConfig` ignores its argument (`:15-18`).
- `computerPlayer.md`: the intended contract: a CPU is "an alternative form of an input device", runs once per
  `Match:run()`, gets the real stack at construction and **must not alter it**; it returns one input per call, encoded
  as `base64encode[bits + 1]` with Right 1, Left 2, Down 4, Up 8, Swap 16, Raise 32.

**Is it wired in? No.** Nothing `require`s `computerPlayer.lua` (repo-wide grep finds no reference outside the folder).
The only trace is a commented-out hook in `client/src/ClientMatch.lua:212-215`:

```lua
    -- if stack.cpu then
    --   stack.cpu:run(stack)
    -- end
    if stack.is_local and stack.send_controls and not stack:game_ended() --[[and not stack.cpu]] then
```

History (`git log`): Endaris added the entry point in `b962c3fa` (2022-08-01, PR #579): `Match:run` called
`self.P1CPU:run(P1)` / `self.P2CPU:run(P2)` and skipped `send_controls` for CPU stacks, and the old select screen set
`GAME.match.P2CPU = ComputerPlayer("DummyCpu", "DummyConfig", P2)` behind a test-only "Vs Computer" menu item. The
Scene refactor `941c2788` (2024-05-13, #1174) commented the hook out and dropped the creation; `b2adfd3f`
(2024-12-23, #564) moved the commented hook from `Match.lua` to `ClientMatch.lua`. The stub has been dead since May
2024. There never was a real AI in the repo.

**What it would take** (keep the idea, replace the code):

1. Rewrite the module as a normal `local` class returned from its file (the globals and the name switch don't match
   current style; CONTRIBUTING wants LuaLS annotations). Interface: constructed with `(stack, config, seed)`;
   `getInput(): string` returns exactly one encoded character per frame; reads the stack, never writes it; owns its
   own RNG (`love.math.newRandomGenerator(seed)`), never the panel generator's (see A2).
2. Drive it from the client, at the dead hook: in `ClientMatch:run` (`ClientMatch.lua:211-219`), for a stack whose
   player is a CPU, push `cpu:getInput()` into the engine stack when `#engine.confirmedInput == engine.clock` and the
   stack hasn't ended, and **skip `send_controls`** for it (`PlayerStack:send_controls` reads
   `self.player.inputConfiguration`, `client/src/network/PlayerStack.lua:40`, which a CPU doesn't have). Tests drive
   the CPU the same way by hand (A5), so `Match` stays untouched, which keeps the server and replay paths risk-free.
   (Putting the hook in `Match:run` as in 2022 also works and makes headless runs drive themselves, but it puts client
   policy into the shared engine; not needed.)
3. A participant type for the CPU (A4) so `ClientMatch` builds a real engine `Stack` + `PlayerStack` for it.

## A2. How a match runs, how inputs reach a stack, and where a CPU injects

**Per-frame call chain (client).** `GameBase:runGame` (`client/src/scenes/GameBase.lua:305-325`) calls
`ClientMatch:run()` once per elapsed 1/60 s, several times in one love frame if it fell behind (`:315-321`).
`ClientMatch:run` (`ClientMatch.lua:205-240`) returns early while paused or ended (`:206`), lets every local stack
produce input via `send_controls` (`:211-219`), then calls `Match:run()` (`:221`). `Match:run`
(`common/engine/Match.lua:236-286`) loops: for each stack, `pushGarbageTo(stack)` then `stack:run()` while
`Match:shouldRun` → `Stack:shouldRun` allows it (`Match.lua:610-639`, `Stack.lua:680-712`); after all stacks ran it
saves rollback copies where needed (`:259-266`). A **local** stack only runs if an input is waiting
(`Stack.lua:693-694`: `buffer_len > 0`), so exactly one input per `Match:run` means exactly one frame.

**Input path for a human.** `PlayerStack:send_controls` (`client/src/network/PlayerStack.lua:24-57`) returns if an
input is already buffered (`:33-36`), builds one character from the input configuration (`:39-48`; `isDown` = pressed
this frame, `isPressed` = held, `client/src/inputManager.lua:12-14`; swap uses `isDown` only, so it is edge-triggered;
directions and raise use either), sends it to the server (`NetClient:sendInput` is a no-op offline,
`NetClient.lua:471-476`) and appends it with `engine:receiveConfirmedInput` (`:56`). `Stack:receiveConfirmedInput`
(`Stack.lua:812-820`) appends to `confirmedInput` (preallocated 43200 entries, `Stack.lua:222`).
`Stack:run` (`:715-792`) → `setupInput` (`:800-810`) reads `confirmedInput[clock + 1]` (idle once the stack ended)
→ `controls` (`:605-678`).

**Encodings.** `common/data/KeyDataEncoding.lua`: `base64encode[value + 1]`, `base64decode[char]` =
`{raise, swap, up, down, left, right}` (`:5-14`; unpacked at `Stack.lua:639`); named constants `idle/left/right/up/
down/swap/raise` (`:16-26`). One direction per frame wins in the order up > down > left > right (`Stack.lua:652-660`).
`common/data/TouchDataEncoding.lua` packs raise + a target row/column into one Latin character; on a cylinder touch
only carries raise (`Stack.lua:612-613`). A CPU should use `inputMethod = "controller"`.

**Controller timing a CPU must model** (its "hands"):

- A new direction moves the cursor on the frame it is pressed (`cur_timer == 0`, `Stack.lua:1060-1062`). Holding the
  same direction repeats only after `DEFAULT_INPUT_REPEAT_DELAY = 20` frames (`Stack.lua:40`, `:662-669`, `:1064`),
  then every frame in 2D. So the fast way to cross columns is press / idle / press (2 frames per column after the
  first), or switch directions each frame.
- 3D: left/right start a 4-frame rotation (`consts.CYLINDER_ROTATION_FRAMES`, `Stack.lua:1092-1097`); presses during a
  rotation are dropped; held repeats use `CYLINDER_INPUT_REPEAT_FRAMES = 3` (`Stack.lua:1059-1075`), giving a column
  per 6 frames held. Up/down still move a row per press. A swap during a rotation snaps it to its end first
  (`Stack.lua:767-770`).
- Cursor movement is applied before the swap in the same frame (`Stack.lua:761`, then `:766-774`), so move + swap in
  one input swaps at the new position. A swap is refused while one is queued (`Stack.lua:643-650`, so at most every
  other frame) and during the countdown and the first frames (`Stack.lua:1333-1335`). The queued swap executes at the
  start of the **next** frame's physics (`Stack.lua:930-934`), then the panels sit in `swapping` for the swap time.
- Raise is level-triggered: a held raise keeps `manual_raise` on (`Stack.lua:672-677`, `:980-1025`).
- During the countdown (`stack.do_countdown`, `Stack.lua:1218-1273`) the engine animates the cursor; the CPU should
  send idle until `do_countdown` is false.

**Rollback and replays.** Replays store each `Stack`'s `confirmedInput`, compressed (`Match:createNewReplay`,
`Match.lua:413-453`, `stackType = 1`; refreshed at the end by `ReplayV3.finalizeReplay`,
`common/data/ReplayV3.lua:230-253`, called from `ClientMatch:finalizeReplay`, `ClientMatch.lua:382-435`). Playback
rebuilds plain stacks and feeds the inputs back (`Match.createFromReplay` → `createStackWithSettings(..., inputs)`,
`Match.lua:457-505`, `:664-686`). `SimulatedStack`s (attack engine / health, challenge mode) are stored as settings
instead (`stackType = 2`, `Match.lua:428-436`). Rollback restores a saved copy and re-runs the stack on its already
confirmed inputs (`BaseStack.lua:158-184`, `Match.lua:289-353`); it never asks for inputs again.

**Therefore: inject at the input buffer, like a human.** A CPU stack must be a normal engine `Stack` whose inputs come
only through `receiveConfirmedInput`, one character per frame, decided from state the stack already shows. Then a
vs-CPU replay is just a two-human replay: it replays bit-exact with no CPU code loaded, survives rollback (confirmed
inputs are re-used, the CPU is not re-asked), and plays in the existing replay browser (`ClientMatch.createFromReplay`
turns a `stackType = 1` stack into a non-local `Player`, `ClientMatch.lua:103-115`; `Player.createFromReplayMetadata`,
`client/src/Player.lua:276-293`). Rules that follow:

- **Never touch the stack's panel RNG.** Each stack's `PanelGenerator` owns a `love.RandomGenerator`
  (`common/engine/PanelGenerator.lua:24`, `:36-38`) that the panel source draws from (`GeneratorSource.lua:56`). A CPU
  that consumed it would change future panels live but not on playback: instant replay desync. Use a separate
  generator seeded from the match seed and the stack index.
- **Never write to the stack**, its panels or garbage queues (the 2022 contract). Calling `stack:canSwap(p1, p2)` is
  safe (`Stack.lua:1329-1388` and `WigglePay.canSwap`, `common/engine/WigglePay.lua:40-64`, only read);
  `tryQueueSwap`/`swap` are not.
- Decide only when the stack is caught up (`#confirmedInput == clock`), from the state after the previous frame, the
  same view a human gets.
- Determinism of the CPU itself is not needed for replays (inputs are recorded) but is needed for CPU-vs-CPU tests:
  no `math.random`, no wall-clock budgets, no `love.thread` (thread timing would change which frame a plan lands on).

**Client wiring that touches `human`.** `ClientMatch:setupFromGameMode` builds an engine `Stack` only for
`player.human` and a `SimulatedStack` otherwise (`ClientMatch.lua:154-166`); finalize writes human metadata on the
same flag (`:406-426`). `BattleRoom` needs an input device only for local humans (`getLocalHumanPlayers`,
`client/src/BattleRoom.lua:458-466`; ready check `:300-317`, `(not player.human or inputConfiguration ...)` at `:311`).
`MatchParticipant:onMatchEnded` un-readies only humans (`client/src/MatchParticipant.lua:213-224`). `PlayerStack`
copies `is_local` from the player into the engine (`client/src/PlayerStack.lua:50`). So a CPU participant should be
`human = false`, `isLocal = true`, plus a new `isCpu = true` that `ClientMatch.lua:157` and `:406` also accept.

## A3. What the CPU can read without touching the stack

All on the engine `Stack` (`common/engine/Stack.lua`, fields annotated at `:92-167`, set up at `:176-300`):

| What | Where |
|---|---|
| Grid | `stack.panels[row][col]`, rows `0..#stack.panels`: row 0 is the incoming row (state `dimmed`), rows `1..stack.height` (12) visible, rows above `height` hold off-screen garbage. `stack.width` 6, or 18 on a cylinder (`:180-182`). |
| Panel | `common/engine/Panel.lua:4-47`: `color` (0 empty, 1-7 colors, 8 shock, 9 colorless; `:719-746`), `state` (`normal`, `swapping`, `matched`, `popping`, `popped`, `hovering`, `falling`, `landing`, `dimmed`, `dead`; state tables `:291-300`), `timer` (frames left in the state), `chaining`, `isGarbage`, `metal`, `garbageId`, `width`/`height`/`x_offset`/`y_offset`, `dont_swap`, `isSwappingFromLeft`, `queuedHover`, `matchAnyway`. Helpers: `allowsSwap()` (`:698-717`: normal/swapping/falling/landing, not garbage, not `dont_swap`), `dangerous()` (`:836-842`). |
| Cursor | `cur_row`, `cur_col` (left panel), `top_cur_row` (`:144-153`, 11 while part-way through a rise, `:923-925`), `cursorDirection`, `cur_timer`, `cur_wait_time`, `queuedSwapRow/Column`, `swapQueued()` (`:590-592`). |
| Rise | `displacement` (16 units per row, 3D too), `rise_timer`, `rise_lock`, `speed`, `manual_raise`, `has_risen`, `prevent_manual_raise`; passive raise in `advancePassiveRaise` (`:1186-1216`). |
| Danger / health | `isToppedOut()` (`:822-829`), `wasToppedOut`, `health` (counts down while topped out, `:1199-1200`; reset to `levelData.maxHealth` when safe, `:919-920`), `stop_time`, `pre_stop_time`, `shake_time`. (The client's danger columns are in `PlayerStack`, `client/src/PlayerStack.lua:83`, and only 6 wide; the CPU should compute column heights itself.) |
| Chains | `chain_counter` (`:130`), `hasChainingPanels()` (`:1690`), `n_active_panels` / `getActivePanelCount()` (`:1704-1740`), `hasActivePanels()` / `hasFallingGarbage()` (`:573-588`). |
| Garbage | Incoming: `stack.incomingGarbage` (`common/engine/GarbageQueue.lua`, fields `:104-115`); next to drop is `peek()` (`:268-271`), all staged in `stagedGarbage` (sorted lowest to highest priority); drop rules in `Stack:shouldDropGarbage` (`Stack.lua:843-893`). What the opponent is building is in its `outgoingGarbage` (`currentChain`, `garbageInTransit`): that is what the client telegraph draws. |
| End | `game_over_clock` (-1 alive), `game_ended()` (`:1276-1282`), `do_countdown`, `clock`, `stopWatch`, `score`, `swapCount`. |
| Level | `levelData` (`common/data/LevelData.lua:11-35`: `colors`, frame constants such as `HOVER`/`FLASH`/`POP`, `maxHealth`, `stop`), `behaviours.allowManualRaise/passiveRaise`. |

**Cylinder (SPEC §9).** `stack.cylinder`; `cur_col` is the board column of the cursor's left panel (1-18), the right
one is `stack:columnRightOf(cur_col)` (`Stack.lua:1127-1133`); `rotationTimer` (4 → 0) and `rotationDirection`
(−1/0/+1) for a running turn; `getCylinderViewCenter()` (`:1160-1166`); column helpers `wrapColumn` (`:1120`),
`areNeighbourColumns` (`:1138`), `viewToBoardColumn` / `boardToViewColumn` (`:1147-1155`, view column 4 = cursor's
left panel, `consts.CYLINDER_CURSOR_VIEW_COLUMN`). Garbage `x_offset` counts modulo 18; `width == 18` is a full ring.
The CPU never moves the cursor sideways: it rotates (`moveCursorInDirection`, `:1078-1088`). Ring distance between
columns a and b is `min(|a−b|, 18−|a−b|)`, at 6 frames per column held or 4 per tap+idle. PPL's own 3D CPU plans
only inside view columns 0-5 (SPEC §8: `src/main/ai.c:268`), which makes the 3D search the same size as 2D.

## A4. Templates for a new mode, and the recipe

**How ChallengeMode is built** (the closest template: one human against a non-human participant, a ladder of stages):

- `client/src/ChallengeMode.lua`: a `BattleRoom` subclass (`:21-40`) that adds `GAME.localPlayer` and a
  `ChallengeModePlayer`, builds per-difficulty stages (`createStages`, `:48-145`), advances on wins
  (`recordStageResult`, `:164-189`), overrides `onMatchEnded` (`:191-215`), and configures the opponent per stage
  (`setStage`, `:217-233`). `ChallengeMode.create(difficulty)` (`:42-44`) uses preset `ONE_PLAYER_CHALLENGE` with
  scene `Game1pChallenge`. Progress is not saved anywhere; a run lives only in memory.
- `client/src/ChallengeModePlayer.lua`: `MatchParticipant` with `human = false`, `isLocal = true`, always ready
  (`:14-25`, `:76-80`), picks a character per stage (`:29-52`, `:72-74`), builds a `ChallengeModePlayerStack`
  (`:56-70`) around a `SimulatedStack`, and rebuilds itself from replay metadata (`:84-94`).
- Scenes: `ChallengeModeMenu.lua` (difficulty stepper → `ChallengeMode.create` → `CharacterSelectChallenge`,
  `:23-29`, `:31-61`); `CharacterSelectChallenge.lua` already handles a non-human opponent (cursors and panel
  carousels only for `player.human`, `:49-71`); `Game1pChallenge.lua` (HUD with difficulty/stage/continues,
  `startNextScene` → recap when `challengeComplete`, `:25-34`); `ChallengeModeRecapScene.lua`.
- `GameModes.lua:152-170` (`OnePlayerChallenge`: `playerCount = 1`, `VERSUS`, `STACKS_ACTIVE = 1`, win by
  `GAME_OVER_CLOCK`, countdown). `playerCount` counts players the room creates itself; the challenger is added by
  `ChallengeMode`.

**How the 3D presets were added** (`704f1ae4`, `84d7ddb9`): `cylinderVariant(gameMode, name, label)` deep-copies a
preset and sets `matchRules.stackSetupModifications.cylinder = true` (`GameModes.lua:210-227`); each new mode is added
in four places: `GameModes.IDs` (`:233-247`), `privateGameModes` (`:250-263`), `gameModeIdToName` (`:296-310`),
`nameToGameModeId` (`:313-327`). Menu items in `client/src/scenes/MainMenu.lua:54-128` (`mm_1_vs_3d` at `:90-95`
reuses `VsSelfGame` + `CharacterSelectVsSelf`; `mm_1_training_3d` at `:99-101` passes `{gameModeId = ...}` into an
existing menu scene, which reads it in its constructor, `TrainingMenu.lua` `self.gameModeId = sceneParams and ...`).
Localization rows were appended at the bottom of `client/assets/localization.csv` (now 685 lines; columns
`CODE,Context,EN,FR,PT,JP,ES,GE,IT,TH`, header line 1; the 3D rows are 681-685). `BattleRoom` is a global used without
`require` in `MainMenu`. `MatchRules.lua` needs no change for a new mode (only the `cylinder` flag was added, `:7`).
`LevelPresets.getModern(level)` / `getClassic(difficulty)` (`common/data/LevelPresets.lua:314`, `:323`) give the
`LevelData` for each side.

**Save data.** Persistent records live in `client/src/scores.lua` (`Scores`, `scores.json`, `currentVersion = 5` at
`:13`; tables built in the constructor `:21-50`; loading/upgrade `:205-290`; `saveToFile` `:310`; reached through
`GAME.scores`, created in `client/src/Game.lua:76`; tests in `client/tests/ScoresTests.lua`). Note: the 3D modes
currently write into the 2D tables (`VsSelfGame.lua:21` saves vs-self 3D into the same `vsSelf[level]`).

**Recipe: a main-menu mode "Stadium" (and "Stadium 3D") that pits P1 against a CPU stack.**

1. **Engine CPU** `common/engine/computerPlayers/` (replace the stub, A1): `ComputerPlayer.lua` (interface + factory
   by config name) and one implementation folder. Pure Lua, no client requires; read-only on the stack; own RNG;
   preallocated buffers (A6).
2. **Mode presets** `common/data/GameModes.lua`: `OnePlayerStadium` as a copy of `OnePlayerChallenge` (`:152-170`)
   with `gameScene = "Game1pStadium"`, `name = "stadium"`; `OnePlayerStadium3D = cylinderVariant(OnePlayerStadium,
   "stadium3d", "Stadium 3D")`; add both in the four tables (`:233-327`). Both sides get the same rules, so the CPU's
   stack is 3D when the player's is.
3. **CPU participant** `client/src/CpuPlayer.lua`: subclass `Player` (so `settings.levelData` and
   `settings.inputMethod = "controller"` exist for `ClientMatch.lua:158` and `createClientStack` builds a normal
   `PlayerStack`, `Player.lua:104-129`), with `human = false`, `isLocal = true`, `isCpu = true`, always ready (copy
   `ChallengeModePlayer.lua:76-80`), character per stage (copy `:29-52`), and a `cpuConfig` setting (difficulty
   preset). Edits: `ClientMatch.lua:157` build a `Stack` for `player.human or player.isCpu`; `ClientMatch.lua:211-219`
   drive the CPU (push `cpu:getInput()` when caught up) and skip `send_controls` for it; `ClientMatch.lua:406` write
   `StackMetadata` for CPUs too (plus e.g. `metadata.cpu = {config, seed}` for display; playback doesn't need it).
   Create the CPU object when the `PlayerStack` is created (it needs the engine stack).
4. **Room** `client/src/Stadium.lua`: copy `ChallengeMode.lua` as a `BattleRoom` subclass: stages = list of
   `{characterId, cpuConfig, cpuLevel, playerLevel}`; constructor adds `GAME.localPlayer` and a `CpuPlayer`, calls
   `restoreInputConfigurations()` and `setStage(1)`; `Stadium.create(difficulty, gameModeId)`; `recordStageResult` /
   `onMatchEnded` like `ChallengeMode.lua:164-215` (win → next stage, loss → continue counter).
5. **Scenes** `client/src/scenes/`: `StadiumMenu.lua` (copy `ChallengeModeMenu.lua`, take `gameModeId` from
   `sceneParams` like `TrainingMenu`), reuse `CharacterSelectChallenge` as is, `Game1pStadium.lua` (copy
   `Game1pChallenge.lua`), `StadiumRecapScene.lua` (copy `ChallengeModeRecapScene.lua`).
6. **Main menu** `MainMenu.lua`: require `StadiumMenu`, add `mm_1_stadium` and `mm_1_stadium_3d` after
   `mm_1_challenge_mode` (`:102-104`), the 3D one as `StadiumMenu({gameModeId = GameModes.IDs.ONE_PLAYER_STADIUM_3D})`.
7. **Localization**: append at the bottom of `client/assets/localization.csv`: `mm_1_stadium`, `mm_1_stadium_3d`,
   `stadium_difficulty_1..n`, stage/CPU labels; fill EN, leave other columns as best effort like the 3D rows.
8. **Replays**: label and folder for `"stadium"`/`"stadium3d"` in `common/data/ReplayV3.lua:146-221` (otherwise the
   folder is `Unknown`) and `client/src/scenes/ReplayBrowser.lua:195-209` (otherwise "Unknown").
9. **Progress**: add a `stadium` table (best stage cleared per difficulty, 2D and 3D separately) to `Scores`, bump
   `currentVersion` to 6 with an upgrade step, cover it in `client/tests/ScoresTests.lua`.
10. Optional: a single "vs CPU" match (no ladder) in `LocalGameModeSelectionScene` (how `704f1ae4` added 2P VS 3D),
    useful for tuning.

Online: keep Stadium offline (the server's rooms know nothing of CPUs; `NetClient` only sends human inputs).

## A5. Tests

**Runner.** `testLauncher.lua` requires each module in the `allTests` list (`:58-111`) inside `love.update`, one per
frame, under `pcall`; any error fails the run and the exit code (`:140-185`). A new file must be added to the list;
`./testLauncher.lua <filter>` runs matching files only (`:113-136`). Engine tests live in `common/tests/engine/`,
client-dependent ones in `client/tests/`. Each test file is plain Lua: local functions with `assert`, called at the
bottom. Run headless only: `/Users/mcosta/tools/love12-headless/run.sh /Users/mcosta/projects/panel-attack-3d
./testLauncher.lua ComputerPlayerTests`.

**Building a match headlessly.**
- `StackReplayTestingUtils.createEndlessMatch` / `createSinglePlayerMatch(gameMode, panelSource, inputMethod,
  levelData)` (`common/tests/engine/StackReplayTestingUtils.lua:20-64`): `Match(panelSource, rules)`,
  `createStackWithSettings(levelData, false, "controller")` (**`is_local = false`**, so a stack runs at most once per
  `Match:run` with `setMaxRunsPerFrame(1)`), `match:start()`.
- `CylinderTestUtils.createMatch` (`common/tests/engine/CylinderTestUtils.lua:20-36`, 3D endless, no countdown, no
  rise), `clearBoard` (`:40-50`), `setColors(stack, row, {[col] = color})` (`:56-62`), `inputFor("swap", "left")`
  (`:67-74`).
- Fixed boards: `Puzzle({puzzleType = ..., stack = "..."})` with `puzzle:toGameMode()` / `toPanelSource()`
  (`common/engine/Puzzle.lua:456`, `:506`; used in `common/tests/engine/StackTests.lua:8-27`).
- Two stacks: create both, then `match:addTarget(a, b)` both ways (`Match.lua:712-725`; ClientMatch does this for
  `VERSUS`, `ClientMatch.lua:185-192`). Attack engine opponent: `createSimulatedStackWithSettings`
  (`CylinderReplayTests.lua:120-140`).
- Stepping: `simulateMatchUntil(match, clock)` (`StackReplayTestingUtils.lua:85-93`) needs inputs queued in advance;
  for a CPU write the loop yourself: `stack:receiveConfirmedInput(cpu:getInput()); match:run()`.
- Replay round trip: `match:createNewReplay()` before running, `ReplayV3.finalizeReplay(match, replay)` after,
  `reloadReplay` through JSON (`common/tests/engine/CylinderReplayTests.lua:67-76`) and compare a state `snapshot`
  (`:40-53`).
- State equality: `stack:saveIntoRollbackCopy(copy)` + `tableUtils.deep_content_equal` (`Match.lua:215-226`).

**Proposed `common/tests/engine/ComputerPlayerTests.lua`:**

1. *CPU clears a given board*: a puzzle board or `clearBoard` + `setColors` with one known match/chain; run the CPU
   until no matchable panels remain (`stack:matchablePanelCount()`, `Stack.lua:1844`) or `chain_counter` reached N,
   with a frame cap. 2D and 3D (3D with the target behind the tower to force rotation).
2. *CPU never mutates the stack*: snapshot via `saveIntoRollbackCopy` before and after `getInput()` on a busy
   mid-game frame; `deep_content_equal`.
3. *CPU vs CPU is deterministic and ends*: two stacks, `VERSUS`, two CPUs with fixed seeds, loop until
   `match:hasEnded()` (cap e.g. 60·60·5 frames); assert it ended with one winner; run again, assert identical
   `confirmedInput` strings and snapshot.
4. *vs-CPU replay replays without the CPU*: record (3), finalize, reload through JSON, run with no CPU attached,
   compare snapshots (2D and `stadium3d` rules).
5. *No per-frame garbage*: after a warm-up, `collectgarbage("stop")`, count KB across 600 `getInput()` calls, assert
   ~0 (pattern: `renderLauncher.lua:512-536`).
6. Difficulty sanity (slow, maybe filtered out of the default list): hard CPU beats easy CPU in k of n seeds.

Client side (`client/tests/`): a `Stadium` stage-advance test and the `Scores` upgrade test; `PlayerStackRollbackTests.lua:8-23`
shows building a `Player` + `PlayerStack` around an engine stack without a scene.

## A6. Performance constraints

- CONTRIBUTING: in the gameplay loop "avoid the use of shortlived tables to not overwhelm the garbage collector"; no
  LuaJIT `ffi` ("LuaJIT is disabled on Android, our weakest platform"); gameplay graphics derive from state. The
  client runs with GC on automatic: manual GC in `client/src/CustomRun.lua:42-60` is commented out because the game
  allocates so little; a CPU that allocates per frame would be the main garbage source.
- The engine shows the pattern: `table.new` / `table.clear` (`Stack.lua:13`, `checkMatches.lua:8-9`), preallocated
  `confirmedInput` (`Stack.lua:222`), pooled rollback panel copies (`Stack.lua:335-363`), closures hoisted out of hot
  loops (`Match.lua:600-603`).
- Cost multiplies: `GameBase:runGame` can call `Match:run` several times per love frame while catching up
  (`GameBase.lua:315-321`), and a Stadium match runs two full stacks plus the CPU each tick; on Android the Lua is
  interpreted.

What that means for the AI:

- **Board model in preallocated flat arrays** (color, state class, height per column), filled from `stack.panels` in
  place each think; candidate moves as integers (row·width + col), not tables; scores in reused arrays. Returned input
  is a prebuilt string from `KeyDataEncoding.base64encode` (no concatenation).
- **Don't search every frame.** Think when the current plan is finished or invalidated (board changed under it, new
  garbage landed, topped out); otherwise replay the plan's next button state. PPL's CPU works the same way: plan, then
  walk the cursor.
- **Bounded, deterministic search**: 2D one-swap candidates = 12 rows × 5 = 60; two swaps ≈ 3600. On the tower,
  restrict to PPL's 6-column window (SPEC §8) to stay at 2D size, or to a few windows around the cursor. If a deeper
  search is wanted, spread it over frames with a fixed node budget per frame (counted in nodes, never milliseconds,
  so CPU-vs-CPU stays deterministic).
- **No full-engine look-ahead per candidate.** Cloning a `Stack` (rollback copy + `Stack:run`) per candidate costs
  table traffic and emits signals; a settled-board evaluation (apply swap, gravity, find matches, count chain links)
  on the flat model is enough for move choice. A shadow `Stack` reused via `saveIntoRollbackCopy` /
  `restoreFromRollbackCopy` could verify one chosen plan occasionally, not drive the search.
- Difficulty is best expressed as hand limits (reaction delay before acting, frames per cursor step, mistake rate,
  search depth, whether it sets up chains or only clears), all deterministic from the CPU's own RNG.

---

# Part B: prior art

Checked 2026-10-12 through `git log`, the GitHub API (`gh`), web search and the local decomp. Nothing was posted.
"Unverified" means that only search snippets were seen (speedrun.com and Bulbapedia returned 403).

## B1. The real PPL CPU: `puzzleleague64` `src/main/ai.c`

- **Where:** `/Users/mcosta/projects/puzzleleague64/src/main/ai.c` (3392 lines) and `include/ai.h`, upstream
  https://github.com/AngheloAlf/puzzleleague64. **License:** MIT (2023 AngheloAlf) for the decomp, but it reproduces
  Nintendo's logic: read it for tables and strategy, reimplement, don't transliterate. AngheloAlf doesn't want LLM
  contributions there, so this is read-only.
- **Difficulty ladder, read in matched C:** `AISetLevel(brain, game, stage)` (`ai.c:234`) picks Easy, Normal, Hard,
  Super Hard or Ultra (game 1-5); `stage` is the opponent's place in the Stadium ladder. Per difficulty
  (`ai.c:55-173`):
  - `speed` (frames between cursor actions; USA): Easy `35 − (stage−1)/2`, Normal `20 − …`, Hard `16 − …`,
    Super Hard 11 → 7, Ultra 7 → 4 by stage bands; PAL uses slower bands and `ADJUST_FRAMERATE` (`:258-260`).
  - A per-stage technique bitmask (`unk_014`, from `characteristic[]` tables; Easy 0-7, Normal 1-15, Hard
    0x23-0xFF, Super Hard / Ultra up to 0xFF). The table lengths give the ladder lengths: Easy 11 stages, Normal 14,
    Hard 15, Super Hard and Ultra 16.
  - `unk_018` set per stage in `AISetCharacter` (`ai.c:175-232`: −1 … −10, 0 on stages 5/9/11, −99 late) and
    adjusted per difficulty; the subagent's reading (compared with the chain count in `AIChainGarbage1`, so it caps
    how long a chain the CPU builds) is plausible but **unverified**.
  - Vision: `AIChangeVision` (`ai.c:268-285`) scans only the cursor row ±2, columns 0-5; on the tower the window is
    view columns 0-5 (SPEC §8, `ai.c:268` and `ai.c:3282`).
- **Not yet matched:** `UpdateAI` is an m2c draft inside `#if 0`; the technique routines (`AIChainVert1-5`,
  `AIChainHori2-5`, `AIClearGarbage`, `AIFlashCheck`, `AIVolumeCheck`, `AIPossibleCol`, `AICombo3a`) are still
  assembly. Reading them is slower but possible.
- **Verdict:** the best source for *how the Stadium ladder should feel*: an action-rate budget per stage, techniques
  unlocked per stage, limited vision, a cooldown between chains (subagent read `think` as a random 333-443 frame
  pause after a chain; not checked). This maps directly onto a Stadium config table:
  `{difficulty, stage} → {framesPerAction, techniques, chainCap, vision, thinkCooldown}`.

## B2. Panel Attack's own CPU work

| What | URL | License / language | State | Reusable |
|---|---|---|---|---|
| The stub (A1) | this repo, `b962c3fa` (Endaris, 2022-08-01, #579) | zlib, Lua | Interface + DummyCpu only; dead since 2024-05 | The contract (input-device CPU), not the code |
| JamBox's `basicAI` branch | https://github.com/JamesVanBoxtel/panel-attack/tree/basicAI (last commit 2021-11-29, "Fixes and limited actions per think") | No license file; PA code is zlib, so presumably zlib (confirm before reuse) | Never merged. Two CPUs: `computerPlayer.lua` (647 lines: deep-copies the match and both stacks, simulates candidate action sequences with the real engine, scores win/loss, stop time, colour clustering, stack height; thinks in a coroutine capped at `MAX_THINK_TIME = 1/130` s per frame; Easy/Medium/Hard = `inputSpeed` 60/10/5) and `rowBasedCPU.lua` (812 lines, "based on endaris' cpu": rule-based search for H3/V3 matches and V4/V5/T/L combos, costs cursor travel, flags for stealth/insert/slide/catch moves). Written against the 2021 engine (`stack.input_buffer`, `stack.CLOCK`, `deepcopy` of the match) | Ideas and the rule catalogue. Not the code: it allocates heavily (`deepcopy`, `table.insert`, `:copy()` per think) and uses wall-clock budgets, both against A6. Local copies: `/private/tmp/claude-503/-Users-mcosta-projects-mms/c8af54fc-448a-4b2f-ae7c-340ea93f711d/scratchpad/basicai/` |
| JamBox prep work | `89b11af2` (2021-11-28, "Changes in Prep for CPU (#295)": stacks run without a canvas); `Stack.getEstimatedGarbageLinesForCombo` (`common/engine/checkMatches.lua:51`, 2026-09-13) "for … CPU code" | zlib, Lua | In the engine | Use `getEstimatedGarbageLinesForCombo` for attack scoring |
| Upstream stance | issue #113 "Add Vs. CPU opponent." (open; JamBox 2022-03-30: "looking into both a CPU opponent and a story mode, but they are slow going"); #739 "Suggestion: Vs. Computer game mode?" (closed; Endaris: Challenge Mode already covers it, a board-playing CPU "would be a huge undertaking that brings no obvious advantages") | | | Expect a cool reception for a CPU PR upstream; keep it in the fork |
| briankeegan's bot | https://github.com/briankeegan/panel-game, branches `claude/bot-building-hpom4o`, `claude/bot-verification-handoff-w7b53s` (2026-07), `claude/game-bot-creation-action-0e7emk` (2026-10-12) | Fork of PA, no separate license (presumably zlib, unconfirmed); Lua | Large LLM-built `bot/` (BoardSim, CursorController, ThinkBudget, chip/shape caches, many design notes) on the current engine; joins the online server as a bot. Its own `BENCHMARK.md` reports weak play: frozen survival benchmark 11.6 s median, best "large-garbage median 28.7 s", catch mechanic "broken" | Plumbing ideas only (board sim checked against the engine, cursor controller, per-frame budget). Not its decisions |

`panel-attack/panel-attack` (the old repo) answers 404 on the API now, so the #579 discussion can't be read;
`panel-attack/panel-game` has no cpu/ai/bot branches. No Panel Attack AI discussion was found on Reddit, the website
or wikis; Discord history would need someone in the server.

## B3. Open-source Tetris Attack / Panel de Pon / Puzzle League AI

| Project | License / language | What it is, how good | Reusable |
|---|---|---|---|
| https://github.com/a544jh/panel-pop (Panel Pop) | MIT, C++, 45★, pushed 2026-07 | `AI/` has a 2016 greedy "Simple AI": vertical matches, flatten the stack, place blocks for chains. Plays, but weak | Heuristics and structure, license fine |
| https://github.com/CSID-DGU/2018-2-OSSP-PanelpopGameAI | MIT, C++, 2018 student project | Panel Pop AI with evaluation weights (vertical, horizontal, tall columns, block count) tuned by a genetic algorithm | The weight-tuning idea (tune difficulty weights by CPU-vs-CPU runs) |
| https://github.com/gnu-lorien/crack-attack (Crack Attack!) | GPL-2, C++, 2009 | `ComputerPlayerAI` has no board play: timed garbage at Easy/Medium/Hard rates, like PA's Challenge Mode | No (GPL, and PA already has this) |
| https://github.com/loociano/tetris-attack-ai | Apache-2.0, JS, 2014 | 89-line colour counter per row/column | Trivial |
| DamonHolland/TetrisAttackAI, Dateb/TetrisAttackAI, danielmast/tetris_attack | none / none / GPL-3, Python | Play the SNES game from screen pixels through an emulator (Keras / DQN); demo videos, no benchmarks | No |
| https://www.nayuki.io/page/paneldepon-puzzle-solver-javascript | "All rights reserved", TS/Java | Breadth-first puzzle-mode solver (shortest solution) | Algorithm idea for "CPU clears a given board" tests and 3D puzzles |
| https://github.com/cyrus07424/panelDePonUtils | MIT, TS | Has `lib/puzzle/solver.ts` for puzzle mode (not read) | Possibly, for puzzles |

No papers on Panel de Pon / Tetris Attack AI turned up on arXiv or Google Scholar. Other clones checked had no AI
(Bottomless Block Barrage, tetris-attack-js, panel-league, NetPuzzleArena, freeblocks, everpuzzle, JSPDP).

## B4. Write-ups of the original CPUs (unverified, snippets only)

- speedrun.com Panel de Pon guide (https://speedrun.com/panel_de_pon/guides/2vgfz): the TA and PdP CPUs scan top-down
  for matches and clear garbage with combos; TA's switches to chains after stage 8; PdP's keeps a lower stack.
- PPL "Experts Guide to 1P Stadium" (https://www.speedrun.com/nl-NL/pokemon_puzzle_league/guides/ubsuc): garbage grace
  periods and screen shake in Stadium.
- Bulbapedia: the PPL CPU ignores garbage falling into its cursor and can lock up; the Super Hard / Very Hard ladders
  end with Gary then Mewtwo, and losing to Mewtwo means fighting Gary again.
- No Data Crystal RAM map for Tetris Attack and no TASVideos notes on CPU behaviour were found.

## B5. What to use

1. **PPL `ai.c` for the ladder design**: per-stage action rate, technique unlocks, chain cap, vision window,
   cooldown. Reimplemented as a config table, no code copied.
2. **JamBox's `rowBasedCPU.lua` for the move catalogue** (H3/V3 matches, V4/V5/T/L combos, stealth/insert, cursor
   cost), rewritten allocation-free against today's engine. His search CPU shows full-engine look-ahead works but
   is slow, which is why A6 prefers a flat settled-board model.
3. **briankeegan's `bot/` for plumbing only** (engine-checked board sim, cursor controller, budgeted thinking); its
   play is weak by its own numbers.

Nothing found is a drop-in, strong, license-clean Panel Attack CPU; we write our own.

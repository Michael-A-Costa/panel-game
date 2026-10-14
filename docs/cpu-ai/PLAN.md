# CPU AI plan (Pokémon Puzzle League's CPU in Panel Attack)

A real CPU opponent for Panel Attack, ported from Pokémon Puzzle League's own AI, played from the main menu as
"1P vs CPU" and "1P vs CPU 3D" with CPU levels 1–10. The work started as a plan for PPL's 1P Stadium ladder on top of
the CPU; that draft now lives on its own branch (below).

Specs (read before working):

- [AI-SPEC.md](AI-SPEC.md): PPL's CPU function by function, from `src/main/ai.c` and the unmatched asm. The port source.
- [STADIUM-SPEC.md](STADIUM-SPEC.md): PPL's Stadium ladder; also where the CPU's (difficulty, stage) presets come from.
- [INTEGRATION.md](INTEGRATION.md): where a CPU hooks into Panel Attack, the mode recipe, test approach, prior art.
- [BALANCE.md](BALANCE.md): the CPU-vs-CPU ladder check.

Branches, both pushed to `origin` (the public fork):

- `cpu-ai` (off `3d-mode`): the CPU and 1P vs CPU. Agent work happened on `stadium-*` sub-branches in
  `/Users/mcosta/worktrees/panel-attack-3d-<name>`, all merged.
- `stadium` (off `cpu-ai`): the 1P Stadium draft, one revert of the commit that split it out of `cpu-ai`. Rebase or
  merge it onto `cpu-ai` when picking Stadium up again.

**Goal closed 2026-10-13 on the CPU AI.** Stadium picked up again the same day on branch `stadium`: PPL's
progression (see Log).

## Status

- [x] **Research**: AI-SPEC, STADIUM-SPEC, INTEGRATION written; baseline suite green headless.
- [x] **1. CPU plumbing + 1P vs CPU**: a CPU drives a normal `Stack` through `receiveConfirmedInput`; main-menu
  "1P vs CPU" (2D and 3D) with CPU level 1–10; tests for determinism, replay round trip, read-only.
- [x] **2a. PPL CPU core**: RNG, board adapter, brain/queues, helpers, executor, `UpdateAI` cascade with planner slots.
- [x] **2b. PPL CPU planners**: chains (Vert1–5, Hori1–5), garbage and volume, combos and fallback.
- [x] **3. Stadium mode** (branch `stadium`): ladder room, difficulty menu, game scene, pre-match card, recap,
  progress in `stadium.json`, Stadium 3D, and PPL's progression copied: in-match pace (speed schedule, rise times,
  shrinking topout grace), new rows without pairs plus PPL's helper pair by difficulty, story screens between stages,
  endings with credits, Very Hard and Super Hard unlocked by PPL's codes (shown at the Hard and Very Hard endings),
  "Continue?" after a loss, the boss and continued rematches started at once, resume never on the boss, best chain
  and combo saved, PPL's stage select once a difficulty is cleared. Played through end to end by a CPU in the
  player's seat (`testLauncher.lua StadiumPlaythrough`); Michael hasn't played it yet.
- [x] **4. CPU tuning and polish**: 1P vs CPU on PplCpu, SimpleCpu removed, type check back to the 11 pre-existing
  diagnostics, CPU cost ~0.015 ms per frame, CPU-vs-CPU ladder check (BALANCE.md) with two raise fixes.

## Next up (deferred)

1. Michael plays 1P vs CPU (2D and 3D) and says how it feels.
2. CPU review leftovers: `volumeCheck` plans at row −3 on an empty bottom row (`PplGarbage.lua` ~493, add
   `if row < 0` + test); on the tower `shortestDistance` treats a real panel at view column −1 as "none"
   (`PplHelpers.lua` ~297, `PplPlanner.lua` ~268); duplicated scans/constants across PplChains/PplCombos/PplGarbage
   (sort-by-colour, possibleRow retry, raise-under-garbage, `SLIDE_IN`, `SORT_USED`); unreachable checks in
   `PplGarbage.lua` ~52, ~292, ~296.
3. Balance decisions (BALANCE.md): Easy/Normal get weaker when they gain the raise bit (PPL's design); vs-CPU levels
   8 and 9 are out of order (PPL's DemoCPU table); Super Hard mirror matches can stall past 5 minutes.
4. Stadium (branch `stadium`): Michael plays it and says whether PPL's pace is too harsh; Stadium 3D tuning.

The Stadium rows in the decisions table below apply to the `stadium` branch.

## Decisions taken (override any of them)

| Question | Decision | Why |
|---|---|---|
| Port or write our own AI | Port PPL's rule-based CPU, function by function, in idiomatic Lua (not a C transliteration) | The goal is PPL feel; the AI is cheap (no search) and fully documented |
| PPL's bugs (AI-SPEC §8.3) | Keep them in 2D; each one marked `-- PPL:` with the AI-SPEC reference | They are part of how the PPL CPU plays; easy to fix later one by one |
| 3D stale columns (AI-SPEC §5) | Fix: commands store board columns; the planner sees PPL's 6-column view window | Stadium 3D is ours; a CPU that loses its plan after every turn is just broken |
| 2D quick moves | Repeated same-direction moves get an idle frame between them (PA's input repeat) | No engine change; PA players get the same constraint |
| Swap refusal (moves 5/6) | Decide with `stack:canSwap` at move time | Read-only, same rules the swap will meet |
| CPU randomness | Own PPL-style generator per CPU, seeded from the match seed + player number | Never touch the panel RNG; CPU-vs-CPU tests stay deterministic |
| Engine rules | No engine changes for Stadium in phases 1–3; PA's level presets as they are | 2D stays bit-identical; PA levels 1/2/4 already are PPL's VS rows (STADIUM-SPEC §6) |
| PPL speed schedule, rise times, topout decay | On in Stadium (2D and 3D) through the `pplVersus` stack setup modification; every other mode keeps PA's pace | Michael asked for PPL's progression; a match rule like `cylinder`, so v3 replays carry it and old replays don't change |
| PPL's helper pair per row (`newBlock`) | Copied behind `pplHelperPairs` (Easy every row, Normal/Hard every other, Very/Super Hard none); Stadium's level data denies generated pairs (`adjacentDenialFrequency` 1) as PPL's generator does. The pair's column is a hash of the row count instead of a panel RNG roll | The generator's random numbers stay the same in every mode |
| 2P characters unlocked by Stadium progress (PPL: 8 to 14) | Not copied; Michael decided 2026-10-13 to keep every character open | Panel Attack has no character locks (characters are installed mods); a lock would hide characters players already have in every VS mode |
| Topout grace over time | Exact: a topped-out stack loses whatever the grace shrinks by (`Stack:updateHealth`, `pplGrace`) | PPL compares its death counter with the current grace every frame |
| Stage select (PPL's hidden `CHEAT.SBF`) | "Start at stage" on the Stadium menu once the difficulty is cleared | The decomp doesn't show how PPL reaches it; a clear is the closest earned gate |
| Story screens | Text only, no art: PPL's intro, elite and boss intros on the pre-match card (which then waits for a press), the rival/wanderer/rogues scenes after stages 1, 9, 10 as the result line, the boss's win before "Continue?", the rival's return after it, an ending per difficulty and credits from Hard on | Licensing: no PPL characters, names or screens |
| After a loss | PPL's "Continue?": yes costs a continue and replays the stage (the rival after losing the boss); no leaves the run saved on the lost stage, for free. Leaving a match from the pause menu still costs a continue and replays | STADIUM-SPEC §3.7; a pause-quit that cost nothing would dodge every loss |
| Resume | Next stage after the last beaten, capped at 15 as PPL does | Rival and boss are always beaten back to back |
| Opponents | Panel Attack characters, picked per stage from installed characters (stable order); stage 1 and the pre-boss stage share a rival; stage 16 a boss; no Pokémon names or art | Licensing and CONTRIBUTING asset rules |
| Unlocks | PPL's codes on the difficulty select: hold Raise1 (Z) and press Left Left Swap1 Swap2 (L L A B) for Very Hard, Right Left Swap1 Swap2 (R L A B) for Super Hard; the Hard and Very Hard endings show them; remembered per dimension | PPL's own way; Panel Attack has no Z/L/R, so Raise1 and the directions stand in |
| Online | Offline only | Server knows no CPUs |
| Where progress is saved | `stadium.json` (`client/src/StadiumProgress.lua`, own version), not `scores.json` | Upstream builds share the save identity and stop writing `scores.json` once its version is newer than theirs |
| Opponent characters | Fixed per run from the character-select order; only a stage wearing the player's pick gets a stand-in (the first in-between candidate) | Rival and boss must not change when the player changes or re-rolls a character |
| Touch players | Stadium always uses `Game1pStadium`, never `PortraitGame` | PortraitGame has no card, HUD or recap |

## Phases

### 1. CPU plumbing + 1P vs CPU (agent "plumbing")

INTEGRATION.md §A1–A5. Files:

- `common/engine/computerPlayers/ComputerPlayer.lua`: replace the stub's globals with a module + LuaLS-annotated
  interface (`getInput(): string`, configs). Keep `DummyCpu` working or delete it if nothing references it.
- `client/src/CpuPlayer.lua`: `Player` subclass, `human = false`, `isLocal = true`, `isCpu = true`, always ready.
- `client/src/ClientMatch.lua`: build an engine `Stack` for CPUs (`:157`), push `cpu:getInput()` when the stack is
  caught up instead of `send_controls` (`:211-219`), CPU metadata in the replay (`:406`).
- Presets `ONE_PLAYER_VS_CPU` (+ 3D) in `GameModes.lua` (four tables); main-menu items; a level picker (DemoCPU 1–10,
  AI-SPEC §3.5); localization rows at the bottom; replay folder/label.
- Until phase 2 lands, the CPU behind this is a small placeholder that only finds the nearest horizontal 3 (enough to
  prove the wiring and tests). Phase 2 replaces it.
- Tests `common/tests/engine/ComputerPlayerTests.lua` (INTEGRATION §A5 items 2–5): read-only, deterministic CPU vs CPU,
  replay round trip without the CPU (2D and 3D), no per-frame allocation.

### 2a. PPL CPU core (agent "core")

`common/engine/computerPlayers/PplCpu/` (AI-SPEC §7.1): `PplRandom` (exact 32-bit step, f32 output), `PplBoard`
(read-only adapter in PPL 0-based coordinates, 2D and the 3D view window, preallocated), `PplBrain` (fields of §1.2,
command/move queues, scratch arrays preallocated), helpers (§1.9, §1.10), `PplExecutor` (`AIMove`, 2D/3D, PA input
bits, quick-move pacing), `PplPlanner` (`UpdateAI`, `expandCommands`, cooldown, flash check) with the planner cascade
calling planner modules that may still be empty stubs, difficulty presets (§3.4 table, DemoCPU scale). Unit tests on
fixed boards for every helper and the executor; the CPU can play a whole game with only the fallback planner.

### 2b. PPL CPU planners (three agents in parallel, after 2a)

- "chains": AIFlashCheck consumers AIChainVert1/2/3/4/5, AIChainHori1–5 (AI-SPEC §2.1–2.2).
- "garbage": AIClearGarbage, AIChainGarbage1/2, AIChainPack, AIVolumeCheck, AIStupidMove (§2.3, §2.5).
- "combos": AIPossibleRow/Col, AIComboCheck, AICombo3a/3b/45/X (§2.4).

Each planner gets a fixed-board test: the board where PPL would fire it, assert the queued commands and that running
the CPU produces the match/chain. Owner of the merge: me; conflicts only in the cascade file.

### 3. Stadium mode (agent "stadium", parallel with 2b)

INTEGRATION.md §A4 recipe + STADIUM-SPEC §3 flow:

- Ladder data `common/data/StadiumLadder.lua`: per difficulty, stages with CPU preset (difficulty, stage), stack level
  (Easy 1, Normal 2, Hard+ 4), rival/boss flags.
- `client/src/Stadium.lua` (`BattleRoom` subclass, modelled on `ChallengeMode.lua`): win → next stage, draw → replay
  free, loss → continue (counted, unlimited), losing the boss → back to the rival stage.
- Scenes: `StadiumMenu` (difficulty, new game / resume, locked difficulties), `Game1pStadium` (HUD: difficulty,
  stage, continues), `StadiumRecapScene`; reuse `CharacterSelectChallenge`.
- Progress per difficulty, 2D and 3D, last stage beaten and continues: first in `Scores` v6, moved to `stadium.json`
  in phase 4 (see "Decisions taken").
- Presets `ONE_PLAYER_STADIUM` and `ONE_PLAYER_STADIUM_3D`; main-menu items; localization; replay labels.
- Tests: ladder advance/continue/boss-loss rules, scores upgrade.

### 4. Tuning and polish (me + one agent)

- CPU-vs-CPU ladder check: higher stages beat lower ones in most seeded games, 2D and 3D; a CPU at every preset
  finishes a 5-minute game without errors.
- Pre-match card (portraits, stage name) and result card; ending/credits gate per difficulty; unlock messages.
- Performance: frame cost of the CPU on a busy board, allocation check.
- Optional PPL speed schedule (`st_AdvanceLevel`) as a Stadium-only rule if Michael wants it after playing.
- PLAN, README notes; Michael plays it natively (`/Users/mcosta/tools/love12/love.app/...`) only when he asks.

## Rules for every agent

- Upstream CONTRIBUTING.md: 2-space indents, lines < 140, `""` strings, `camelCase`, `ALL_CAPS` constants, LuaLS
  annotations on new classes, multi-line control flow, no `ffi`, no short-lived tables in the gameplay loop,
  localization rows at the bottom of `client/assets/localization.csv`.
- 2D stays bit-identical: no engine rule changes, the whole suite (replays included) must pass.
- The CPU never writes to a stack and never draws from the panel RNG.
- Tests headless only (`/Users/mcosta/tools/love12-headless/run.sh <worktree> ./testLauncher.lua`), never native LÖVE.
- Decomp: read only, leak-free, nothing posted anywhere. Nothing goes to upstream (PRs, issues, Discord).
- Commits as the clone's configured identity, no AI mention in messages.

## Log

- 2026-10-12: Goal set: PPL-style 1P Stadium with a ported CPU. Three research agents wrote AI-SPEC (58 of 61
  functions fully read, including the 17 asm-only ones; per-stage difficulty table), STADIUM-SPEC (ladder 11/14/15/16/16,
  stack levels map to PA 1/2/4, flow, continues) and INTEGRATION (dead CPU hook in `ClientMatch:run`, mode recipe,
  prior art: nothing reusable beyond the decomp). Plan written; branch `stadium` off `3d-mode`.
- 2026-10-13: Phase 1 merged: `ComputerPlayer` registry (`create(name, stack, {seed, level | difficulty+stage})`),
  `CpuPlayer`, CPU inputs injected in `ClientMatch:run` like a human's, 1P vs CPU and 1P vs CPU 3D with a level 1–10
  picker, `SimpleCpu` placeholder, replay round trip without the CPU, zero allocation per frame. Phase 2a merged:
  `PplCpu` core (RNG, board adapter with the 3D view window and board-column commands, brain, helpers, executor,
  `UpdateAI` cascade, presets), with only PossibleRow and the fallback planner live: it clears 21 panels before
  topping out in 2D, so 1P vs CPU stays on SimpleCpu until the planners land. Started chains, garbage, combos and
  Stadium mode agents in parallel.
- 2026-10-13: Phase 4 polish on `stadium-polish`. 1P vs CPU plays PplCpu; SimpleCpu deleted, ComputerPlayerTests
  check PplCpu (registry, read-only, deterministic CPU vs CPU 2D/3D with replay round trip, zero allocation); the
  match owns its CPUs (`ClientMatch.cpus`), `ComputerPlayer` reads the scale sizes from `PplPresets`. Stadium: both
  name bars (opponent = character name), a pre-match card (difficulty, stage x/N, title, both portraits; 3 s or
  Swap/Start), "Gym 3 beaten! Next: Gym 4" after a win, the existing "New difficulty unlocked" recap line checked.
  Progress moved out of `scores.json` (back to v5) into `stadium.json`. Fixed cast per run, touch players keep the
  Stadium scene, menus share `LocalModeMenu`. lua-language-server (`--checklevel=Warning` and `Information`, repo
  `.luarc.json`): 3d-mode 11, stadium before polish 44, now 11 (all pre-existing). CPU frame cost
  (`testLauncher.lua PplCpuBenchmark`, level 10 vs level 10 on PA level 10, 6000 calls after 8 s of play, headless
  arm64 Docker): 2D JIT on mean 0.015 ms, p99 0.17, max 0.56 (trace compiles); JIT off mean 0.029 ms,
  p99 0.10, max 0.16. 3D JIT on mean 0.013 ms, p99 0.13, max 0.47; JIT off mean 0.043 ms, p99 0.10, max 0.17.
  Nothing near the 0.2 ms mean bar. Seen on the way: the 3D CPU at level 8 to 10 tops out within 10 to 15 s on
  level 5 to 10 stacks (the 3D benchmark needed 6 games for 3000 frames, 2D one), and lost to level 3 in the render
  shot (cause not looked into). Left for the balance work.
- 2026-10-13: All planners merged (chains, garbage, combos): in 2D endless the CPU clears 288 panels in 3 minutes
  without topping out and builds ×3 chains. Stadium mode merged as a draft. Polish: 1P vs CPU on PplCpu, SimpleCpu
  removed, Stadium progress moved to `stadium.json` so `scores.json` stays at version 5 (upstream shares the save
  folder), stable opponent cast, CPUs owned by the match. Balance (BALANCE.md, `balanceLauncher.lua`, PplLadderTests):
  strength rises with stage and difficulty (H15 beats H1 100-0, S16 beats S1 90-5 over 100 seeds); fixed a raise on a
  topped-out stack (instant loss in PA, ignored in PPL) and the tower's raise check using only the 6 visible columns
  (levels 8–10 topped out in 10–15 s; now last 5 minutes alone). Goal closed on the CPU AI; branch renamed `cpu-ai`.
- 2026-10-13: Split the Stadium draft onto its own branch `stadium` (off `cpu-ai`); `cpu-ai` keeps the CPU, 1P vs CPU
  and the balance tools, which now use the vs-CPU modes and PPL's stack level per difficulty directly. Docs moved to
  `docs/cpu-ai/`. Suite green, render harness runs, type check at the 11 pre-existing diagnostics.
- 2026-10-13: Stadium picked up again on `stadium` (still one branch off `cpu-ai`, no Stadium commits on the 3D or
  CPU branches): PPL's progression. Engine: `StackSetupModifications.pplVersus`, set by both Stadium presets, swaps in
  `st_AdvanceLevel` (speed +1 after 15 s ×4, 10, 9, 8, 7, 6, then 5 s) and `st_RaiseTimer` (`consts.PPL_*`, checked
  against the decomp data) and shrinks the topout grace with match minutes (`Stack:getMaxHealth`; PPL recomputes it
  every topped-out frame, here it is taken when the stack tops out). Client: a loss asks "Continue?" (Yes/No menu in
  `Game1pStadium`; `Stadium:continueRun`), resume capped at stage 15 (`StadiumLadder.getResumeStage`). Tests:
  PplVersusTests (tables, schedule, grace, other modes untouched), StadiumTests for the question, the boss loss and the
  resume cap; render shot `stadium_continue.png`. Suite green, type check at the 11 pre-existing diagnostics.
- 2026-10-13: Rest of PPL's progression on `stadium`. Engine: `pplHelperPairs` adds PPL's ready-made pair to new
  rows (Init2DNewRow: the right neighbour's color, never on a shock panel or its own color, no three in a row),
  `Stack.newRowCount` for the alternation. Client: story keys per stage in `StadiumLadder` (`introKey`, `beatenKey`),
  endings and credits on the recap, codes instead of clear-unlocks (`StadiumMenu:readCode`, `codeEntered` in
  `stadium.json`), `startDirectly` for the boss and continued rematches (not for the rival after the boss, which PPL
  sends through the pick), best chain and combo per difficulty on the menu. Tests: helper pairs 2D/3D in
  PplVersusTests, codes/bests in StadiumProgressTests, story/codes/direct starts in StadiumTests; shots
  `stadium_story.png`, `stadium_recap.png` (code). Suite green, type check at the 11 pre-existing diagnostics.
- 2026-10-13: Exact shrinking grace (`Stack:updateHealth`, rollback field `pplGrace`), PPL's stage select after a
  clear, and `client/tests/StadiumPlaythrough.lua` (optional, ~25 s): a Super Hard 16 CPU in the player's seat plays
  Easy 2D (11 straight wins), Very Hard 3D (losses at 12 and 15, then the boss) and, as Super Hard 13, Super Hard 2D
  (a 10-minute stall left from the pause menu, a boss loss back to the rival, two lost rival rematches, then rival and
  boss back to back) through the room and ClientMatch; every step checked against PPL's rules. Michael chose to keep
  all characters open instead of PPL's 2P character unlock.

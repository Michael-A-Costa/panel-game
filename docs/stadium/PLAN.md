# Stadium plan (1P vs CPU ladder, Pokémon Puzzle League style)

A real CPU opponent for Panel Attack, ported from Pokémon Puzzle League's own AI, and a 1P "Stadium" ladder built on
it: five difficulties, 11–16 stages each, a recurring rival, a final boss, continues and saved progress. 2D like PPL,
plus a Stadium 3D on the tower (our addition: PPL's Stadium is 2D only).

Specs (read before working):

- [AI-SPEC.md](AI-SPEC.md): PPL's CPU function by function, from `src/main/ai.c` and the unmatched asm. The port source.
- [STADIUM-SPEC.md](STADIUM-SPEC.md): the ladder, per-stage parameters, flow, and how it maps onto Panel Attack.
- [INTEGRATION.md](INTEGRATION.md): where a CPU hooks into Panel Attack, the mode recipe, test approach, prior art.

Branch `stadium` (off `3d-mode`), pushed to `origin` (the public fork). Agent work happens on sub-branches in
`/Users/mcosta/worktrees/panel-attack-3d-<name>` and merges into `stadium`.

## Status

- [x] **Research**: AI-SPEC, STADIUM-SPEC, INTEGRATION written; baseline suite green headless.
- [x] **1. CPU plumbing + 1P vs CPU**: a CPU drives a normal `Stack` through `receiveConfirmedInput`; main-menu
  "1P vs CPU" (2D and 3D) with CPU level 1–10; tests for determinism, replay round trip, read-only.
- [x] **2a. PPL CPU core**: RNG, board adapter, brain/queues, helpers, executor, `UpdateAI` cascade with planner slots.
- [~] **2b. PPL CPU planners**: chains (Vert1–5, Hori1–5), garbage and volume, combos and fallback.
- [~] **3. Stadium mode**: ladder room, difficulty menu, game scene, recap, saved progress, unlocks, Stadium 3D.
- [ ] **4. Tuning and polish**: CPU-vs-CPU difficulty ladder check, pre-match and result cards, endings, playtest.

## Next up

1. Merge phase 2b (chains, garbage, combos) and phase 3 (running in parallel); switch 1P vs CPU from SimpleCpu to
   PplCpu once the planners are in.
2. Phase 4, then Michael plays it.

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
| PPL speed schedule, topout decay, helper pairs | Phase 4, optional, behind new Stadium-only rules if wanted | Harsher than PA; needs Michael's playtest first |
| Opponents | Panel Attack characters, picked per stage from installed characters (stable order); stage 1 and the pre-boss stage share a rival; stage 16 a boss; no Pokémon names or art | Licensing and CONTRIBUTING asset rules |
| Unlocks | Beat Hard → Very Hard; beat Very Hard → Super Hard (PPL uses codes) | No hidden button codes in PA |
| Online | Offline only | Server knows no CPUs |

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
- Progress in `Scores` (version 6 + upgrade + tests): per difficulty, 2D and 3D, last stage beaten and continues.
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

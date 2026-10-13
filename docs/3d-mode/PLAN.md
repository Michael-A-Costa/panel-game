# 3D mode plan

Add Pokémon Puzzle League's 3D (cylinder) mode to Panel Attack. Rules and geometry: [SPEC.md](SPEC.md).

## Status

- [x] **Setup**: fork `Michael-A-Costa/panel-game`, branch `3d-mode` off `beta` (b1f501d). Tests and screenshots run
  headless (Xvfb, software GL, no audio) like CI; the whole suite passes.
- [x] **Plumbing**: `stackSetupModifications.cylinder` builds an 18-wide stack with the SPEC §9 contract fields
  (`rotationTimer`, `rotationDirection`, `getCylinderViewCenter`); presets Endless 3D, Time Attack 3D, 2P VS 3D in
  the menus; `CylinderStackTests` runs a 3D stack for 600 frames.
- [x] **Engine**: 18-column ring behind `stackSetupModifications.cylinder`: 4-frame rotation steps (presses during a
  step dropped), swaps and matches across the seam, wrapped and full-ring garbage, PPL's 3D garbage shapes placed in
  front of the cursor, a generator that closes the ring, PPL's countdown intro, 3D replays stamped `"3d-049"` so
  upstream clients refuse them. 2D output pinned by a generator fingerprint test and the existing replays.
- [x] **Renderer**: `client/src/graphics/CylinderStackRenderer.lua`, PPL's camera and geometry through a vertex shader,
  back-to-front like PPL; tube frame (blue P1, red P2); telegraph shows 12/18-wide garbage as full-row chain; touch
  off for the tower; the countdown intro rises from 6 rows low. `renderLauncher.lua` writes scripted 1P/2P
  screenshots, including `live_` shots driven only by inputs and the engine's rules.
- [x] **Modes**: Endless 3D, Time Attack 3D, 1P vs yourself 3D, 1P training 3D (main menu), local 2P VS 3D (2P local
  menu); offline only. Training 3D isn't covered by the render harness (it can't drive training in 2D either); the
  engine test against an attack engine covers 3D garbage arriving.
- [~] **Verify**: all 50 test files pass headless, type check at the 11 pre-existing diagnostics, live screenshots
  checked against PPL footage. Not yet: Michael playing it with a controller.
- [x] **Upstream review (#147)**: `3d-board` replaces the `if cylinder` branches with a board topology on `Stack`
  (`width` + `wraps`; `columnRightOf`, `getCursorSwapColumns`, `moveCursorHorizontally`, ...), one match path for
  flat and wrapped boards. `3d-challenge` adds Challenge Mode 3D. Both off `3d-mode-pr`, merged in `3d-playtest`
  (own save folder "Panel Attack 3D"); all 52 test files pass.
- [~] **Playtest build**: Windows / macOS / .love packages built from `3d-playtest`; Michael shares them in the PA
  Discord (unofficial, AI use disclosed).

## Next up

1. Michael shares the playtest build in the Discord, plays it, and says what feels off.
2. Challenge 3D balance: challenger garbage lands lower on the tower (3-chain = 12x1, 6-chain = 3 rings) and health
   and rise speed are the 2D values, so it likely plays easier than 2D. Tune once players report back.
3. When upstream wants it: split `3d-board` into the three PRs offered on #147.
4. ~~Hold speed~~: done, PPL's 10-then-every-3 repeat on the tower (a column per 6 frames held).
5. Replay browser: label the 3D modes (`client/src/scenes/ReplayBrowser.lua` ~195) and check a 3D replay plays back.
6. CPU opponent for a vs-CPU "Stadium 3D" (SPEC §8).
7. Later: online 3D (forked server), 3D puzzles.

## Log

- 2026-10-12: Researched prior art (none for Panel Attack; upstream issue #147 is wontfix; JakeSiegers/PuzzleCylinder
  is a Three.js toy with 30 columns; Brandon Kase's PPL browser port is 2D only and private). Wrote SPEC.md from the
  decomp. Forked, installed LÖVE 12, baseline test run. Plumbing commit. Renderer merged (all tests pass, type check
  at the 11 pre-existing diagnostics). Moved every automated LÖVE run into a headless container after native runs
  kept popping windows and playing music. Engine merged; turn sound and the countdown intro hooked up in the client;
  live screenshots (intro, turning, seam match, 12-wide and full-ring garbage landing and turning) look right.
- 2026-10-13: Offered the cleaned branch `3d-mode-pr` on #147. JamesVanBoxtel: code fine, but needs a stack
  abstraction instead of `if cylinder` branches; mode upkeep has a cost, so share a build in the Discord first and try
  challenge mode in 3D. Built `3d-board` (topology refactor, 2D renders byte-identical) and `3d-challenge`, merged
  them into `3d-playtest`, packaged Windows/macOS/.love builds.

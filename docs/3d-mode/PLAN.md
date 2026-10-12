# 3D mode plan

Add Pokémon Puzzle League's 3D (cylinder) mode to Panel Attack. Rules and geometry: [SPEC.md](SPEC.md).

## Status

- [x] **Setup**: fork `Michael-A-Costa/panel-game`, branch `3d-mode` off `beta` (b1f501d). Tests and screenshots run
  headless (Xvfb, software GL, no audio) like CI; the whole suite passes.
- [x] **Plumbing**: `stackSetupModifications.cylinder` builds an 18-wide stack with the SPEC §9 contract fields
  (`rotationTimer`, `rotationDirection`, `getCylinderViewCenter`); presets Endless 3D, Time Attack 3D, 2P VS 3D in
  the menus; `CylinderStackTests` runs a 3D stack for 600 frames.
- [~] **Engine**: 18-column ring behind `stackSetupModifications.cylinder`.
- [x] **Renderer**: `client/src/graphics/CylinderStackRenderer.lua`, PPL's camera and geometry through a vertex shader,
  back-to-front like PPL; tube frame (blue P1, red P2); telegraph shows 12/18-wide garbage as full-row chain; touch
  off for the tower. `renderLauncher.lua` writes scripted 1P/2P screenshots. Not yet seen with the engine's wrapping
  rules.
- [ ] **Modes**: Endless 3D, Time Attack 3D, local 2P VS 3D; offline only.
- [ ] **Verify**: tests, type check, in-game screenshots, side by side with PPL in ares.

## Next up

1. ~~Plumbing~~ (done).
2. Engine rules, each with a test (SPEC §§1–5):
   - cursor wraps the ring; Left/Right start a 4-frame rotation step, ignored while one runs; swap during rotation
     finishes the rotation first
   - horizontal matches across the seam; garbage contact across the seam
   - wrapped garbage spans: support, falling, landing, clearing
   - 3D garbage shapes: combo 3–6 in front, chain ×2 6 wide, ×3 12 wide, ×4+ full ring with (chain − 3) rows
   - row generator checks the seam (only when `cylinder`, so 2D rows stay identical); start 6 rows low
   - 3D replays round-trip; all 2D tests and replays unchanged
3. ~~Renderer~~ (done; recheck screenshots once the engine lands).
4. Modes: menu entries, replay labels, 3D replays refused by older clients (engine version bump).
5. Later: CPU opponent for a vs-CPU "Stadium 3D" (SPEC §8), online 3D (forked server), 3D puzzles.

## Log

- 2026-10-12: Researched prior art (none for Panel Attack; upstream issue #147 is wontfix; JakeSiegers/PuzzleCylinder
  is a Three.js toy with 30 columns; Brandon Kase's PPL browser port is 2D only and private). Wrote SPEC.md from the
  decomp. Forked, installed LÖVE 12, baseline test run. Plumbing commit. Renderer merged (all tests pass, type check
  at the 11 pre-existing diagnostics). Moved every automated LÖVE run into a headless container after native runs
  kept popping windows and playing music.

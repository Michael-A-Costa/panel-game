# 3D mode spec (Pokémon Puzzle League cylinder)

What Pokémon Puzzle League (N64) does in its 3D mode, read from the matching decomp
[AngheloAlf/puzzleleague64](https://github.com/AngheloAlf/puzzleleague64), and how this fork maps it onto Panel Attack.
Citations are paths inside that repo (`src/…`, `asm/usa/…`, `include/…`), USA version.

Tags: **[R]** read directly in matched C, asm or data. **[I]** inferred from code. **[U]** memory of the game, unverified.
PPL code is 0-based (columns 0–17, rows 0–11); Panel Attack is 1-based. Where this doc says "PPL column c", add 1 for
Panel Attack.

## 1. Board

- **[R]** One ring of **12 rows × 18 columns** (`include/unknown_defines.h:24`). Matching, gravity, danger and game over
  all loop over all 18 columns (`src/main/tetris.c:276`, `src/main/animate.c:434`): a panel at the top on the back of
  the tower still tops you out.
- **[R]** The incoming row is generated across all 18 columns. The "not the same colour as the left neighbour" rule
  wraps: column 0 is also checked against column 17 (`src/main/init3d.c:89`). Shock (`!`) panels land in PPL columns
  1–5 (2D: 0–4) (`src/main/init3d.c:22`).
- **[R]** In PPL the cursor never moves sideways: the whole block array shifts one column per rotation step, with
  wrap-around, and the cursor always sits on array columns 4 and 5 (`src/main/update3d.c:45`, `src/main/init3d.c:108`).
  The shift also moves the incoming row, combo/chain icons, garbage spans and explosions.

## 2. Cursor and rotation

- **[R]** Left/Right sets a counter `sx` to ±4, **only if no rotation is running**; it counts down once per frame and
  the array shifts when it reaches 0 (`src/main/animate3d.c:90`, `src/main/update3d.c:162`). Pressing Left moves the
  panels right (column c becomes c+1), i.e. the view turns left.
- **[R/I]** Linear, no easing: one column per 4 frames. Angles come from 20°/15°/10°/5° cos/sin tables indexed by the
  counter (`src/main/update.c:29`, `src/main/update.c:1882`, `src/main/tetris.c:536`). Input runs before the counter
  update and the draw, so the frames shown are 5°, 10°, 15°, then the snapped shift.
- **[I]** Holding a direction: auto-repeat after 10 frames, then every 3; repeats that land mid-rotation are dropped,
  so holding turns about one column per 6 frames (`src/main/controller.c:255`).
- **[R]** Up/Down as in 2D (rows 0–11, 0–10 while the stack is part-way through rising) (`src/main/animate.c:181`).
- **[R]** Left/Right is ignored while the cursor is in state 3 (meaning unknown)
  (`asm/usa/nonmatchings/main/animate3d/Input3D.s:116`).
- **[R, m2c draft]** Swap during a rotation: the swap targets the destination pair, snaps the rotation to finish, then
  swaps (`asm/usa/nonmatchings/main/animate3d/Switch3DBlocks.s:166`). Otherwise swap rules are 2D's; a swap takes 4
  frames. Starting a rotation finishes a running swap immediately (`src/main/animate3d.c:127`).
- **[R]** Swap animation: both panels slide along the cylinder surface 5° per frame, crossing at the centre (centres at
  −5°, 0°, +5°) (`src/main/update.c:1905`, `src/main/draw3d.c:577`).

## 3. Matching, chains, gravity

- **[R]** Horizontal matches wrap. The normal row scan covers columns 0–17 without wrapping; a 3D-only pass then starts
  at column 0, scans forward and backward from 17, and marks runs of 3+ across the seam (`src/main/combo.c:19`,
  `src/main/combo3d.c:105`). Combo size counts cleared panels, so a run marked twice is still counted once
  (`src/main/combo.c:534`).
- **[R, draft]** A cleared run that crosses the seam pops starting from its left end, so pop timing and sound pitch run
  continuously across the seam. Garbage next to a cleared panel is triggered across the seam too (`src/main/update.c:1210`).
- **[R]** Vertical matches, gravity, chains, the combo-size → garbage table and the score tables are shared with 2D
  (`src/main/attack.c:19`).

## 4. Garbage

- **[R]** A garbage block covers columns [start, end); end < start means it wraps; start == end means a full ring
  (`src/main/attack.c:483`).
- **[R]** Combo garbage: 3/4/5/6 wide like 2D, placed inside PPL columns 2–7, centred on the cursor
  (`src/main/attack3d.c:15`).
- **[R]** Chain garbage (`src/main/attack3d.c:134`):
  - ×2: 6 wide (PPL columns 2–7).
  - ×3: 12 wide (PPL column 17 wrapping through 10).
  - ×4 and up: full ring, (chain − 3) rows, capped at 10.
- **[I]** Garbage stays fixed relative to the player's view until it starts falling; only falling or landed garbage
  turns with the tower. So garbage always drops in front of the player (`src/main/update3d.c:74`).
- **[R, asm]** Garbage drops a row when every cell under its span (wrapped cells included) is empty and not mid-swap.
  Clearing converts its bottom row one cell at a time around the ring
  (`asm/usa/nonmatchings/main/combo3d/Compact3DAttack.s`, `asm/usa/nonmatchings/main/attack3d/Change3DAttack.s`).
- **[R]** Sending and receiving are the shared 2D code; only the widths and positions above are 3D-specific.

## 5. Rising, speed, score

- **[R]** A row is 32 rise units in 3D instead of 16 and the rise rate is doubled, so rows per second and manual raise
  (16 frames per row) are unchanged (`src/main/animate.c:95`). The tower starts 6 rows low (`src/main/tetris.c:385`).
- No 3D-specific speed, stop-time or score tables were found.

## 6. Modes

- **[R]** 3D paths exist for endless (plus a 3D title demo), VS (CPU-vs-CPU 3D demo), line-clear modes, puzzle (own
  18-column loader, `src/main/puzzle.c:254`) and the tutorial. The save keeps 2P 3D win counts for three 2P modes
  (`include/player_t.h:98`).
- **[U]** 3D is offered in Marathon, Time Zone, Spa Service, Puzzle and 2P; unsure about Stadium.

## 7. Rendering

- **[R]** Plain N64 3D: no depth buffer, back-face culling, smooth shading, no lighting or fog. Draw order back to
  front: incoming row, back garbage, back panels, front garbage, front panels from the edges toward the centre
  (`src/assets/misc/segment_0CA4A0.c:80`, `src/main/draw3d.c:2403`).
- **[R]** Camera: vertical FOV 33°, aspect 0.88, near 10, far 3000, eye (0, 0, 900) looking at the origin, up +Y
  (`src/main/draw3d.c:2391`). The tower's Y rotation is applied to the model first; after projection the tower is
  shifted in screen space: x +0.06 in 1P, ±0.51 in 2P, y follows the rise (`src/main/update.c:1868`).
- **[R]** Geometry (`src/assets/vertex/cylinder_3d.c`): 20° per column; outer radius ≈ 81, inner ≈ 66 (panels are 15
  deep). PPL column c spans [(c−5)·20°, (c−4)·20°] from the camera axis toward +x (screen right), so the cursor pair
  (columns 4, 5) spans −20°…+20°. Row y = −208 + 32·row; the incoming row is at y = −240. Outer face 33 units tall,
  inner face 32.
- **[R]** Visible: columns 1–8 draw their outer faces (front; 8 columns fully visible). Columns 9–17 and 0 draw their
  inner faces (back); columns 0 and 9 are edge-on at the silhouette (`src/main/draw3d.c:242`, `src/main/draw3d.c:430`).
- **[R]** Brightness: every front vertex is full white (no edge darkening; panels shrink toward the edges only by
  perspective). Back panels show their inner face at vertex colour 100/255 (≈ 39%). The side walls between faces are
  flat dark per-colour tones (`src/main/draw3d.c:522`).
- **[R]** Back cells are drawn only where they show through empty or popped front cells; a table (`block3Dview[8][12]`
  in the GameCube DWARF) shifts which back row shows through by ±1 above and below eye level (row 6)
  (`asm/usa/nonmatchings/main/update3d/Check3DVisibleBlocks.s`). A depth buffer gives the same picture.
- **[R]** Screen sizes in 1P (320×240): row pitch 16 px; front column x positions 105, 115, 131, 151, 171, 191, 207, 217
  (centre panels ≈ 21 px wide, edge panels ≈ 10 px); flat 56×23 cursor sprite at x = 142; clip y 31–221
  (`src/main/attack.c:522`).
- **[R]** Panel textures: 64×32 8-bit sheets of eight 16×16 tiles. Background: a flat 2D image (`src/main/bkground.c:639`).
- **[R]** Explosions and combo/chain icons are drawn only on front columns (1–8; icons 2–7) and jump column to column
  as the tower turns (`src/main/explode3d.c:262`).

## 8. CPU (later phase)

- **[R]** Same planner as 2D; left/right moves become rotations, no 1-frame quick moves, one move type replaced by a
  random move (`src/main/ai.c:3282`). Its view window is array columns 0–5: 4 columns left of the cursor plus the
  cursor pair (`src/main/ai.c:268`).

## 9. How this fork maps it onto Panel Attack

**Switch.** `MatchRules.stackSetupModifications.cylinder = true` (see `common/data/MatchRules.lua`). Replays store
match rules, so a 3D replay rebuilds a 3D stack; every older replay has no flag and stays 6 wide. Every 3D rule sits
behind `stack.cylinder`; 2D must stay bit-identical (test suite + `verificationLauncher.lua`).

**Board coordinates stay fixed.** Instead of shifting the array like PPL, the cursor moves around the ring and the
camera follows it. Same behaviour, no mass panel moves, and every panel keeps its `column`. "PPL array column c" in
the sections above is a **view column**: view column v (0-based, cursor pair = 4, 5) is board column
`((cur_col - 1) + (v - 4)) % 18 + 1`.

**Engine contract** (what the renderer may rely on):

| Field / method | Meaning |
|---|---|
| `stack.cylinder` | true for 3D stacks |
| `stack.width` | 18 when `cylinder`, else 6 |
| `stack.cur_col` | board column of the cursor's left panel, 1–18; the right panel is `cur_col % 18 + 1` |
| `stack.rotationTimer` | frames left in the running rotation step (4 → 0); 0 when idle |
| `stack.rotationDirection` | −1 (Left), +1 (Right), 0 when idle; `cur_col` changes by this when the timer hits 0 |
| `stack:getCylinderViewCenter()` | fractional board column at the screen centre: `cur_col + rotationDirection * (4 - rotationTimer) / 4` while rotating, `cur_col` otherwise. Unit: column c spans [c − 1, c), so `cur_col` is the boundary between the cursor's two panels. Pure function of state, so rollback-safe. |
| garbage panels | `x_offset` = index from the block's left edge counted modulo 18 (a wrapped block's cells at the seam have x_offset continuing past the seam); `width` up to 18; `width == 18` is a full ring |

The renderer must derive everything it draws from stack state at that frame (rollback rule); animation timers it
needs live in the stack.

## 10. Rendering notes

`client/src/graphics/CylinderStackRenderer.lua`, used by `PlayerStack` when `stack.cylinder`.

- PPL's camera and geometry are used as is. Only the final mapping to the screen is Panel Attack's: rows on the front
  are 16 units tall like 2D, so rows, cursor, displacement and HUD line up with the 2D well, and the tower's silhouette
  is scaled to the 96 unit wide 2D well (PPL's 4:3 stretch would make it 113 wide, past the theme's HUD). Still
  stretched sideways, 14% less than PPL.
- Painter's order like PPL (back walls, back faces, front walls, front faces), no depth buffer.
- A plain glass tube (blue P1, red P2) replaces the theme frame and wall; the portrait shows inside it.
- Besides §9 the renderer reads the same fields the 2D renderer does: `panels`, `displacement` (16 units per row),
  `cur_row`, panel `state`/`timer`/`isSwappingFromLeft`, garbage `x_offset`/`y_offset`/`width`/`height`/`metal`, and
  matched garbage `initial_time`/`pop_time`. Rows above `height` are not drawn, as in 2D.
- Dev harness: `renderLauncher.lua` (see its header) writes screenshots of scripted 3D and 2D states.

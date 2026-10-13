# 3D mode

3D mode plays Panel Attack on Pokémon Puzzle League's tower: the stack is a cylinder of 18 columns and the tower turns
under the cursor instead of the cursor moving sideways. The rules below follow the game's code as read in the
[puzzleleague64 decompilation](https://github.com/AngheloAlf/puzzleleague64); code comments name the file a rule
comes from (e.g. `attack3d.c`) where it explains a number.

It is offered as Endless 3D, Time Attack 3D, Training 3D and Challenge Mode 3D in the main menu and as 2P VS 3D in
the local 2P menu, offline only. In Challenge Mode 3D only the player's stack is a tower; the challengers are the same
attack engines and health bars as in 2D.

## Rules

Everything not listed here works as in 2D: rows, rising, speed, stop time, score, chains, the garbage queue.

- **Board**: 12 rows of 18 columns where column 18 neighbours column 1. Gravity, danger and game over cover all 18
  columns, so a panel at the top on the back of the tower still tops you out.
- **Turning**: the cursor always faces the player. Left and Right turn the tower by one column, which takes 4 frames;
  `cur_col` changes when the turn is over. A press during a turn is dropped. Held directions repeat after the usual
  delay and then every 3 frames instead of every frame, so holding turns the tower a column every 6 frames.
- **Swapping**: the cursor can straddle the seam. A swap during a turn finishes the turn and swaps the pair the tower
  turned to.
- **Matching**: horizontal runs continue across the seam. A run pops from left to right as the player sees it, so a run
  across the seam pops in one sweep. Garbage is hit and passes hits on across the seam too.
- **Garbage**: senders queue the same garbage as against a 2D stack and the receiving tower decides where it goes,
  relative to the cursor when the block drops, so it always lands in front of the player:
  - combos and shock garbage keep their size and the 2D rotation of drop columns, two columns further right;
  - a chain of 2 is 6 wide, a chain of 3 is 12 wide and longer chains are a full ring of (chain − 3) rows, at most 10.

  Blocks can wrap around the seam; a full ring has no ends.
- **New rows**: the generator checks columns 18 and 1 like any other neighbours. Shock panels enter in the cursor's
  columns or the three to their left.
- **Countdown**: the tower turns left a column at a time for the first 48 frames while it rises into place from 6 rows
  low.

## View columns

The original numbers the columns as the player sees them: view column 0 is at the left edge of the tower, 1-8 face the
player and the cursor is on 4 and 5. Garbage placement, new shock panels and pop order are defined in view columns;
`Stack:viewToBoardColumn` and `Stack:boardToViewColumn` convert. On a flat board view column v is simply column v + 1,
so the same pop order and shock panel code serves both. The board itself never shifts, unlike in the original, where
the whole array shifts by a column per turn.

## Board topology

Generic code doesn't ask whether a stack is a cylinder. It asks the board, which is `width` columns that either wrap
(`Stack.wraps`, the last column neighbours the first) or not:

| Method | Answers |
|---|---|
| `columnLeftOf`, `columnRightOf` | the neighbouring column, wrapping round the seam; nil past the edge of a flat board |
| `areNeighbourColumns` | if two columns are next to each other, across the seam included |
| `wrapColumn` | any column index brought back onto a wrapped board; unchanged on a flat one |
| `getColumnOffset` | how far right of one column another is, as garbage `x_offset` counts it |
| `getCursorSwapColumns` | the pair of columns the cursor swaps |
| `getCursorColumnAfterMove` | where a horizontal input takes the cursor: clamped on a flat board, round the seam on a wrapped one |
| `viewToBoardColumn`, `boardToViewColumn` | view columns, see above |

Swapping, matching, garbage contact and garbage drops use only these, so they run the same code on both boards. What
remains behind `stack.cylinder` are the 3D mode's own rules, each in one method: the tower turning under the cursor
(`moveCursorHorizontally`), the hold repeat cadence (`inputRepeatInterval`), the countdown intro, garbage placement
(`getGarbagePlacement`), the shock panel columns (`getShockPanelViewColumns`) and touch only raising
(`canTouchSetCursor`). Their cylinder halves live in `common/engine/cylinder.lua`.

## Drawing

`CylinderStackRenderer` draws the tower with the original's geometry (20° per column, outer radius 81, inner radius
66, panels 15 deep, eye 900 units from the axis) in a vertex shader. The projection is scaled so that rows on the front
are 16 units tall like 2D rows and the tower is as wide as the 2D well, which keeps the cursor, row positions and HUD
where they are in 2D. Like the original it paints back to front without a depth buffer: the back of the tower shows
inner faces at 100/255 brightness where the front has gaps, and side walls show along the edges of panels next to gaps.
Explosions only show on the front 8 columns and combo/chain cards on the middle 6.

A plain tube, blue for player 1 and red for player 2, replaces the theme's frame and wall, which are narrower than the
tower. Touch input only raises on the tower, as touching cells can't turn it.

## Code

| What | Where |
|---|---|
| The `cylinder` stack setup flag | `common/data/MatchRules.lua` |
| Board topology, view columns, the input repeat, the countdown | `common/engine/Stack.lua` |
| Turning, the intro turn, garbage and shock panel placement | `common/engine/cylinder.lua` |
| Matches and garbage contact, pop order (one path for both boards) | `common/engine/checkMatches.lua` |
| Garbage falling and landing across the seam | `common/engine/Panel.lua` |
| New rows and shock panels | `common/engine/PanelGenerator.lua`, `common/engine/GeneratorSource.lua` |
| The 3D game modes | `common/data/GameModes.lua` |
| Drawing | `client/src/graphics/CylinderStackRenderer.lua`, used by `client/src/PlayerStack.lua` |
| Tests | `common/tests/engine/StackTopologyTests.lua`, `common/tests/engine/Cylinder*Tests.lua`, `client/tests/CylinderStackRendererTests.lua`, `client/tests/ChallengeMode3DTests.lua` |

The flag is part of the match rules, so replays rebuild the tower. 2D stacks are 6 wide and don't wrap, and behave and
generate exactly as before; `CylinderGeneratorTests` pins the 2D generator output.

Not done yet: online play, a CPU opponent, 3D puzzles, and replay browser labels for the 3D modes.

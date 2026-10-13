# CPU AI spec (Pokémon Puzzle League)

How Pokémon Puzzle League's (N64) computer opponent works, read from the matching decomp
[AngheloAlf/puzzleleague64](https://github.com/AngheloAlf/puzzleleague64) (`src/main/ai.c` plus the unmatched functions
in `asm/usa/nonmatchings/main/ai/`). It is written so the AI can be ported to Lua function by function without
opening the decomp. Which stage uses which settings is in [STADIUM-SPEC.md](STADIUM-SPEC.md) §2 "CPU parameters per
stage"; §3 below repeats that table with what each knob does.

Tags: **[R]** read directly in matched C, asm or data. **[R, m2c]** read in an m2c draft of unmatched asm, with the
doubtful spots checked against the asm. **[R, draft]** read in a hand-written `#if 0` C draft in `ai.c` that does not
match yet. **[I]** inferred from code. **[U]** memory of the game, unverified.

Citations are paths inside the decomp, USA version. `<F>.s:<n>` is short for
`asm/usa/nonmatchings/main/ai/<F>.s` line n. Names come from the GameCube *Puzzle Collection* DWARF dump
(`PANEPON/title/src/panepon/gc/src/ai.c`), which carries the same code with real names. Where the decomp still says
`unk_XXX`, this doc uses the name in the field table (§1.2).

Conventions (all PPL, 0-based): rows 0–11 with **row 0 at the bottom** (new rows push in at row 0 and shift everything
up, `src/main/animate3d.c` `Add3DNewRow`, `src/main/animate2d.c:159`); columns 0–5 in 2D. The cursor covers
`(cursor.x, cursor.x + 1)`, so `cursor.x` is the left cell (0–4 in 2D). Panel Attack is 1-based: add 1 to rows and
columns (§7).

---

## 0. Source status

61 functions (the DWARF list). 44 are matched C. 17 exist only as asm. Of those, `AIVolumeCheck` has
NON_MATCHING C (a register-allocation diff only). `AIFlashCheck`, `AICombo3a`, `AIChainHori1`,
`AIHoriMoveCheckCheck` and `UpdateAI` have `#if 0` drafts in `ai.c`. **The `UpdateAI` and `AIFlashCheck` drafts in
`ai.c` are wrong in places.** This doc uses fresh m2c drafts instead, generated with the project's context and checked
against the asm.

| Function | Source | Understood |
|---|---|---|
| InitAI, AISet{Easy,Normal,Hard,SHard,Ultra}, AISetCharacter, AISetLevel, AISetCursor, AIChangeVision, AISetGarbage, AIAddCommand, AIDelCommand, AISetMove, AIFinishMove, AIClearCommand | matched | fully |
| AIRowPack, AIVertMove, AIHoriMove, AIHoriMoveBlock, AISearchClose, AIMoveAcross, AIShortestD, AISortRows, AIDistance, AILowerRow, AIVisionCheck, AIBoundaryCheck | matched | fully |
| AIPossibleRow, AIComboCheck, AICombo3b, AICombo45, AIComboX, AIScrollCheck, AIChainFrequency, AIClearPosition, AIChainPack, AIChainGarbage1, AIChainGarbage2, AIStupidMove | matched | fully |
| AIMove, AI2DMove, AI3DMove, AISpeedUpMove | matched | fully |
| UpdateAI | asm (m2c) | fully |
| AIFlashCheck, AICombo3a, AIPossibleCol, AIClearGarbage, AIVolumeCheck | asm (m2c / non-matching C) | fully |
| AIChainVert1, AIChainVert3 (`func_8007ACAC_usa`), AIChainVert2, AIChainVert4 | asm (m2c) | fully |
| AIChainHori1, AIChainHori2, AIChainHori3, AIChainHori4, AIChainHori5 | asm (m2c) | fully (Hori3 has a confirmed bug) |
| AIChainVert5 | asm (m2c) | code fully; the intended geometry of its final timed swap is unclear |
| AIHoriMoveCheckCheck | asm (`#if 0` draft, branch 1 of 6 checked against m2c) | code read; purpose inferred |

`func_8007ACAC_usa` is `AIChainVert3(well, brain, type, slide)` (DWARF order and signature) **[R]**.

---

## 1. Architecture

### 1.1 Shape

**[R]** Two stages per frame, each with its own queue:

1. **Planner** `UpdateAI` (once per frame, after match detection). When both queues are empty it runs a fixed-priority
   cascade of *planners*. The first that succeeds appends **commands** (macro steps such as "go to row r" or "slide the
   panel in column a to column b on this row"). When the move queue is empty it then **expands** the next command(s)
   into **moves** (single inputs: left, right, up, down, swap, raise).
2. **Executor** `AIMove` (once per frame, as the CPU's input). It counts down `delay` and, when it reaches 0,
   performs the next move and draws a new random delay of about `speed` frames.

Plans are built from a snapshot of the board and are not re-validated, except that a failed swap clears everything
and several conditions abort the plan (§1.6). There is no search or scoring tree. It is a hand-written rule list:
chain extension first, then garbage, stack height, horizontal or vertical 3s, 4/5 combos, and a fallback.

### 1.2 Data kept between frames (`ai_t`, `brainbrain[2]`)

N64 offsets from `include/ai.h` (size 0x12C). GC names from DWARF (size 0x128; GC has one int less between 0x14 and
0x28, so the GC offsets for 0x18–0x24 do not line up). "Name here" is what this doc uses.

| N64 off | Decomp name | GC DWARF name | Name here | Meaning |
|---|---|---|---|---|
| 0x00 | cursor_x | cursor_x | cursor_x | copy of `cursor.x` taken each planning frame **[R]** |
| 0x04 | cursor_y | cursor_y | cursor_y | copy of `cursor.y` **[R]** |
| 0x08 | unk_008 | think | think | chain cooldown timer: >0 counts down; ≤0 = chain planners allowed; −1 = never cools down (§1.5) **[R]** |
| 0x0C | speed | speed | speed | base frames between moves; −1 = human player (AI off) **[R]** |
| 0x10 | delay | delay | delay | frames until the next move **[R]** |
| 0x14 | unk_014 (u8) | character (u8) | character | technique bitmask (§3.2) **[R]** |
| 0x18 | unk_018 | (step / chain / choice?) | chainLimit | longest chain the CPU will build, as a negative `old_chain` threshold; 0 = "combo character"; −99 = unlimited (§3.3) **[R]** |
| 0x1C | unk_01C | (choice?) | lastPlan | ID of the last planner that succeeded (§6.4). Written, never read **[I]** |
| 0x20 | unk_020 | (step?) | step | chain-setup phase: 0 idle, 1 setting up, 2 setup finished / waiting for the chain to resolve **[R]** |
| 0x24 | unk_024 | garbage | garbageRow | lowest row (≥1) whose column 2 or 3 holds garbage; −1 = none **[R]** |
| 0x28 | t | t | t | vision window top row **[R]** |
| 0x2C | unk_02C | b | b | vision window bottom row **[R]** |
| 0x30 | unk_030 | l | l | vision left column (always 0) **[R]** |
| 0x34 | unk_034 | r | r | vision right column (always 5) **[R]** |
| 0x38 | direction | direction | direction | flash found by AIFlashCheck: 0 none, 11 vertical, 22 horizontal **[R]** |
| 0x3C | where | where | where | vertical: the flash column; horizontal: the flash row **[R]** |
| 0x40 | unk_040 | from | from | first flashing row (vertical) or column (horizontal) **[R]** |
| 0x44 | unk_044 | to | to | last flashing row/column, inclusive **[R]** |
| 0x48 | command[15] | command[15] | commands | `{function, para1, para2}` FIFO, `com_head..com_tail`, count `total_command` **[R]** |
| 0x108 | move[25] | move[25] | moves | byte FIFO `move_head..move_tail` **[R]** |

Which GC name belongs to N64 0x18/0x1C/0x20 is not certain (GC has `choice` as a signed char at 0x15 and `step`,
`chain`, `garbage` at 0x18–0x20) **[I]**. The names above describe behaviour. The queues are linear, not ring
buffers: they are reset to index 0 whenever they drain (§1.6), and nothing bounds-checks them **[R]**.

Shared scratch globals (one copy, not per player), reused by most planners **[R]** (`include/ai.h`, DWARF):

| Global | Shape | Use |
|---|---|---|
| `AIrowCheck` | `int[7][5]` | per colour (index = type − 1): rows of candidate panels |
| `AIcolCheck` | `int[7][5]` | matching columns |
| `AItotCheck` | `int[7]` | per colour: number of candidates. **Also** reused by AIChainGarbage1/AIChainPack/AILowerRow as a per-column lock array (−1 = locked) |
| `AIdistance` | `int[8]` | per colour: cursor distance (18 = invalid); `[7]` = best colour index |
| `chain_check` | `int[2]` (`[4]` on GC) | last frame's `old_chain` per player, updated by `UpdateAnimation` (`src/main/animation.c:121-145`) |
| `gCounter` | int | global frame counter (parity used by AIPossibleRow) |

Port these as per-CPU scratch tables. Sharing them between two CPUs only matters for the bugs that read stale values
(AILowerRow from AIVolumeCheck, §2.5) **[I]**.

### 1.3 Board fields the AI reads

| PPL field | Meaning | Source |
|---|---|---|
| `block[row][col].type` | 0 empty, 1–6 colours, 7 `!` shock panel, ≥8 not matchable (9 = garbage cell; 8, 10, 12 other) | type 9 = garbage `src/main/combo2d.c:102`; 7 = `!` **[I]** from `src/main/init2d.c:49` and `combo.c:422`; "≥8 not matchable" `combo.c:293` **[R]** |
| `block[row][col].state` | 0 idle (resting), 1 falling, 2/3 swapping, 5/6 hover (6 = carries chain flag), 7 flashing (matched, flash phase), 8 face/popping, 9 garbage turned panel | gravity `src/main/combo.c:59-123`, swap `src/main/animate.c:120-150`, 7→8 `src/main/update.c:1221` **[I]** from these |
| `well.unk_43A8` (`old_chain`) | 0 = no chain; decremented once per chain link, so −1 during a ×2, −2 during a ×3, … | `src/main/attack.c:740`, reset `src/main/combo.c:497-514` **[R]**; meaning **[I]** (score index `~old_chain`, `combo.c:247`) |
| `well.unk_43B0` (`raise`) | manual raise in progress (>0) | GC name `raise`; `src/main/ai.c:3133-3149` **[R]** |
| `well.alert` | a non-garbage panel in row 9+ (any of the 18 columns in 3D), or VS garbage reaching row 10; also set by `danger` | `src/main/animate.c:283-336` **[R]** |
| `well.state.death` | game-over grace running **[I]** | `src/main/ai.c:3159` |
| `cursor.state` | 0 calm, 1 panels active (popping or falling), 2 garbage converting, 4 garbage shake, 3 unknown (Input3D ignores left/right in 3) | `src/main/update.c:1476-1483`, `attack2d.c:501`, `attack.c:312` **[R]**; meanings **[I]** |
| `cursor.delay` | swap animation frames left (0 = no swap running) | `src/main/animate2d.c:134-154` **[R]** |
| `cursor.waiting` | frames until dropped panels settle **[I]** | `attack2d.c:580` |
| `CheckFieldActive(well)` | any cell in rows 0–11, columns 0..gMax−1 with state ≠ 0 | `src/main/animate.c:415-428` **[R]** |

### 1.4 Frame order

Per player, per frame, in `src/main/tetris.c:500-600` **[R]**:

1. Auto-rise timer, then `CompactWell` (gravity).
2. `CheckGameInput` → **`AIMove`** when `brainbrain[num].speed ≠ −1`, else the human's `Input2D`/`Input3D`
   (`src/main/animate.c:18-33`). Then `Update2DSwitching`/`Update3DSwitching`.
3. `CheckCollision`, `CheckChainCounter` (may reset `old_chain` to 0), `ComboCount` (match detection), `CheckShake`,
   `CheckIcon`, `StartAttack` (decrements `old_chain` per chain link).
4. **`UpdateAI`** (planning).
5. `UpdateWell`, garbage, cursor, icons, …, `UpdateAnimation` (sets `chain_check[num] = old_chain`), then `AddNewRow`
   if a rise completed (cursor `y` + 1, all rows shift up).

So moves planned on frame N start executing on frame N+1 at the earliest **[R]**. Queued commands hold absolute rows.
When a new row is added, nothing adjusts the queues, so planned rows are one too low **[R, by absence: no other file
references `brainbrain` commands]**. The vertical moves themselves are computed relative to the fresh `cursor_y` at
expansion time.

### 1.5 `UpdateAI` (planner): `UpdateAI.s`, m2c

```lua
function UpdateAI(well, cursor, brain, num)
  local allowChain, combo = false, 0                                -- var_s1, var_s2
  -- chain cooldown (the inlined AIChainFrequency, src/main/ai.c:1678)            UpdateAI.s:53-83
  if brain.think > 0 and well.old_chain ~= 0 then
    brain.think = 0                                                 -- a chain started: cancel the cooldown
  elseif well.old_chain ~= chain_check[num] and well.old_chain == 0 and chain_check[num] >= -2 then
    if brain.think == 0 then brain.think = AnimationRandom(111) + 333 end   -- a x2 or x3 chain just ended
  end
  if brain.think > 0 then brain.think = brain.think - 1 end

  if cursor.delay ~= 0 or well.raise > 0 then return end            -- swap animating / manual raise   :88-93
  brain.cursor_x, brain.cursor_y = cursor.x, cursor.y
  if cursor.state ~= 2 and cursor.state ~= 3 then AISetGarbage(well, brain) end

  local flash = AIFlashCheck(well, brain)                           -- sets direction/where/from/to   :122
  if flash == 0 then
    -- after a finished setup, sit still while the field is busy                  :125-142
    if brain.step == 2 and cursor.state ~= 2 and brain.total_command == 0
       and (cursor.state == 1 or cursor.waiting ~= 0) then
      return
    end
  else
    if brain.step ~= 1 then                                         -- new flash: drop the plan, re-plan
      brain.step = 0; clearQueues(brain)
    elseif AnimationRandom(321) % 3 == 0 then                       -- mid-setup: 1/3 drop it    :149-150
      brain.step = 0; clearQueues(brain)
    else
      brain.direction = 0                                           -- 2/3 keep it, no new chain plan
    end
  end

  if brain.move_head ~= brain.move_tail then return end             -- still executing moves     :172-174

  if brain.total_command == 0 then
    brain.step = 0; clearQueues(brain)
    -- 1. garbage on the board
    if brain.garbageRow ~= -1 then
      if cursor.state == 2 then                                     -- garbage is turning into panels
        if band(brain.character, 0x20) ~= 0 and AIChainGarbage1(well, cursor, brain) ~= 0 then
          brain.lastPlan = 0x1E
        elseif AIChainPack(well, cursor, brain) ~= 0 then
          brain.lastPlan = 0x1F
        else
          AIAddCommand(brain, 14, 0, 0)                             -- placeholder wait (0 frames)
        end
        brain.step = 2
      else
        if AIClearGarbage(well, cursor, brain) ~= 0 then brain.lastPlan = 0x20
        elseif AnimationRandom(1972) % 3 == 0 and AIVolumeCheck(well, cursor, brain, 0) ~= 0 then
          brain.lastPlan = 0x32
        end
      end
    end
    -- 2. extend the running chain off the current flash
    if brain.total_command == 0 then
      if brain.think <= 0 and brain.direction ~= 0 then
        if brain.garbageRow ~= -1 then
          allowChain = brain.garbageRow >= 6 and well.old_chain >= -3
        elseif brain.chainLimit < 0 then
          allowChain = brain.chainLimit < well.old_chain
        elseif brain.chainLimit == 0 then
          allowChain = well.old_chain >= -3
        end
        if allowChain then
          if brain.direction == 11 then
            if AIChainVert1(well, brain) ~= 0 then brain.lastPlan = 11
            elseif AIChainVert2(well, brain) ~= 0 then brain.lastPlan = 12
            elseif band(brain.character, 8) ~= 0 and AIChainVert4(well, brain) ~= 0 then brain.lastPlan = 14
            elseif band(brain.character, 0x10) ~= 0 and well.old_chain ~= 0 and AIChainVert5(well, brain) ~= 0 then
              brain.lastPlan = 15
            end
          else -- 22
            if AIChainHori1(well, brain) ~= 0 then brain.lastPlan = 0x15
            elseif AIChainHori2(well, brain) ~= 0 then brain.lastPlan = 0x16
            elseif band(brain.character, 4) ~= 0 and AIChainHori3(well, brain) ~= 0 then brain.lastPlan = 0x17
            elseif band(brain.character, 8) ~= 0 and AIChainHori4(well, brain) ~= 0 then brain.lastPlan = 0x18
            elseif band(brain.character, 8) ~= 0 and AIChainHori5(well, brain) ~= 0 then brain.lastPlan = 0x19
            end
          end
        end
      end
      -- 3. stack height (raise logic always; flattening only while alert)          :375-379
      if brain.total_command == 0 then
        if AIVolumeCheck(well, cursor, brain, well.alert == 0 and 1 or 0) ~= 0 then brain.lastPlan = 0x33 end
        if brain.total_command == 0 then
          -- 4. simple 3-matches through the cursor
          if AIPossibleRow(well, brain, brain.cursor_y) ~= 0 then brain.lastPlan = 1
          elseif AIPossibleCol(well, brain) ~= 0 then brain.lastPlan = 2
          else
            -- 5. vertical stacks within +/-2 rows of the cursor (the inlined AIVisionCheck)
            brain.l, brain.r = 0, 5
            brain.t = math.min(brain.cursor_y + 2, 11); brain.b = math.max(brain.cursor_y - 2, 0)
            clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
            for i = 0, 7 do AIdistance[i] = 18 end
            AIBoundaryCheck(well, brain); AIComboCheck(well, brain)
            if brain.chainLimit == 0 then
              combo = AIComboX(brain); if combo ~= 0 then brain.lastPlan = 9 end
            end
            if combo == 0 then
              if brain.think <= 0 and band(brain.character, 1) ~= 0 then
                if AnimationRandom(803) % 7 == 0 then                                 -- :467-468
                  combo = AICombo45(brain, 5); if combo ~= 0 then brain.lastPlan = 3 end
                elseif AnimationRandom(566) % 5 == 0 then                             -- :491-492
                  combo = AICombo45(brain, 4); if combo ~= 0 then brain.lastPlan = 4 end
                end
              end
              if combo == 0 then
                if AICombo3a(brain) ~= 0 then brain.lastPlan = 5
                elseif AICombo3b(brain) ~= 0 then brain.lastPlan = 6
                elseif AIVolumeCheck(well, cursor, brain, 0) ~= 0 then brain.lastPlan = 0x34
                else AIStupidMove(well, brain) end
              end
            end
          end
        end
      end
    end
  end

  if brain.total_command > 0 then
    brain.move_head, brain.move_tail = 0, 0
    expandCommands(well, brain)                                     -- §1.7
  end
end
```

`clearQueues` sets `total_command = com_head = com_tail = move_head = move_tail = 0` **[R]**. `band` is bitwise AND.
The RNG calls happen only on the branches shown (the 4-combo roll is skipped when the 5-combo roll hits) **[R]**.

Notes:

- **[R]** The CPU plans only when no swap is animating, no manual raise is running, and both queues are empty.
- **[R]** `step` drives chain timing. Planners that set up a chain set `step = 1` and end with command 11 (or 5),
  whose expansion sets `step = 2`. While `step == 2` and the field is busy, the CPU idles. A **new** flash while not in
  `step 1` throws away the plan, so each new chain link triggers planning of the next link: the chain-extension loop.
- **[I]** The cooldown: after a ×2 or ×3 chain ends (`chain_check` was −1 or −2), difficulties with `think == 0` wait
  333–443 frames (5.5–7.4 s) before building chains or 4/5 combos again. A chain of ×4 or more starts no cooldown.
  `think = −1` (Easy, Very Hard stages 9+, Super Hard) never cools down.

### 1.6 Commands and their expansion

Command codes (`command.function`) **[R]** (UpdateAI's switch, m2c):

| Code | Params | Expands to |
|---|---|---|
| 1 | row | vertical moves from `cursor_y` to `row` (3 = up, 4 = down). **Skipped** when the *next* command is 3, 4 or 5 with `para1 == para2` |
| 2 | col | horizontal moves to `col` (`col < 0` → 0; in 2D `col == 5` → 4, the cursor's left cell can't be 5) |
| 3, 7 | from, to | slide the panel at `from` to `to` on the cursor row (`slide`, below). First, if `step == 1` and `AIHoriMoveCheckCheck(from, to)` added a detour, the whole queue is sped up |
| 4 | from, to | `from = AIShortestD(from, to)` (re-picks the nearest same-coloured idle panel to `to` on the cursor row; written back into the command), then as 3 |
| 5 | from, to | as 3, then the **last** queued move becomes 6 (retrying swap), then `step = 2` |
| 6 | from, to | `slide` then `AISpeedUpMove` (always) |
| 8 | pos1, pos2 | `AIRowPack(pos1, pos2)` |
| 9 | — | one swap (move 5) |
| 10 | — | move 8 (2D: re-centre vision; 3D: becomes a random move) |
| 11 | — | `step = 2` (no moves) |
| 12 | — | move 7 (raise) and `delay = 0` |
| 13 | row, col | **wait** (stays queued) while `cond` holds, below |
| 14 | n | **wait n frames**: `n = n − 1`; consumed when the old `n ≤ 0` (`UpdateAI.s:1167-1172`) |
| 20 | row, col | **wait** while `CheckFieldActive` and `block[row][col]` is empty; consumed when filled or the field is calm |

Command 13: `lim = garbageRow` (12 if none); `r = row − 2`; advance `r` while `r < lim` and `block[r][col]` is empty.
If `(CheckFieldActive or block[row−2][col].type == 0) and r ~= lim`, the command is consumed only once
`block[row][col].state == 1` (falling); otherwise it is consumed at once **[R, m2c `UpdateAI.s:1089-1143`]**.

```lua
function expandCommands(well, brain)                                -- UpdateAI.s ~:560-1185
  repeat
    local cmd = brain.commands[brain.com_head]
    local f = cmd.func
    if f == 13 or f == 20 or f == 14 then
      if not waitDone(well, brain, cmd) then return end             -- keep it queued for next frame
    elseif f == 1 then
      local nxt = brain.commands[brain.com_head + 1]
      if not ((nxt.func == 3 or nxt.func == 4 or nxt.func == 5) and nxt.p1 == nxt.p2) then
        AIVertMove(brain, cmd.p1)
      end
    elseif f == 2 then AIHoriMove(brain, cmd.p1)
    elseif f == 3 or f == 7 or f == 5 then
      if brain.step == 1 and AIHoriMoveCheckCheck(well, brain, cmd.p1, cmd.p2) ~= 0 then AISpeedUpMove(brain) end
      slide(brain, cmd.p1, cmd.p2)
      if f == 5 then
        if brain.move_tail ~= 0 then brain.moves[brain.move_tail - 1] = 6 end
        brain.step = 2
      end
    elseif f == 4 then
      cmd.p1 = AIShortestD(well, brain, cmd.p1, cmd.p2)
      if brain.step == 1 and AIHoriMoveCheckCheck(well, brain, cmd.p1, cmd.p2) ~= 0 then AISpeedUpMove(brain) end
      slide(brain, cmd.p1, cmd.p2)
    elseif f == 6 then slide(brain, cmd.p1, cmd.p2); AISpeedUpMove(brain)
    elseif f == 8 then AIRowPack(brain, cmd.p1, cmd.p2)
    elseif f == 9 then AISetMove(brain, 5)
    elseif f == 10 then AISetMove(brain, 8)
    elseif f == 11 then brain.step = 2
    elseif f == 12 then AISetMove(brain, 7); brain.delay = 0
    end
    brain.total_command = brain.total_command - 1
    brain.com_head = brain.com_head + 1
  until brain.total_command <= 0 or brain.move_head ~= brain.move_tail
end
```

So a plan is expanded lazily: the expander keeps consuming commands until one produces moves, and the rest wait until
those moves have run **[R]**.

`slide(p1, p2)` is the inlined `AIHoriMoveBlock` (`src/main/ai.c:452-493`) **[R]**:

```lua
function slide(brain, from, to)          -- move the panel in column `from` to column `to` along the cursor row
  local start, steps, dir
  if from < to then start, steps, dir = brain.cursor_x, to - from - 1, 2      -- cursor's left cell on `from`
  elseif to < from then start, steps, dir = brain.cursor_x + 1, from - to - 1, 1  -- cursor's right cell on `from`
  else return 0 end
  local n, approach = -1, nil
  if start < from then n, approach = from - start, 2 elseif from < start then n, approach = start - from, 1 end
  for _ = 1, n do AISetMove(brain, approach) end                    -- n = -1: no approach moves
  AISetMove(brain, 5)
  for _ = 1, steps do AISetMove(brain, dir); AISetMove(brain, 5) end
  return -1
end
```

Moves (`brain.moves[i]`) **[R]** (`AI2DMove`, `src/main/ai.c:3173-3280`; `AI3DMove`, `:3282-3359`):

| Move | 2D | 3D |
|---|---|---|
| 1 / 2 | cursor left / right (`Move2DCursorLeft/Right`) | rotate (`Move3DCursorLeft/Right`): starts a 4-frame rotation only if none is running, otherwise does nothing, **but the move is consumed either way** |
| 3 / 4 | cursor up / down | same |
| 5 | swap; if the swap is refused: **clear both queues** | same |
| 6 | swap; it counts as done if it succeeded or both cursor cells are empty, otherwise it is **retried**; `delay = 1` | same, but no `delay = 1` |
| 7 | raise: `well.raise = 1` if 0, else retry | same |
| 8 | `AIChangeVision` (re-centre `t`/`b` on `cursor_y`) | replaced by `AnimationRandom(5) + 1` (a random move 1–5, rarely 6) in place, run on the next turn |
| 11–14 | as 1–4, `delay = 1` (one-frame "quick" moves) | as 1–4, no delay change |
| 15 | as 5, `delay = 1` | as 5 |
| other | nothing, not advanced | same |

A move that "succeeds" advances `move_head`. Moves 6 and 7 retry on failure; the 3D move 8 rewrites its own slot.
The cursor sound plays for moves that moved the cursor **[R]**.

`AISpeedUpMove` (`src/main/ai.c:3361-3389`) **[R]**: for every queued, not yet run move, 3→13, 4→14, 1→11, 2→12, 5→15
(6 and 7 unchanged).

### 1.7 `AIMove` (executor): `src/main/ai.c:3112-3171` [R]

```lua
function AIMove(well, cursor, brain, num)
  -- (demo/pause handling for gMain 387/388 omitted: title demo only)
  if well.raise ~= 0 then
    if well.raise < 0 then well.raise = well.raise + 1 end
    if well.raise > 0 then
      RaiseBlocks(well, cursor)
      if well.raise == 0 then clearQueues(brain) end                -- a finished raise drops every plan
      return
    end
  end
  brain.delay = brain.delay - 1
  if brain.delay <= 0 and brain.move_head ~= brain.move_tail then
    if AnimationRandom(375) % 3 == 0 then brain.delay = brain.speed + AnimationRandom(2)
    else brain.delay = brain.speed - AnimationRandom(2) end
    if well.state.death ~= 0 then brain.delay = brain.speed - AnimationRandom(3)
    elseif brain.step ~= 0 then brain.delay = brain.delay - AnimationRandom(3) end
    if dimension == DIMENSION_2D then AI2DMove(well, cursor, brain, num) else AI3DMove(well, cursor, brain, num) end
  end
end
```

Timing, all **[R]** from the above:

- **Move cadence**: one move per `delay` frames, `delay ≈ speed ± 1` (1/3 of the time `speed + {0,1}`, else
  `speed − {0,1}`); `−{0,1,2}` more while a chain setup runs (`step ≠ 0`); `speed − {0,1,2}` when `state.death ≠ 0`.
- **2D quick moves** (11–15 and 6) set `delay = 1`, so the next move runs on the next frame. In 2D, sped-up queues run
  at one move per frame.
- **No separate "thinking" delay.** `delay` keeps counting down below 0 while the queue is empty, so the first move of
  a fresh plan runs on the frame after it was planned if the previous wait has expired. The only planned pauses are
  commands 13, 14 and 20, `step == 2` idling, and the chain cooldown `think`.
- `InitAI` seeds `delay = speed`, so the first move waits one full `speed`.

### 1.8 `InitAI`, `AISetGarbage`, `AIChangeVision`: `src/main/ai.c:24-53`, `:268-310` [R]

```lua
function InitAI(well, cursor, brain)
  brain.lastPlan, brain.step, brain.garbageRow, brain.direction = 1, 0, -1, 0
  brain.delay = brain.speed
  clearQueues(brain); for i = 0, 24 do brain.moves[i] = 0 end
  brain.cursor_x, brain.cursor_y = cursor.x, cursor.y     -- (2, 5 first, then overwritten)
  AIChangeVision(brain)
  if gSelection == SELECTION_96 then                     -- 1P Stadium (vs CPU) [I]
    if AnimationRandom(317) % 2 == 0 then cmds{1(2), 10}  -- go to row 2, then command 10
    elseif AnimationRandom(66) % 2 == 0 then cmds{1(3), 10}
    end
  end
end
```

```lua
function AISetGarbage(well, brain)               -- skipped by the caller when cursor.state is 2 or 3
  for row = 1, 11 do
    if well.block[row][2].type == 9 or well.block[row][3].type == 9 then brain.garbageRow = row; return end
  end
  brain.garbageRow = -1
end

function AIChangeVision(brain)
  brain.l, brain.r = 0, 5
  brain.t = math.min(brain.cursor_y + 2, 11)
  brain.b = math.max(brain.cursor_y - 2, 0)
end
```

Note that row 0 is never checked for garbage, and only columns 2 and 3 count **[R]**. In 2D every garbage block covers
column 2 or 3, because 3-wide blocks sit at columns 0–2 or 3–5 and wider ones overlap the middle **[I]**.

### 1.9 Helpers (all matched C unless noted) [R]

```lua
-- AIVertMove (ai.c:403): queue |row - cursor_y| moves up (3) or down (4), relative to brain.cursor_y.
-- AIHoriMove (ai.c:424): target = (col == 5 and 2D) and 4 or max(col, 0); queue right (2) / left (1) moves.

function AIRowPack(brain, pos1, pos2)                        -- ai.c:345: bring pos1's and pos2's panels together
  local gap = pos2 - pos1; if gap < 2 then return 0 end
  local left  = math.abs(brain.cursor_x - pos1)
  local right = math.abs(brain.cursor_x - (pos2 - 1))
  if left < right then                                        -- carry pos1's panel rightwards to pos2-1
    local m = (brain.cursor_x < pos1) and 2 or 1
    for _ = 1, left do AISetMove(brain, m) end
    AISetMove(brain, 5); for _ = 1, gap - 2 do AISetMove(brain, 2); AISetMove(brain, 5) end
  else                                                        -- carry pos2's panel leftwards to pos1+1
    local m = (brain.cursor_x + 1 < pos2) and 2 or 1
    for _ = 1, right do AISetMove(brain, m) end
    AISetMove(brain, 5); for _ = 1, gap - 2 do AISetMove(brain, 1); AISetMove(brain, 5) end
  end
  return -1
end

function AIMoveAcross(well, row, from, to)                   -- ai.c:687: can a panel slide from->to on `row`?
  for each col strictly between from and to:
    if block[row][col].type ~= 0 and block[row][col].state ~= 0 then return 0 end   -- a busy panel in the way
    if row ~= 0 and block[row-1][col].type == 0 then return 0 end                   -- it would fall into a hole
  return -1                                                   -- (from == to: -1; endpoints are not checked)
end

function AIShortestD(well, brain, from, to)                  -- ai.c:718
  local row, T = brain.cursor_y, well.block[brain.cursor_y][from].type
  if well.block[row][to].type == T then return to end
  local L, R = -1, -1
  for col = to - 1, brain.l, -1 do if type == T and state == 0 then L = col; break end end
  for col = to + 1, brain.r do     if type == T and state == 0 then R = col; break end end
  if L == -1 then return R end; if R == -1 then return L end   -- may return -1 (see §8)
  return (to - L > R - to) and R or L                          -- tie -> left
end

function AISortRows(row, total, array)                       -- ai.c:763: greedy nearest-neighbour order
  -- repeat `total` times: among unused entries (value ~= 12) pick the one with the smallest |value - row|
  -- (strict <, so the lowest index wins ties); record its INDEX, set row = its value, mark it 12.
  -- array[0..total-1] := the recorded indices.  (If nothing is left, the previous index is recorded again.)
  -- In this doc's Lua, `order = AISortRows(...)` is a 1-based list of those 0-based entry indices:
  -- order[1] is visited first, order[#order] last; `for _, e in ipairs(order)` walks entries in that order.
end

function AIDistance(brain, row, col)                         -- ai.c:803 (cursor covers cx and cx+1)
  local h = (col < brain.cursor_x) and (brain.cursor_x - col) or (col > brain.cursor_x) and (col - 1 - brain.cursor_x) or 0
  return math.abs(brain.cursor_y - row) + h
end

function AISearchClose(brain, pos1, pos2)                    -- ai.c:674: true if pos1 is at least as close
  return math.abs(brain.cursor_x - pos1) <= math.abs(brain.cursor_x - (pos2 - 1))
end

function AIClearPosition(well, brain, row, col)              -- ai.c:2044: push (row,col) sideways into a hole
  if block[row][col].type == 0 then return -1 end
  if col == 0 then if block[row][1].type == 0 then cmds{1(row), 3(0, 1)}; return -1 end
  elseif col == 5 then if block[row][4].type == 0 then cmds{1(row), 3(5, 4)}; return -1 end
  elseif block[row][col+1].type == 0 then cmds{1(row), 3(col, col+1)}; return -1
  elseif block[row][col-1].type == 0 then cmds{1(row), 3(col, col-1)}; return -1 end
  return 0
end

function AILowerRow(well, brain, row, col)                   -- ai.c:826: drop (row,col) into a hole one row down
  if AItotCheck[col] == -1 or row == 0 then return 0 end     -- AItotCheck as column locks (see §1.2)
  local below = row - 1
  for c = col - 1, 0, -1 do
    if block[row][c].type ~= 0 and AItotCheck[c] == -1 then break end
    if block[below][c].type == 0 then
      if AItotCheck[c] ~= -1 then
        if c == col - 1 then cmds{1(below), 3(col, c)} else cmds{1(row), 3(col, c)} end
        return -1
      end
      break
    end
  end
  -- same to the right: c = col+1 .. 5, with c == col+1 as the adjacent case
  return 0
end
```

`AIHoriMoveCheckCheck(well, brain, from, to)` **[R, draft `src/main/ai.c:497-655`; first branch checked against m2c]**:
called only while `step == 1`, before a slide is expanded. Let `y = cursor_y` and `T` = the type at `(y, from)`
(1–7, else return 0). For each column `v` on the slide path (`from+1..to`, or `from−1` down to `to`), it looks for
two `T`s stacked next to row `y` in column `v` that are not state 8:

1. `(y−1, v)` and `(y−2, v)` (needs `y ≥ 2`): queue down 2, `AIHoriMoveBlock(v, v∓1)`, up 2;
2. `(y+1, v)` and `(y+2, v)` (needs `y < 10`): up 1, `AIHoriMoveBlock(v, v∓1)`, down 1;
3. `(y+1, v)` and `(y−1, v)` (needs `1 ≤ y ≤ 10`): up 1, `AIHoriMoveBlock(v, v∓1)`, down 1.

The sign is `−` when sliding right and `+` when sliding left. On the first hit it sets `brain.cursor_x` to where the
detour leaves the cursor (`v − 1` or `v`) and returns −1. The caller then speeds up the whole queue. The vertical
targets are relative: `AIVertMove` measures from the unchanged `brain.cursor_y`. **[I]** Purpose: the slid panel would
otherwise complete a premature vertical 3 in column `v` while crossing it, so one panel of the pair is knocked aside
first.

### 1.10 Board scans used by several planners [R]

```lua
function AIFlashCheck(well, brain)               -- AIFlashCheck.s (the ai.c:1359 draft has a bug: wrong row index)
  local row0, col0 = 0, 0
  while true do
    local r, c = nil, nil
    for row = row0, 7 do                         -- only rows 0..7, columns 0..5
      for col = (row == row0) and col0 or 0, 5 do
        if well.block[row][col].state == 7 then r, c = row, col; break end
      end
      if r then break end
    end
    if not r then brain.direction = 0; return 0 end
    if well.block[r + 1][c].state == 7 then                       -- vertical run
      brain.direction, brain.where, brain.from, brain.to = 11, c, r, r + 1
      for row = r + 2, 11 do if well.block[row][c].state ~= 7 then break end; brain.to = row end
    elseif well.block[r][c + 1].state == 7 then                   -- horizontal run
      brain.direction, brain.where, brain.from, brain.to = 22, r, c, c + 1
      for col = c + 2, 5 do if well.block[r][col].state ~= 7 then break end; brain.to = col end
    else
      brain.direction = 0; return 0                               -- a lone flashing cell ends the search
    end
    if brain.to - brain.from >= 2 then return -1 end
    -- run of 2 (part of an L or a T): resume after it
    if brain.direction == 11 then row0, col0 = brain.to, brain.where + 1
    else row0, col0 = brain.where, brain.to + 1 end
  end
end

function AIScrollCheck(well, brain, heights)     -- ai.c:1465: contiguous stack height per column from row 0
  local limit = (brain.garbageRow ~= -1) and brain.garbageRow or 12
  local total = 0
  for col = brain.l, brain.r do
    local h = 0
    for row = 0, limit - 1 do
      local b = well.block[row][col]
      if (b.type ~= 0 and b.type < 8) or (b.type == 0 and b.state ~= 0) then h = h + 1 else break end
    end
    total = total + h; if heights then heights[col] = h end
  end
  return total
end

function AIBoundaryCheck(well, brain)            -- ai.c:900: per colour, one panel per consecutive row
  local limit = (brain.garbageRow ~= -1) and (brain.garbageRow - 1) or brain.t
  if limit - brain.b < 2 then return end
  for row = brain.b, limit do
    for col = brain.l, brain.r do
      local T, s = well.block[row][col].type, well.block[row][col].state
      if T ~= 0 and s == 0 and AItotCheck[T-1] < 3 then         -- (re)start this colour's list here
        local k = T - 1
        AIrowCheck[k][0], AIcolCheck[k][0], AItotCheck[k] = row, col, 1
        for r2 = row + 1, limit do
          local hit = false
          for c2 = brain.l, brain.r do                          -- leftmost idle T in that row
            if type == T and state == 0 then
              AIrowCheck[k][AItotCheck[k]] = r2; AIcolCheck[k][AItotCheck[k]] = c2
              AItotCheck[k] = AItotCheck[k] + 1; hit = true; break
            end
          end
          if not hit or AItotCheck[k] > 4 then break end
        end
      end
    end
  end
end
```

`AIBoundaryCheck` does not exclude types ≥ 8, so a garbage cell would index `AItotCheck[8]` past the array. In 2D,
garbage can't sit inside the scanned rows. In 3D it can. Skip types ≥ 8 **[I]**.

---

## 2. Planners

Every planner returns −1 (it queued commands) or 0. "cmds{…}" means consecutive `AIAddCommand` calls, written
`code(p1, p2)`. `T` is a colour (type 1–7), `k = T − 1`.

### 2.1 Chain extension, vertical flash (`direction == 11`)

The flash is in column `W = where`, rows `F = from` to `To = to` (3 or more). When it pops, everything above `To` falls
`To − F + 1` rows. Every Vert planner arranges panels so that the fall completes a new match (a chain link).

#### AIChainVert1 (lastPlan 11): `AIChainVert1.s` [R, m2c]

Purpose **[I]**: get the colour sitting just below the flash and stack the same colour above the flash (and under it),
all in column `W`, so the falling panels land on it and match vertically.

```lua
function AIChainVert1(well, brain)
  local canSlide = band(brain.character, 4) ~= 0                    -- :16-19
  if brain.from == 0 or brain.to >= 10 then return 0 end
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W = brain.where
  local L, R                                                        -- 3-column window around W
  if W == brain.l then L, R = W, W + 2 elseif W == brain.r then L, R = W - 2, W else L, R = W - 1, W + 1 end
  for i = 0, 2 do
    local c = L + i
    local b = well.block[brain.from - 1][c]                         -- the cell just below the flash row span
    local T = b.type
    if T ~= 0 and T < 8 and b.state == 0 and AItotCheck[T-1] == 0 then
      local k, above = T - 1, 0
      push(k, brain.from - 1, c)                                    -- entry 0 (push = append row/col, tot++)
      if brain.from - 2 >= 0 then                                   -- one more under it
        for c2 = L, R do if isIdle(c2, brain.from - 2, T) and AIMoveAcross(well, brain.from - 2, c2, W) ~= 0 then
          push(k, brain.from - 2, c2); break end end
      end
      local hitTop = false
      for c2 = L, R do if isIdle(c2, brain.to + 1, T) and AIMoveAcross(well, brain.to + 1, c2, W) ~= 0 then
        push(k, brain.to + 1, c2); above = above + 1; hitTop = true; break end end
      if AItotCheck[k] >= 2 and hitTop then
        for c2 = L, R do if isIdle(c2, brain.to + 2, T) and AIMoveAcross(well, brain.to + 2, c2, W) ~= 0 then
          push(k, brain.to + 2, c2); above = above + 1; break end end
        local slide = 0
        local proceed = true
        if not canSlide then
          proceed = AItotCheck[k] ~= 2                              -- without bit 4 a pair isn't enough
        else
          slide = (AItotCheck[k] == 2 and above == 2) and 222 or 111  -- 222 is unreachable: tot counts entry 0 [I]
        end
        if proceed then
          if AItotCheck[k] >= 3 then
            if band(AnimationRandom(516), 1) == 0 then AItotCheck[k] = 3 end        -- :350-355 keep only 3
            if slide ~= 0 and band(AnimationRandom(516), 1) == 0 then slide = 0 end -- :358-366
          end
          local order = AISortRows(brain.cursor_y, AItotCheck[k], rowsOf(k))
          for _, e in ipairs(order) do
            if AIcolCheck[k][e] ~= W then cmds{1(AIrowCheck[k][e]), 4(AIcolCheck[k][e], W)} end
          end
          if slide ~= 0 and AIChainVert3(well, brain, T, slide) ~= 0 then
            brain.step = 1; return -1                               -- Vert3 ends with command 5
          end
          if AItotCheck[k] >= 3 then cmds{11}; brain.step = 1; return -1 end
          -- only 2 panels and no slide-in: take every queued command back (com_tail -= total_command)
          brain.com_tail = brain.com_tail - brain.total_command; brain.total_command = 0
        end
      end
    end
  end
  return 0
end
```

`isIdle(c, r, T)` means `block[r][c].type == T and state == 0`. The second `AnimationRandom(516)` call happens only
when `slide ≠ 0` **[R]**.

#### AIChainVert3 = `func_8007ACAC_usa` (called by Vert1): `func_8007ACAC_usa.s` [R, m2c]

Purpose **[I]**: completes a 2-panel vertical setup by sliding a `T` sideways into the flash column at a row inside the
flash, at the moment that cell pops. The final swap retries until it succeeds (command 5 → move 6).

```lua
function AIChainVert3(well, brain, T, slide)
  local W = brain.where
  local lowest = (slide == 222) and brain.from or (brain.from + 1)
  for row = brain.to - 1, lowest, -1 do                             -- top-down through the flash rows
    local left = -1
    for c = W - 1, brain.l, -1 do                                   -- nearest reachable T on the left
      if isIdle(c, row, T) and AIMoveAcross(well, row, c, W) ~= 0 then left = c; break end
    end
    for c = W + 1, brain.r do                                       -- nearest reachable T on the right
      if isIdle(c, row, T) and AIMoveAcross(well, row, c, W) ~= 0 then
        if left == -1 or not ((W - left) < (c - W)) then cmds{1(row), 5(c, W)}; return -1 end  -- right if not farther
        cmds{1(row), 5(left, W)}; return -1
      end
    end
    if left ~= -1 then cmds{1(row), 5(left, W)}; return -1 end
  end
  return 0
end
```

#### AIChainVert2 (lastPlan 12): `AIChainVert2.s` [R, m2c]

Purpose **[I]**: a horizontal 3 on row `F`. Two `T`s already on row `F` get slid next to the column, and one `T` from
row `To + 1` gets slid into column `W`. When the flash pops, that `T` falls to row `F` between or beside them.

```
before (W = flash column, rows F..To = 3..5):   after setup:          after the pop:
row6  . . T . .      (T at To+1)                . . . T .  (col W)
row5  . . . * .      * = flashing               . . . * .
row4  . . . * .                                 . . . * .
row3  T . . * T      (T's on row F)             . . T * T             . . T T T  -> match
```

```lua
function AIChainVert2(well, brain)
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W, F = brain.where, brain.from
  for T = 1, 7 do
    local k, nl, nr = T - 1, 0, 0
    for c = W - 1, brain.l, -1 do                                   -- left on row F, nearest first, up to 2
      if isIdle(c, F, T) and AIMoveAcross(well, F, c, W - 1) ~= 0 then
        AIrowCheck[k][nl], AIcolCheck[k][nl] = F, c; nl = nl + 1; if nl >= 2 then break end
      end
    end
    for c = W + 1, brain.r do                                       -- right on row F -> slots 2, 3
      if isIdle(c, F, T) and AIMoveAcross(well, F, c, W + 1) ~= 0 then
        AIrowCheck[k][2+nr], AIcolCheck[k][2+nr] = F, c; nr = nr + 1; if nr >= 2 then break end
      end
    end
    if nl + nr >= 2 then
      local found = false
      for c = brain.l, brain.r do                                   -- one T on row To+1 -> slot 4
        if isIdle(c, brain.to + 1, T) and AIMoveAcross(well, brain.to + 1, c, W) ~= 0 then
          local d = W - c; if d <= 0 then d = -W - c end            -- [R] asm typo (:225-231): right side unlimited
          if d < 4 then AIrowCheck[k][4], AIcolCheck[k][4] = brain.to + 1, c; found = true; break end
        end
      end
      if found then
        local rows = {12, 12, 12, 12, 12}                           -- choose 3 of the 5 slots
        if nl == 2 then rows[1], rows[2] = AIrowCheck[k][0], AIrowCheck[k][1]
        elseif nr == 2 then rows[3], rows[4] = AIrowCheck[k][2], AIrowCheck[k][3]
        else rows[1], rows[3] = AIrowCheck[k][0], AIrowCheck[k][2] end      -- nl == nr == 1
        rows[5] = AIrowCheck[k][4]
        local order = AISortRows(brain.cursor_y, 5, rows)           -- inlined; use the first 3 results
        local target = {[0] = W - 1, W - 2, W + 1, W + 2, W}
        for i = 1, 3 do
          local s = order[i]
          if AIcolCheck[k][s] ~= target[s] then
            cmds{1(AIrowCheck[k][s]), ((s == 4) and 4 or 3)(AIcolCheck[k][s], target[s])}
          end
        end
        cmds{11}; brain.step = 1; return -1
      end
    end
  end
  return 0
end
```

No RNG **[R]**. Rows `To+1`/`To+2` are not bounds-checked in Vert2/4/5; with `To == 11` the original reads past the
board **[R]** (port: treat rows ≥ 12 as empty).

#### AIChainVert4 (lastPlan 14, needs bit 8): `AIChainVert4.s` [R, m2c]

Purpose **[I]**: a `T` just above the flash goes into column `W`. Two `T`s on row `F + 1` (inside the flash height,
beside the column) wait next to it. Then a "plug" panel on row `F + 1` is slid into column `W` with a retrying swap
(command 5), which fires once that flashing cell has popped. The plug drops to `F`, so the falling `T` lands at `F + 1`
next to the pair: a horizontal 3.

```
row To+1   . . T(.)  .        T moved into col W
row F+1    T T  *   P         T,T at W-2,W-1; P = plug at W+1 (must be non-empty)
row F      . .  *   .         after the pop: P slides into W (falls to F); T lands at F+1 -> T T T
```

```lua
function AIChainVert4(well, brain)
  local W, F = brain.where, brain.from
  if W == brain.l or W == brain.r then return 0 end
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  for i = 0, 2 do
    local c0, top = W - 1 + i, brain.to + 1
    local T, s = well.block[top][c0].type, well.block[top][c0].state
    if T ~= 0 and T < 8 and s == 0 and AItotCheck[T-1] == 0 then
      local k = T - 1
      AIrowCheck[k][0], AIcolCheck[k][0], AItotCheck[k] = top, c0, 1
      local nl, nr, row = 0, 0, F + 1
      for c = W - 1, brain.l, -1 do                                 -- no early break: slots 1, 2, 3…
        if isIdle(c, row, T) and AIMoveAcross(well, row, c, W - 1) ~= 0 then
          AIrowCheck[k][1+nl], AIcolCheck[k][1+nl] = row, c; nl = nl + 1; AItotCheck[k] = AItotCheck[k] + 1 end
      end
      for c = W + 1, brain.r do                                     -- no early break: slots 3, 4…
        if isIdle(c, row, T) and AIMoveAcross(well, row, c, W + 1) ~= 0 then
          AIrowCheck[k][3+nr], AIcolCheck[k][3+nr] = row, c; nr = nr + 1; AItotCheck[k] = AItotCheck[k] + 1 end
      end
      if AItotCheck[k] ~= 1 then
        local plugR = well.block[F + 1][W + 1].type ~= 0
        local plugL = well.block[F + 1][W - 1].type ~= 0
        if nl == 2 and plugR then
          cmds{1(r0), 3(c0, W), 1(AIrowCheck[k][1]), 3(AIcolCheck[k][1], W-1),
               1(AIrowCheck[k][2]), 3(AIcolCheck[k][2], W-2), 1(F+1), 5(W+1, W)}
          brain.step = 1; return -1
        end
        if nr == 2 and plugL then
          cmds{1(r0), 3(c0, W), 1(AIrowCheck[k][3]), 3(AIcolCheck[k][3], W+1),
               1(AIrowCheck[k][4]), 3(AIcolCheck[k][4], W+2), 1(F+1), 5(W-1, W)}
          brain.step = 1; return -1
        end
        -- one side has a single T: fetch a second from row F+2 on the other side (first hit)
        if nl == 1 then
          for c = W + 1, brain.r do if isIdle(c, F+2, T) and AIMoveAcross(well, F+2, c, W+1) ~= 0 then
            AIrowCheck[k][2], AIcolCheck[k][2] = F + 2, c; nl = 2; break end end
        elseif nr == 1 then
          for c = W - 1, brain.l, -1 do if isIdle(c, F+2, T) and AIMoveAcross(well, F+2, c, W-1) ~= 0 then
            AIrowCheck[k][4], AIcolCheck[k][4] = F + 2, c; nr = 2; break end end
        end
        if (nl == 2 and plugR) or (nr == 2 and plugL) then
          if nl ~= 0 then
            cmds{1(r0), 3(c0, W), 1(AIrowCheck[k][1]), 3(AIcolCheck[k][1], W-1),
                 1(AIrowCheck[k][2]), 3(AIcolCheck[k][2], W+1)}
          else
            cmds{1(r0), 3(c0, W), 1(AIrowCheck[k][3]), 3(AIcolCheck[k][3], W+1),
                 1(AIrowCheck[k][4]), 3(AIcolCheck[k][4], W-1)}
          end
          cmds{1(F+1), 5((nl ~= 0) and W+1 or W-1, W)}
          brain.step = 1; return -1
        end
      end
    end
  end
  return 0
end
```

`r0, c0` = entry 0. No RNG **[R]**. The side scans don't stop, so 3 or more hits on one side overflow the 5-slot rows
(slot 5 is the next colour's slot 0) and never plan from that side. Use 6-slot scratch rows in a port **[R/I]**.

#### AIChainVert5 (lastPlan 15, needs bit 0x10 and a running chain): `AIChainVert5.s` [R, m2c]

Same ingredients as Vert4 (a `T` at `To + 1` near `W`, a pair on row `F + 1`), but it ends with a **timed swap**:
the cursor parks on row `F` beside the column, command 13 waits until the column above starts falling
(`block[F+2][W].state == 1`), then a plain swap (command 9) fires. It first knocks aside a `T` sitting at `(To+2, W)` with
a sped-up slide (command 6).

```lua
function AIChainVert5(well, brain)
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W, F = brain.where, brain.from
  for i = 0, 2 do
    local c0, top = W - 1 + i, brain.to + 1
    if c0 >= 0 and c0 <= 5 then                                      -- hard-coded 0..5, not l..r (:42)
      -- entry 0 and the two side scans on row F+1: exactly as AIChainVert4
      if AItotCheck[k] ~= 1 then
        local onTop = well.block[top + 1][W].type == T
        if nl == 2 then
          if onTop then cmds{1(top+1), 6(W, W-1)} end
          cmds{1(r0), 3(c0, W), 1(row1), 3(col1, W-1), 1(row2), 3(col2, W-2), 1(F), 2(W-1)}
          tail(); return -1
        end
        if nr == 2 then
          if onTop then cmds{1(top+1), 6(W, W+1)} end
          cmds{1(r0), 3(c0, W), 1(row3), 3(col3, W+1), 1(row4), 3(col4, W+2), 1(F), 2(W)}
          tail(); return -1
        end
        if nl == 1 and nr == 1 then
          if onTop then
            cmds{1(top+1)}
            if band(AnimationRandom(100), 1) == 0 then cmds{6(W, W-1)} else cmds{6(W, W+1)} end   -- :685-691
          end
          cmds{1(r0), 3(c0, W), 1(row1), 3(col1, W-1), 1(row3), 3(col3, W+1)}
          if band(AnimationRandom(100), 1) == 0 then cmds{1(F), 2(W-1)} else cmds{1(F), 2(W)} end -- :836-841
          tail(); return -1
        end
      end
    end
  end
  return 0
end
-- tail(): cmds{13(F+2, W), 9, 11}; brain.step = 1                   (:912-944)
```

`rowN/colN` = `AIrowCheck[k][N]/AIcolCheck[k][N]`. **Open**: what the timed swap on row `F` builds is not clear from the
code (§8).

### 2.2 Chain extension, horizontal flash (`direction == 22`)

The flash is in row `W = where`, columns `from..to`. When it pops, the cells above those columns fall one or more rows.

#### AIChainHori1 (lastPlan 0x15): `AIChainHori1.s` [R, m2c]

Purpose **[I]**: a vertical 3 through the flash row. `T`s just below the flash row (rows `W − 1`, `W − 2`) and just
above it (`W + 1`, `W + 2`) are slid into one column `X` inside `from..to`. When the flash pops, the upper ones land on
the lower ones.

```lua
function AIChainHori1(well, brain)
  if brain.from == 0 then return 0 end                 -- [R] tests `from` (a column), not `where`; see below
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W = brain.where
  local lo, hi                                         -- scan window (one column of margin)
  if brain.from == brain.l then lo, hi = brain.from, brain.to + 1
  elseif brain.to == brain.r then lo, hi = brain.from - 1, brain.to
  else lo, hi = brain.from - 1, brain.to + 1 end
  for c = lo, hi do
    local b = well.block[W - 1][c]
    local T = b.type
    if T ~= 0 and T < 8 and b.state == 0 and AItotCheck[T-1] == 0 then
      local k = T - 1
      push(k, W - 1, c)
      if W - 2 >= 0 then for c2 = lo, hi do if isIdle(c2, W-2, T) then push(k, W-2, c2); break end end end
      local hitUp = false
      for c2 = lo, hi do if isIdle(c2, W+1, T) then push(k, W+1, c2); hitUp = true; break end end
      if AItotCheck[k] >= 2 and hitUp then
        for c2 = lo, hi do if isIdle(c2, W+2, T) then push(k, W+2, c2); break end end
        if AItotCheck[k] >= 3 then
          local order = AISortRows(brain.cursor_y, AItotCheck[k], rowsOf(k))
          local X = AIcolCheck[k][order[#order]]                  -- column of the last-visited entry
          if X < brain.from then X = brain.from
          elseif X > brain.to then X = brain.to
          else
            local first = AIcolCheck[k][order[1]]
            if math.abs(brain.cursor_x - (first - 1)) < math.abs(brain.cursor_x - X) then X = first end
          end
          for _, e in ipairs(order) do
            if AIcolCheck[k][e] ~= X then cmds{1(AIrowCheck[k][e]), 4(AIcolCheck[k][e], X)} end
          end
          cmds{11}; brain.step = 1; return -1
        end
      end
    end
  end
  return 0
end
```

No `AIMoveAcross` checks and no RNG **[R]**. The guard checks `from ≠ 0`, but the reads use row `W − 1`. With
`W == 0` (a flash on the bottom row) the original reads `block[−1][…]`, memory before the board **[R code, I effect]**.
Port: treat row −1 as empty.

#### AIChainHori2 (lastPlan 0x16): `AIChainHori2.s` [R, m2c]

Purpose **[I]**: a horizontal 3 on the flash row. One or two `T`s from row `W + 1` are slid onto the flash ends.
Two or one `T`s already in row `W` are parked beside the flash. After the pop the upper ones drop in next to them.
It always uses exactly 3 panels.

```
row W+1:  . . T T . .                         . . . . . .
row W  :  T . * * * .   plan: T(W+1) -> cols 1,2; T(W) at col 0 stays at from-1   =>  . T T T . .
```

```lua
function AIChainHori2(well, brain)
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W = brain.where
  for T = 1, 7 do
    local k, same = T - 1, {}                                  -- same[col] = -1 if idle T in row W+1
    local count, left, right = 0, 0, 0
    for col = brain.l, brain.r do
      if isIdle(col, W + 1, T) then
        if count < 2 then AIrowCheck[k][count], AIcolCheck[k][count] = W + 1, col end
        same[col] = -1; count = count + 1
      end
    end
    if count > 0 then
      local need = (count == 1) and 2 or 1
      local side = 0                                           -- 1 = left of the flash, 2 = right
      for col = brain.from - 1, brain.l, -1 do
        if isIdle(col, W, T) then
          AIrowCheck[k][2+left], AIcolCheck[k][2+left] = W, col; left = left + 1
          if left == need then side = 1; break end
        end
      end
      if side == 0 then
        for col = brain.to + 1, brain.r do
          if isIdle(col, W, T) then
            AIrowCheck[k][2+right], AIcolCheck[k][2+right] = W, col; right = right + 1
            if right == need then side = 2; break end
          end
        end
      end
      if side ~= 0 then
        local used = count
        if count >= 3 then                                     -- re-pick which two above-panels to use
          local inFlash = 0
          for col = brain.from, brain.to do if same[col] == -1 then inFlash = inFlash + 1 end end
          used = 0
          if inFlash == 2 then
            for col = brain.from, brain.to do if same[col] == -1 then
              AIcolCheck[k][used] = col; used = used + 1; if used == 2 then break end end end
          elseif inFlash ~= 1 then
            used = 2
          else
            for col = brain.from - 1, brain.l, -1 do if same[col] == -1 then
              AIcolCheck[k][used] = col; used = used + 1; break end end
            local stop = (used == 1) and brain.to or brain.r
            for col = brain.from, stop do if same[col] == -1 then
              AIcolCheck[k][used] = col; used = used + 1; if used == 2 then break end end end
          end
        end
        local rows = {AIrowCheck[k][0], (used == 2) and AIrowCheck[k][1] or 12,
                      AIrowCheck[k][2], (left == 2 or right == 2) and AIrowCheck[k][3] or 12}
        local order = AISortRows(brain.cursor_y, 4, rows)      -- inlined; first 3 used
        local done, target = false, nil
        for i = 1, 3 do
          local idx = order[i]
          if idx == 2 then target = (side == 1) and brain.from - 1 or brain.to + 1
          elseif idx == 3 then target = (side == 1) and brain.from - 2 or brain.to + 2 end
          if idx < 2 then
            if not done then
              if used == 2 then
                local a, b = AIcolCheck[k][0], AIcolCheck[k][1]
                if side == 1 then
                  if b < brain.from + 1 then cmds{1(W+1), 3(b, brain.from+1), 1(W+1), 5(a, brain.from)}
                  else cmds{1(W+1), 3(a, brain.from), 1(W+1), 5(b, brain.from+1)} end
                else
                  if a < brain.to - 1 then cmds{1(W+1), 3(b, brain.to), 1(W+1), 5(a, brain.to-1)}
                  else cmds{1(W+1), 3(a, brain.to-1), 1(W+1), 5(b, brain.to)} end
                end
              else
                target = (side == 1) and brain.from or brain.to
                if AIcolCheck[k][0] ~= target then cmds{1(W+1), 4(AIcolCheck[k][0], target)} end
              end
              done = true
            end
          elseif AIcolCheck[k][idx] ~= target then
            cmds{1(W), 5(AIcolCheck[k][idx], target)}
          end
        end
        cmds{11}; brain.step = 1; return -1
      end
    end
  end
  return 0
end
```

No RNG, no `AIMoveAcross` **[R]**. The side panels and the last above-panel slide use command 5, so their final swap
retries until it succeeds.

#### AIChainHori3 (lastPlan 0x17, needs bit 4): `AIChainHori3.s` [R, m2c]

Purpose **[I]**: one `T` on each side of the flash in row `W`, plus a third `T` either anywhere in row `W + 1` (when
nothing sits on the flash) or as the single panel on top of the flash. Park one side panel, put the third on that flash
end, bring the other side panel to the far end and swap it **into** the flash cell the moment it opens (command 5,
retried). Then run it under the cleared row (command 6) next to the parked one. The upper `T` falls into the gap:
`T T T`.

```
row W+1: . T . . . .      1) T(W,0) -> col 0 (from-1)   2) T(W+1,1) -> col 1 (from)
row W  : T * * * . T      3) T(W,5) -> col 4 (to+1)     4) col 4 -> col 3 (into the flash once it pops, retried)
          from=1 to=3     5) col 3 -> col 2 (from+1), sped up      => after the drop: T T T at cols 0..2
```

```lua
function AIChainHori3(well, brain)
  local row = brain.where                                  -- [R] NOT reset per colour (bug, below)
  for T = 1, 7 do
    local left, right = -1, -1
    for col = brain.from - 1, brain.l, -1 do               -- nearest idle T left (a non-idle T is skipped)
      if well.block[row][col].type == T and well.block[row][col].state == 0 then left = col; break end
    end
    if left ~= -1 then
      for col = brain.to + 1, brain.r do
        if well.block[row][col].type == T and well.block[row][col].state == 0 then right = col; break end
      end
    end
    if left ~= -1 and right ~= -1 then
      row = row + 1                                        -- persists into later colours
      local filled, only = 0, nil
      for col = brain.from, brain.to do if well.block[row][col].type ~= 0 then filled = filled + 1; only = col end end
      local Wr = row - 1
      local function planLeft(c)  cmds{1(Wr), 3(left, brain.from-1), 1(row), 3(c, brain.from), 1(Wr),
                                       7(right, brain.to+1), 5(brain.to+1, brain.to), 6(brain.to, brain.from+1), 11} end
      local function planRight(c) cmds{1(Wr), 3(right, brain.to+1), 1(row), 3(c, brain.to), 1(Wr),
                                       7(left, brain.from-1), 5(brain.from-1, brain.from), 6(brain.from, brain.to-1), 11} end
      if filled == 0 then
        for col = brain.l, brain.r do
          if isIdle(col, row, T) then
            if col < brain.from then planLeft(col) else planRight(col) end
            brain.step = 1; return -1
          end
        end
      elseif filled == 1 and well.block[row][only].type == T then          -- state not checked
        if (only - brain.from) < (brain.to - only) then planLeft(only) else planRight(only) end
        brain.step = 1; return -1
      end
    end
  end
  return 0
end
```

No RNG and no scratch arrays **[R]**. **Bug [R]:** `row` is set once before the colour loop and incremented whenever a
colour passes the side test. A later colour then searches one row higher, and its commands use the shifted rows. The
faithful port keeps this; a fixed port resets `row = brain.where` per colour.

#### AIChainHori4 (lastPlan 0x18, needs bit 8): `AIChainHori4.s` [R, m2c]

Shared **drop-in** step (Hori4 and Hori5) **[R]**: find the first column `x` in `from..to` with
`block[W+1][x].type == 0`, for which some row `y = W+2 .. 11` (bottom-up) holds an idle `T` directly left (`x−1`,
only if `x ≠ 0`; tested first) or right (`x+1`, only if `x ≠ 5`, a hard-coded 5) of column `x`. It emits
`1(y), 3(side, x), 1(W+1), 20(W+1, x)`: slide that panel over the gap, let it fall into `(W+1, x)`, and wait until it
has landed.

Purpose **[I]**: a horizontal 3 on row `W` from a `T` outside the flash in row `W`, a `T` already in row `W + 1`
(`t9`), and a `T` dropped into a gap in row `W + 1`.

```lua
function AIChainHori4(well, brain)
  local W, from, to = brain.where, brain.from, brain.to
  if no col in from..to has block[W+1][col].type == 0 then return 0 end
  local above = {}; for c = brain.l, brain.r do above[c] = well.block[W+1][c].type end
  for c = brain.l, brain.r do
    local b = well.block[W][c]
    if b.state == 0 and b.type >= 1 and b.type <= 7 then
      local T, t9 = b.type, -1
      for k2 = brain.l, brain.r do if above[k2] == T then t9 = k2; break end end
      if t9 ~= -1 then
        local x, y, side = dropIn(from, to, T)                -- side = x-1 or x+1
        if x then
          if c < from then
            cmds{1(W), 3(c, from-1), 1(y), 3(side, x), 1(W+1), 20(W+1, x)}
            if t9 < x then
              if x == from then cmds{6(x, x+1), 6(t9, from)} else cmds{6(t9, from), 6(x, from+1)} end
            else cmds{6(x, from), 6(t9, from+1)} end
          else
            cmds{1(W), 3(c, to+1), 1(y), 3(side, x), 1(W+1), 20(W+1, x)}
            if t9 < x then cmds{6(x, to), 6(t9, to-1)}
            elseif x == to then cmds{6(x, x-1), 6(t9, to)}
            else cmds{6(t9, to), 6(x, to-1)} end
          end
          cmds{11}; brain.step = 1; return -1
        end
      end
    end
  end
  return 0
end
```

No RNG, no path checks, scratch arrays untouched **[R]**.

#### AIChainHori5 (lastPlan 0x19, needs bit 8): `AIChainHori5.s` [R, m2c]

Purpose **[I]**: two `T`s from row `W` on one side are parked at `from−1, from−2` (or `to+1, to+2`), and a `T`
dropped into a gap in row `W + 1` is slid to `from` (or `to`). After the pop it falls next to the pair.

```lua
function AIChainHori5(well, brain)
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  local W, from, to = brain.where, brain.from, brain.to
  if no col in from..to has block[W+1][col].type == 0 then return 0 end
  for T = 1, 7 do
    local k, nl, nr = T - 1, 0, 0
    for col = from - 1, brain.l, -1 do
      if isIdle(col, W, T) then AIrowCheck[k][nl], AIcolCheck[k][nl] = W, col; nl = nl + 1 end
      if nl == 2 then break end
    end
    for col = to + 1, brain.r do
      if isIdle(col, W, T) then AIrowCheck[k][2+nr], AIcolCheck[k][2+nr] = W, col; nr = nr + 1 end
      if nr == 2 then break end
    end
    if nl == 2 or nr == 2 then
      local x, y, side = dropIn(from, to, T)
      if x then
        if nl ~= 0 then                                     -- [R] bug: `nl ~= 0`, not `nl == 2` (:271)
          cmds{1(W), 3(AIcolCheck[k][0], from-1), 1(W), 3(AIcolCheck[k][1], from-2),
               1(y), 3(side, x), 1(W+1), 20(W+1, x), 6(x, from)}
        else
          cmds{1(W), 3(AIcolCheck[k][2], to+1), 1(W), 3(AIcolCheck[k][3], to+2),
               1(y), 3(side, x), 1(W+1), 20(W+1, x), 6(x, to)}
        end
        cmds{11}; brain.step = 1; return -1
      end
    end
  end
  return 0
end
```

With one `T` on the left and two on the right, the left branch runs with `AIcolCheck[k][1] == 0` (from the clear), so it
slides column 0 to `from − 2` **[R]**. No RNG **[R]**.

### 2.3 Garbage

#### AIClearGarbage (lastPlan 0x20): `AIClearGarbage.s` [R, m2c]

Purpose **[I]**: make a match that touches the lowest garbage. The first choice is a horizontal 3 in the row right
under it. Otherwise it builds a vertical 3 in a column under the garbage, in rows `G−1`, `G−2`, `G−3`.

```lua
function AIClearGarbage(well, cursor, brain)
  if cursor.state == 2 then return 0 end
  local G = brain.garbageRow
  if AIPossibleRow(well, brain, G - 1) ~= 0 then                  -- the first call's command is thrown away
    clearQueues(brain); cmds{1(G-1)}; AIPossibleRow(well, brain, G - 1); return -1
  end
  if G < 3 then return 0 end
  for col = 0, 5 do if well.block[G-1][col].state == 7 then return 0 end end   -- something already matching there
  clear(AIrowCheck); clear(AIcolCheck); clear(AItotCheck)
  for c = 0, 5 do
    local T = well.block[G-1][c].type                              -- [R] no T < 8 test (see note)
    if T ~= 0 and AItotCheck[T-1] == 0 then
      local k, found = T - 1, 0
      push(k, G - 1, c)
      local r = G - 1
      repeat                                                       -- up to 3 consecutive rows below
        r = r - 1; if r < 0 then break end
        local hit = false
        for c2 = 0, 5 do
          if isIdle(c2, r, T) and AIMoveAcross(well, r, c2, c) ~= 0 then push(k, r, c2); hit = true; break end
        end
        if not hit then break end
        found = found + 1
      until found >= 3
      if AItotCheck[k] >= 3 then
        local order = AISortRows(brain.cursor_y, 3, {AIrowCheck[k][0], AIrowCheck[k][1], AIrowCheck[k][2]})
        local X
        if well.block[G][c].type == 9 then X = c                   -- garbage right above this column
        elseif well.block[G][2].type ~= 9 then X = 3 else X = 2 end
        if band(brain.character, 0x80) ~= 0 and AItotCheck[k] >= 4 and well.state.death == 0 then
          local d = math.abs(AIcolCheck[k][3] - X)                  -- a 4th panel, when it is close
          if d ~= 0 and d < 3 then cmds{1(AIrowCheck[k][3]), 4(AIcolCheck[k][3], X)} end
        end
        for _, e in ipairs(order) do
          if AIcolCheck[k][e] ~= X then cmds{1(AIrowCheck[k][e]), 4(AIcolCheck[k][e], X)} end
        end
        return -1
      end
    end
  end
  return 0
end
```

Note: `T` can be ≥ 8 in the original (an out-of-bounds index). Skip it in a port **[I]**.

#### AIChainGarbage1 (lastPlan 0x1E, needs bit 0x20) and AIChainGarbage2: `src/main/ai.c:2185-2384` [R]

Runs while garbage converts (`cursor.state == 2`). `garbageRow` is frozen during that state (AISetGarbage is skipped),
so row `G` holds the freshly revealed panels that are about to fall **[I]**. Purpose **[I]**: line up, under each
revealed panel, two of its colour, so the falling panel lands on them and makes a chain.

```lua
function AIChainGarbage1(well, cursor, brain)
  local G = brain.garbageRow
  if G < 2 then return 0 end
  if brain.chainLimit < 0 then if brain.chainLimit >= well.old_chain then return 0 end
  elseif brain.chainLimit == 0 then if well.old_chain < -3 then return 0 end end
  clear(AItotCheck)                                              -- now used per COLUMN: 0, colour, or -1 locked
  local top = 0
  for col = 5, 0, -1 do
    local T = well.block[G][col].type
    if T ~= 9 and T ~= 0 then
      AItotCheck[col] = T
      local n = 0
      for row = G - 1, 0, -1 do                                  -- already two T's under it (gaps skipped)?
        local t = well.block[row][col].type
        if t ~= 0 then if t ~= T then break end; n = n + 1 end
        if n == 2 then AItotCheck[col] = -1; top = math.max(top, row + 1); break end
      end
    end
  end
  for col = 5, 0, -1 do
    local T = AItotCheck[col]
    if T ~= -1 and T ~= 0 then
      local n, inCol = 0, 0                                      -- n entries in AIrowCheck[0]/AIcolCheck[0]
      for row = G - 1, 0, -1 do
        local s1
        for c = 0, 5 do
          if AItotCheck[c] ~= -1 and isIdle(c, row, T) then
            if well.block[row][col].type == T then inCol = inCol + 1; AIrowCheck[0][n], AIcolCheck[0][n] = row, col; n = n + 1; s1 = c; break
            elseif AIMoveAcross(well, row, c, col) ~= 0 then AIrowCheck[0][n], AIcolCheck[0][n] = row, c; n = n + 1; s1 = c; break end
          end
        end
        if not s1 then if n ~= 0 then break end
        elseif n == 1 then
          if AIChainGarbage2(well, brain, T, col) ~= 0 then return -1 end
          if AItotCheck[col] == -1 then break end
        elseif n == 2 then break end
      end
      if inCol == 2 then
        if AIClearPosition(well, brain, AIrowCheck[0][0] + 1, col) ~= 0 then AItotCheck[col] = -1 end
        top = math.max(top, AIrowCheck[0][0])
      elseif n == 2 and (band(brain.character, 0x40) ~= 0 or top < AIrowCheck[0][0]) then
        local cnt, last = 0, AIrowCheck[0][0] + 1
        for row = AIrowCheck[0][0] + 1, G - 1 do
          if well.block[row][col].type ~= 0 and well.block[row][col].state == 0 then cnt = cnt + 1; last = row end
        end
        if cnt < 2 and (AIrowCheck[0][0] + 1 == G or AIClearPosition(well, brain, last, col) ~= 0) then
          local r = AIrowCheck[0][1] - 1
          if well.block[r][col].type == T then cmds{1(r), 2(col - 1), 9} end
          local order = AISortRows(brain.cursor_y, n, {AIrowCheck[0][0], AIrowCheck[0][1]})
          for _, e in ipairs(order) do
            if AIcolCheck[0][e] ~= col then cmds{1(AIrowCheck[0][e]), 4(AIcolCheck[0][e], col)} end
          end
          AItotCheck[col] = -1; return -1
        end
      end
    end
  end
  return 0
end

function AIChainGarbage2(well, brain, below, col)
  local T = well.block[brain.garbageRow + 1][col].type
  if T ~= below or T == 9 or T == 0 or AItotCheck[col] == -1 then return 0 end
  if AIMoveAcross(well, AIrowCheck[0][0], AIcolCheck[0][0], col) == 0 then return 0 end
  local cnt = 0
  for row = AIrowCheck[0][0] + 1, brain.garbageRow - 1 do if well.block[row][col].type ~= 0 then cnt = cnt + 1 end end
  if cnt < 2 and (AIrowCheck[0][0] + 1 == brain.garbageRow
                  or AIClearPosition(well, brain, AIrowCheck[0][0] + 1, col) ~= 0) then
    AItotCheck[col] = -1
    if AIcolCheck[0][0] ~= col then cmds{1(AIrowCheck[0][0]), 4(AIcolCheck[0][0], col)}; return -1 end
  end
  return 0
end
```

(`n`, `inCol` and the per-row break logic follow `src/main/ai.c:2254-2293` exactly; `AIClearPosition` may also add
commands without the caller returning, as in the C.)

#### AIChainPack (lastPlan 0x1F): `src/main/ai.c:2078-2183` [R]

The fallback while garbage converts. Purpose **[I]**: compact the stack under the converting garbage (fill holes,
bring same colours into adjacent rows) so the falling panels can chain. It uses `AItotCheck` column locks from
AIChainGarbage1; if that didn't run, `AItotCheck` holds stale counts (never −1, so nothing is locked).

```lua
function AIChainPack(well, cursor, brain)
  local G, top = brain.garbageRow, 0
  for col = 0, 5 do                                       -- highest first-hole row over locked columns
    if AItotCheck[col] == -1 then
      for row = 0, G - 1 do if well.block[row][col].type == 0 then top = math.max(top, row); break end end
    end
  end
  if top ~= 0 then
    for row = G - 1, top, -1 do for col = 0, 5 do
      if type ~= 0 and state == 0 and AILowerRow(well, brain, row, col) ~= 0 then return -1 end
    end end
    return 0
  end
  for T = 1, 6 do                                         -- bring each colour's panels into consecutive rows
    local last = -1
    for row = 0, G - 1 do for col = 0, 5 do
      if AItotCheck[col] ~= -1 and isIdle(col, row, T) then
        if last == -1 or last == row - 1 then last = row; break end
        if AILowerRow(well, brain, row, col) == 0 then last = row; break end
        return -1
      end
    end end
  end
  for row = G - 1, 1, -1 do for T = 1, 6 do               -- two of a colour in a row: lower either one
    local n, first = 0, nil
    for col = 0, 5 do if isIdle(col, row, T) then
      if n == 0 then first = col end; n = n + 1
      if n >= 2 then
        if AILowerRow(well, brain, row, first) ~= 0 then return -1 end
        if AILowerRow(well, brain, row, col) ~= 0 then return -1 end
        break
      end
    end end
  end end
  for row = 0, G - 2 do for col = 0, 4 do                 -- a hole with a panel diagonally up-right
    if well.block[row][col].type == 0 and well.block[row+1][col+1].type ~= 0 and well.block[row+1][col+1].state == 0
       and AItotCheck[col+1] ~= -1 and AILowerRow(well, brain, row + 1, col + 1) ~= 0 then return -1 end
  end end
  return 0
end
```

### 2.4 Plain matches and combos

#### AIPossibleRow (lastPlan 1; also used by AIClearGarbage and AIStupidMove): `src/main/ai.c:968-1021` [R]

```lua
function AIPossibleRow(well, brain, row)                  -- a horizontal 3 of one colour, anywhere in the row
  if well.block[row][2].type == 9 or well.block[row][3].type == 9 then return 0 end
  for T = 1, 7 do
    local n, first, second, third = 0, -1, -1, -1
    for col = brain.l, brain.r do
      if isIdle(col, row, T) then
        n = n + 1
        if first < 0 then first = col elseif second < 0 then second = col elseif third < 0 then third = col end
      end
    end
    if n >= 3 then
      if second - first == 1 then cmds{3(third, second + 1)}
      elseif third - second == 1 then cmds{3(first, second - 1)}
      elseif gCounter % 2 == 0 then cmds{8(first, second)}
      else cmds{8(second, third)} end
      return -1
    end
  end
  return 0
end
```

Note that it emits no row move: it assumes the cursor is already on `row` (UpdateAI calls it with `cursor_y`; the other
callers queue `1(row)` first) **[R]**. `gCounter` is the global frame counter, not the RNG.

#### AIPossibleCol (lastPlan 2): `AIPossibleCol.s` [R, m2c]

Purpose: a vertical 3 through one of the cursor's two cells, using panels from the two rows above it or from one row
above and one below.

```lua
function AIPossibleCol(well, brain)
  local cy, cx = brain.cursor_y, brain.cursor_x
  if cy == 0 or cy >= 9 then return 0 end
  local L, R
  if cx == brain.l then L, R = cx, cx + 2 elseif cx + 1 == brain.r then L, R = cx - 1, cx + 1 else L, R = cx - 1, cx + 2 end
  for side = 0, 1 do
    local X = cx + side
    local T = well.block[cy][X].type
    if T ~= 0 and T < 8 then                                -- state of the cursor cell not checked
      local k, n = T - 1, 0
      for c = L, R do if isIdle(c, cy+1, T) and AIMoveAcross(well, cy+1, c, X) ~= 0 then
        AIrowCheck[k][0], AIcolCheck[k][0] = cy + 1, c; n = 1; break end end
      if n == 1 then
        for c = L, R do if isIdle(c, cy+2, T) and AIMoveAcross(well, cy+2, c, X) ~= 0 then
          AIrowCheck[k][1], AIcolCheck[k][1] = cy + 2, c; n = 2; break end end
        if n ~= 2 then
          for c = L, R do if isIdle(c, cy-1, T) and AIMoveAcross(well, cy-1, c, X) ~= 0 then
            AIrowCheck[k][1], AIcolCheck[k][1] = cy - 1, c; n = 2; break end end
        end
        if n == 2 then
          local r0, c0, r1, c1 = AIrowCheck[k][0], AIcolCheck[k][0], AIrowCheck[k][1], AIcolCheck[k][1]
          if c0 == X then cmds{1(r1), 4(c1, X)}
          elseif c1 == X then cmds{1(r0), 4(c0, X)}
          elseif AIMoveAcross(well, cy, X, c0) ~= 0 then cmds{3(X, c0), 1(r1), 4(c1, c0)}   -- move the cursor panel instead
          else cmds{1(r0), 4(c0, X), 1(r1), 4(c1, X)} end
          return -1
        end
      end
    end
  end
  return 0
end
```

It does not clear the scratch arrays; it overwrites slots 0–1 of the colour **[R]**.

#### AIComboCheck: `src/main/ai.c:1039-1158` [R]

After `AIBoundaryCheck` has listed, per colour, 3–5 idle panels in consecutive rows within ±2 rows of the cursor,
this ranks colours by cursor distance and picks the best reachable one into `AIdistance[7]`.

```lua
function AIComboCheck(well, brain)
  local best, cy, cx = 18, brain.cursor_y, brain.cursor_x
  local function h(col) return (col < cx) and (cx - col) or (cx < col) and (col - (cx + 1)) or 0 end
  for t = 0, 6 do
    local tot = AItotCheck[t]
    if tot >= 3 then
      local lastRow, firstRow = AIrowCheck[t][tot-1], AIrowCheck[t][0]
      if cy >= lastRow then AIdistance[t] = math.abs(cy - lastRow) + h(AIcolCheck[t][tot-1])
      elseif firstRow >= cy then AIdistance[t] = math.abs(cy - firstRow) + h(AIcolCheck[t][0])
      else
        for s = 0, tot - 1 do
          if AIrowCheck[t][s] == cy then AIdistance[t] = h(cy); break end   -- [R] bug: uses the ROW as the column
        end                                                                  -- (no entry on the cursor row: stays 18)
      end
    end
  end
  for t = 0, 6 do
    if AIdistance[t] ~= 18 then
      local tot = AItotCheck[t]
      local order = AISortRows(cy, tot, rowsOf(t))
      local X = AIcolCheck[t][order[tot]]                   -- column of the last-visited entry (1-based order here)
      for _, e in ipairs(order) do
        if AIMoveAcross(well, AIrowCheck[t][e], AIcolCheck[t][e], X) == 0 then AIdistance[t] = 18; break end
      end
      if AIdistance[t] < best then best = AIdistance[t]; AIdistance[7] = t end
    end
  end
end
```

#### AICombo3a (lastPlan 5): `AICombo3a.s` [R, m2c]

```lua
function AICombo3a(brain)
  local t = AIdistance[7]; if t == 18 then return 0 end
  local tot = AItotCheck[t]
  local order = AISortRows(brain.cursor_y, 3, {AIrowCheck[t][tot-3], AIrowCheck[t][tot-2], AIrowCheck[t][tot-1]})
  -- [R] bug: `order` holds indices 0..2 of that 3-element copy, but they are used to index entries 0..2 directly
  local X = AIcolCheck[t][order[3]]
  for _, e in ipairs(order) do
    if AIcolCheck[t][e] ~= X then cmds{1(AIrowCheck[t][e]), 3(AIcolCheck[t][e], X)} end
  end
  return -1
end
```

With `tot == 3` the bug has no effect. With 4 or 5 it moves the bottom three entries, ordered by the rows of the top
three **[R/I]**. Uses command 3 (fixed source column), unlike Combo3b.

#### AICombo3b (lastPlan 6), AIComboX (lastPlan 9), AICombo45 (lastPlan 3 / 4): `src/main/ai.c:1218-1355` [R]

```lua
function AICombo3b(brain)                                  -- first colour with EXACTLY 3 entries
  for t = 0, 6 do if AItotCheck[t] == 3 then
    local order = AISortRows(brain.cursor_y, 3, rowsOf(t)); local X = AIcolCheck[t][order[3]]
    for _, e in ipairs(order) do if AIcolCheck[t][e] ~= X then cmds{1(AIrowCheck[t][e]), 4(AIcolCheck[t][e], X)} end end
    return -1
  end end
  return 0
end

function AIComboX(brain)                                   -- the same for colour index 6 (type 7, the "!" panel) only
  if AItotCheck[6] ~= 3 then return 0 end
  -- body as AICombo3b with t = 6
end

function AICombo45(brain, combo)                           -- a vertical 4 or 5 of one colour
  for t = 0, 6 do if AItotCheck[t] == combo then
    local order = AISortRows(brain.cursor_y, combo, rowsOf(t))
    local c0, c1 = AIcolCheck[t][0], AIcolCheck[t][1]
    local X = (math.abs(brain.cursor_x + 1 - c1) >= math.abs(brain.cursor_x - c0)) and c0 or c1
    for _, e in ipairs(order) do                           -- every entry except entry 2 ...
      if e ~= 2 and AIcolCheck[t][e] ~= X then cmds{1(AIrowCheck[t][e]), 4(AIcolCheck[t][e], X)} end
    end
    if AIcolCheck[t][2] ~= X then cmds{1(AIrowCheck[t][2]), 4(AIcolCheck[t][2], X)} end   -- ... which goes last
    return -1
  end end
  return 0
end
```

**[I]** Entry 2 is the middle row of the stack. Placing it last keeps a partial 3 from popping early, so all 4 or 5 pop
as one combo.

### 2.5 Stack height

#### AIVolumeCheck (lastPlan 0x32 / 0x33 / 0x34): `src/main/ai.c:1508-1659` [R, non-matching C]

```lua
function AIVolumeCheck(well, cursor, brain, exit)
  local h = {}
  local total = AIScrollCheck(well, brain, h)                  -- h[0..5] = contiguous heights
  local highest = math.max(h[0], h[1], h[2], h[3], h[4], h[5])
  if band(brain.character, 2) ~= 0 then                         -- raise when the stack is low
    if brain.garbageRow == -1 then
      local hh = (cursor.state == 3) and 12 or highest
      if total < 42 and hh < 9 then
        hh = hh + 2; total = total + 9; cmds{12}
        if total < 42 then while hh < 9 do cmds{12}; hh = hh + 3 end end
        cmds{1(AnimationRandom(4) + 2), 10}                     -- then go to a random row 2..5
        return -1
      end
    else
      local a = 11
      while a > brain.garbageRow and well.block[a][2].type == 0 and well.block[a][3].type == 0 do a = a - 1 end
      if cursor.state == 3 then a = 12 end
      if highest < 9 and a < 8 then cmds{12, 1(brain.cursor_y - 1), 10}; return -1 end
    end
  end
  if exit ~= 0 then return 0 end
  -- flatten the tallest column
  local left, right = -1, -1
  for c = 0, 5 do if h[c] == highest then left = c elseif left ~= -1 then break end end      -- right end of the 1st peak run
  for c = 5, 0, -1 do if h[c] == highest then right = c elseif right ~= -1 then break end end -- left end of the last one
  local row = highest - 1; if row == brain.garbageRow then row = row - 1 end
  local col = -1
  local cx = brain.cursor_x
  if AnimationRandom(115) % 2 == 0 then
    if well.block[row][cx].type ~= 0 then col = cx elseif well.block[row][cx+1].type ~= 0 then col = cx + 1 end
  else
    if well.block[row][cx+1].type ~= 0 then col = cx + 1 elseif well.block[row][cx].type ~= 0 then col = cx end
  end
  if col == -1 then
    if left == right then col = left elseif AISearchClose(brain, left, right) then col = left else col = right end
  end
  for a = row, 2, -1 do                                         -- first colour change from the top of that column
    if well.block[a][col].type ~= well.block[a-1][col].type then
      if col ~= 0 and well.block[a-1][col-1].type == 0 then cmds{1(a-1), 3(col, col-1)}; return -1 end
      if col ~= 5 and well.block[a-1][col+1].type == 0 then cmds{1(a-1), 3(col, col+1)}; return -1 end
      break
    end
  end
  if well.block[row][col-1].type ~= 9 and well.block[row][col+1].type ~= 9 then   -- [R] col-1 / col+1 unchecked
    if row ~= 0 and AILowerRow(well, brain, row, col) ~= 0 then return -1 end
  end
  return 0
end
```

So the "volume" logic covers two things **[I]**. With bit 2 the CPU raises the stack when it holds fewer than 42 panels
in the 6 columns and the tallest column is under 9 (4 raise commands when the stack is empty **[R]**). The flattening step pushes the top
panel of the tallest column sideways into a hole, or drops it a row via `AILowerRow`. `AILowerRow` here reads
`AItotCheck` left over from earlier planners **[R]**.

#### AIStupidMove (fallback): `src/main/ai.c:2386-2422` [R]

```lua
function AIStupidMove(well, brain)
  for row = 0, 11 do
    if AIPossibleRow(well, brain, row) ~= 0 then
      clearQueues(brain); cmds{1(row)}; AIPossibleRow(well, brain, row); return -1
    end
  end
  if brain.garbageRow ~= -1 then
    local hi = 11
    while hi > brain.garbageRow and well.block[hi][2].type == 0 and well.block[hi][3].type == 0 do hi = hi - 1 end
    if hi < 11 then cmds{12, 1(brain.cursor_y - 1), 10}; return -1 end      -- raise under garbage
  end
  cmds{1(AnimationRandom(6)), 10}                                            -- wander to a random row 0..5
  return -1
end
```

---

## 3. Difficulty

### 3.1 Where it is set

- **[R]** Stadium (`gSelection == SELECTION_96`, 1P vs CPU): `AISetLevel(&brainbrain[1], menu[0].game,
  menu[0].stage)` then `InitAI` (`src/main/tetris.c:350-354`), 2D only (STADIUM-SPEC.md §2 "2D vs 3D").
- **[R]** Title demos and the menu's vs-CPU path: `DemoCPU(num, level)` → `AISetLevel(game, stage)` then `InitAI`
  (`src/main/tetris.c:187-238`). Title demo 3D/2D VS: levels 5 / 8; endless demo: level 6 (`src/main/title.c:418-440`).
  **[R, draft]** The menu passes level 10 when the match is 3D (`asm/usa/nonmatchings/main/menu/func_80017E18_usa.s:1030-1053`).
- **[R]** `speed == −1` means human (`src/main/animate.c:20`, `src/main/tetris.c:559`). The menu sets both brains to
  −1 (`func_80017E18_usa.s:214-218`).

`AISetLevel(game, stage)` (`src/main/ai.c:234-261`) **[R]**: game 1 Easy, 2 Normal, 3 Hard, 4 Very Hard (kSHARD),
5 Super Hard (kULTRA, also the default). Each sets `character = characteristic[stage − 1]`, calls
`AISetCharacter(stage)` for `chainLimit`, then sets `speed`, adjusts `chainLimit` and sets `think`. Player-facing names
come from STADIUM-SPEC.md §1.

### 3.2 `character` bits (what each technique flag enables) [R]

| Bit | Enables | Where |
|---|---|---|
| 0x01 | AICombo45 (4- and 5-combos, 1/7 then 1/5 chance per planning pass) | `UpdateAI.s:463-464` |
| 0x02 | AIVolumeCheck's raise logic | `AIVolumeCheck.s:84-85` |
| 0x04 | AIChainHori3; AIChainVert1's slide-in (AIChainVert3) and its 2-panel setups | `UpdateAI.s:347-348`, `AIChainVert1.s:16-19` |
| 0x08 | AIChainVert4, AIChainHori4, AIChainHori5 | `UpdateAI.s:315-316`, `:356-357` |
| 0x10 | AIChainVert5 (only during a chain) | `UpdateAI.s:324-325` |
| 0x20 | AIChainGarbage1 (chaining off converting garbage) | `UpdateAI.s:194-195` |
| 0x40 | AIChainGarbage1's relaxed condition (plan even when `top ≥` the pair's row) | `src/main/ai.c:2303` |
| 0x80 | AIClearGarbage's 4th panel | `AIClearGarbage.s:292-293` |

Always on whatever the bits: chain extension Vert1, Vert2, Hori1, Hori2 (gated by `chainLimit`/`think`), garbage
clearing, flattening, AIPossibleRow/Col, Combo3a/3b, the fallback **[R]**.

### 3.3 `chainLimit` (`unk_018`) and `think` (`unk_008`)

- **[R]** Chain planners may run only when `chainLimit < old_chain` (negative limits), or `old_chain ≥ −3` (limit 0),
  and, if garbage is present, only when it is at row 6 or higher and `old_chain ≥ −3`. With `old_chain = −(n−1)`
  during a ×n chain **[I]**, a limit of `−L` lets the CPU extend a chain while it is at ×L or less, so it builds chains
  up to ×(L+1). −1 builds ×2 only; −99 is unlimited; 0 allows chains up to ×5 **[I]**.
- **[R]** `chainLimit == 0` also enables AIComboX (match three `!` panels). It is 0 for stages 5, 9 and 11
  (Erika, Tracey, Giovanni) below Super Hard: "combo personalities" **[I]**.
- **[R]** AIChainGarbage1 uses the same gate (`chainLimit ≥ old_chain` → no; limit 0 and `old_chain < −3` → no).
- `think`: −1 = no cooldown ever; 0 = cooldown of `333 + AnimationRandom(111)` frames after each ×2/×3 chain ends
  (§1.5).

### 3.4 Per-stage table (USA) [R]

`src/main/ai.c:55-232`. `chr` = `character`, `spd` = `speed` (frames per move), `lim` = `chainLimit` after the
difficulty's adjustment. Opponent names per stage: STADIUM-SPEC.md §1.

| Stage | Easy chr / spd / lim | Normal | Hard | Very Hard | Super Hard |
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
| `think` | −1 | 0 | 0 | 0 (stages 1–8), −1 (9–16) | −1 |

Formulas: Easy `speed = 35 − (stage−1)/2`; Normal `20 − (stage−1)/2`, `lim = max(lim, −3)`; Hard
`16 − (stage−1)/2`, `lim −= 1` unless 0 or −99; Very Hard `speed` 11 (stages 1–2), 10 (3–4), 9 (5–6), 8 (7–8),
7 (9+), `lim −= 2` unless 0 or −99; Super Hard `speed` 7 (1–4), 6 (5–8), 5 (9–12), 4 (13+), `lim = −99` (integer
division) **[R]**. Stage 16 has no `AISetCharacter` case on NTSC, so Very Hard's Mewtwo keeps the previous `lim`
(−99 after stage 15) **[R/I]**.

Decoded from the table and §3.2–3.3 **[I]**:

- Easy: 4/5 combos from stage 2, raising from stage 3, Hori3 and the Vert1 slide-in from stage 9; no garbage chaining
  or advanced setups. Its chain cap follows the stage (×2 at stage 1 up to ×9 at stage 10; ×5 on the limit-0 stages).
- Normal: caps chains at ×4 (×5 on stages 5, 9, 11); raising from stage 2, Hori3 from 6, Vert4/Hori4/Hori5 (0x08)
  from 10.
- Hard: garbage chaining (0x20) from stage 1, Hori3 from 2, 0x08 from 4, the 4th-panel garbage clear (0x80) from 6,
  Vert5 (0x10) on the 0xBF/0xFF stages, 0x40 on the 0xEF/0xFF stages.
- Very Hard and Super Hard: the same bytes as each other, everything from stage 4 on except 0x10/0x40 on some
  stages. Super Hard has no chain cap.
- Speed is the dominant knob: 35 → 4 frames per move.

### 3.5 DemoCPU levels (`src/main/tetris.c:187-232`) [R]

| level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|---|
| (game, stage) | (1,1) | (1,9) | (2,3) | (2,12) | (3,6) | (3,14) | (4,3) | (5,10) | (4,15) | (5,15) |

### 3.6 PAL (not for the port)

PAL uses other Very/Super Hard speed steps, an extra stage-16 case, and `ADJUST_FRAMERATE` on `speed`
(`src/main/ai.c:112-125`, `:157-168`, `:225-228`, `:258-260`) **[R]**. Use USA.

---

## 4. Randomness

### 4.1 The generator [R]

`AnimationRandom(max)` (`src/main/animation.c:18-25`):

```
seed = seed + 0x87C125 + seed * 0x7B6E72            (32-bit wrap; gTheGame.unk_9C10, the GC field `seed`)
return (s32)( (f32)(seed & 0x7FFFFFFF) / (f32)0x7FFFFFFF * (f32)max )
```

The arithmetic is single-precision: `(f32)0x7FFFFFFF` is exactly 2³¹, the quotient is exact, and the product is rounded
to f32 then truncated **[I]** (C types; KMC gcc keeps `float` math in single precision). It can return `max` itself when
`seed & 0x7FFFFFFF ≥ 2³¹ − 64` (that rounds to 2³¹) **[I]**. So `AnimationRandom(5) + 1` can be 6, and
`AnimationRandom(2)` can be 2.

**It shares its state with the panel generator.** `RandomBlock` (`src/main/tetris.c:36-58`) advances the same
`gTheGame.unk_9C10` with its own step (`seed += 0x29A74E + seed * 0x31EF68`) **[R]**. Both players' AIs and both
panel generators draw from one stream, and the seed comes from `osGetTime()` at game init (`src/main/tetris.c:272`,
`src/main/init2d.c:911`) **[R]**. So PPL's AI draws are seeded from the clock and interleaved with panel generation;
no port can match PPL's exact sequence.

### 4.2 Every RNG call in the AI [R]

| Where | Call | Use |
|---|---|---|
| InitAI (Stadium only) | `AnimationRandom(317) % 2`, then maybe `AnimationRandom(66) % 2` | opening row 2 / 3 / none |
| UpdateAI cooldown | `AnimationRandom(111) + 333` | `think` |
| UpdateAI new flash while `step == 1` | `AnimationRandom(321) % 3 == 0` | abandon the setup (1/3) |
| UpdateAI garbage branch | `AnimationRandom(1972) % 3 == 0` | try AIVolumeCheck (1/3) |
| UpdateAI combos (bit 1, `think ≤ 0`) | `AnimationRandom(803) % 7 == 0`, else `AnimationRandom(566) % 5 == 0` | try a 5-combo (1/7), else a 4-combo (1/5) |
| AIMove, per executed move | `AnimationRandom(375) % 3`, `AnimationRandom(2)`, optionally `AnimationRandom(3)` | delay jitter |
| AI3DMove move 8 | `AnimationRandom(5) + 1` | random move |
| AIVolumeCheck | `AnimationRandom(4) + 2` (after raising); `AnimationRandom(115) % 2` (flatten side) | |
| AIChainVert1 | `AnimationRandom(516) & 1` once or twice | trim to 3 panels; drop the slide-in |
| AIChainVert5 | `AnimationRandom(100) & 1` up to twice | knock-aside side; parking column |
| AIStupidMove | `AnimationRandom(6)` | random row |

Not random but frame-dependent: `AIPossibleRow` uses `gCounter % 2` **[R]**.

### 4.3 For the port

Give each CPU its own generator with the same step and output function, seeded from the match seed and the player
number, and never touch Panel Attack's panel RNG (`CLAUDE.md`: the 2D panel generator's RNG use must not change).
Replace `gCounter` with the stack's `clock`. Then CPU play is a pure function of (match seed, inputs, board), which
rollback and replays need. Exact equality with PPL is impossible anyway (§4.1).

Lua (LuaJIT, no ffi): the product `seed * 0x7B6E72` overflows 2⁵³, so split it:
`lo = seed % 65536; hi = (seed - lo) / 65536; p = (lo * 0x7B6E72 + ((hi * 0x7B6E72) % 65536) * 65536) % 2^32`.
Round to f32 with `math.frexp`/`math.ldexp` (24-bit mantissa, ties to even) before the multiply by `max` and after it,
then `math.floor`.

---

## 5. 3D

Confirms and extends `docs/3d-mode/SPEC.md` §8.

- **[R]** The planner is identical in 2D and 3D. Only the executor differs (`AIMove` picks `AI3DMove` when
  `dimension ≠ 2D`, `src/main/ai.c:3165-3169`).
- **[R]** In 3D `cursor.x` is fixed at 4 (`src/main/init3d.c:108`): the cursor sits on array columns 4 and 5 and the
  array rotates under it (`src/main/update3d.c:45-110`). So `brain.cursor_x == 4` always, and the AI's window `l..r =
  0..5` is the 4 columns left of the cursor plus the cursor pair. Everything the AI scans is hard-coded to columns 0–5:
  vision, `AIFlashCheck`, `AIScrollCheck`, `AIClearGarbage`, `AIChainPack`, `AILowerRow`, `AIClearPosition`, and the
  garbage tests on columns 2/3. The other 12 columns are invisible to it, while `alert` and game over scan all 18.
- **[R]** Moves 1/2 become rotations (`Move3DCursorLeft/Right`). Left sets `sx = 4`, the array then shifts right one
  column (panels move right, so relative to the panels the cursor moved left: the same meaning as a 2D left). A
  rotation is refused while one is running, but `AI3DMove` consumes the move anyway, so a CPU with `delay < 4` drops
  rotations and its plan drifts **[R code, I effect]**. That affects Super Hard stages with speed ≤ 6 (delay can drop
  to `speed − 3` while `step ≠ 0`). The 3D vs-CPU gets `DemoCPU` level 10 = Super Hard stage 15, speed 4 (§3.1), so
  it should drop rotations often **[I]**.
- **[R]** No quick moves: 11–15 behave like 1–5 and leave `delay` alone, and the retrying swap 6 does not set
  `delay = 1`. AISpeedUpMove still rewrites the queue, to no effect.
- **[R]** Move 8 (re-centre vision, from command 10) is replaced in place by `AnimationRandom(5) + 1` and run on the
  next turn instead: a random left, right, up, down or swap. Command 10 is queued by the Stadium opening (`InitAI`),
  by AIVolumeCheck after raising, and by AIStupidMove, so in 3D every "wander" or "after raise" ends with one random
  input.
- **[R]** `AIHoriMove`'s clamp of column 5 to 4 is 2D only. In 3D, "go to column 5" is one rotation right.
- **[I] Stale columns.** Commands hold array columns from the planning snapshot. Rotating shifts the array, and nothing
  adjusts the queued commands (`Update3DPosition` touches blocks, the incoming row, icons, attacks and explosions
  only). The first slide of a plan is right. Every later command that names a column (3/4/5/6/7, 2, 8, 13, 20) is off
  by however many columns the cursor has rotated since planning. Command 4's `AIShortestD` re-picks the source by
  colour, which partly hides this, but its target column is still stale. This plausibly explains why the 3D CPU is
  weaker (STADIUM-SPEC.md quotes "AI opponents' abilities are limited when using the 3D gameplay style").
- **[I]** Out-of-window reads (`col − 1` at column 0, `col + 1` at 5, `to + 1` past 5) hit real panels in 3D (array
  columns 6 and 17-of-the-row-below), where 2D sees empty cells.

---

## 6. Constants and tables (verbatim)

### 6.1 `characteristic` arrays (USA) [R]

```c
/* Easy   src/main/ai.c:56 */  { 0, 1, 3, 3, 3, 3, 3, 3, 7, 7, 7 }
/* Normal src/main/ai.c:65 */  { 1, 3, 3, 3, 3, 7, 7, 7, 7, 15, 15, 15, 15, 15, }
/* Hard   src/main/ai.c:79 */  { 0x23, 0x27, 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xBF, 0xBF, 0xEF, 0xBF, 0xFF, 0xBF, 0xBF, 0xBF, }
/* VHard  src/main/ai.c:93 */  { 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, }
/* SHard  src/main/ai.c:140 */ { 0x27, 0x2F, 0x2F, 0xAF, 0xAF, 0xAF, 0xEF, 0xFF, 0xAF, 0xEF, 0xFF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, }
```

(The GC DWARF declares these arrays with 9/13/15/15/15 entries: the GC tables differ and are not used here.)

### 6.2 `AISetCharacter(stage)` → `chainLimit` before adjustment (`src/main/ai.c:175-232`) [R]

| stage | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| value | −1 | −2 | −3 | −4 | 0 | −5 | −6 | −7 | 0 | −8 | 0 | −9 | −10 | −99 | −99 | unchanged (USA) |

### 6.3 Speeds (USA) [R]

Easy `35 − (stage−1)/2`; Normal `20 − (stage−1)/2`; Hard `16 − (stage−1)/2`; Very Hard `stage<3:11, <5:10, <7:9,
<9:8, else 7`; Super Hard `stage<5:7, <9:6, <13:5, else 4`.

### 6.4 Other constants [R]

| What | Value | Source |
|---|---|---|
| RNG step (AI) | `s + 0x87C125 + s * 0x7B6E72` | `animation.c:22` |
| RNG step (panels, same state) | `s + 0x29A74E + s * 0x31EF68` | `tetris.c:52` |
| Cooldown | `333 + AnimationRandom(111)` frames, after chains with `chain_check ≥ −2` | `UpdateAI.s:74-76` |
| Raise threshold | panels in 6 columns `< 42` and tallest `< 9` (+2 per raise, +9 to the count; more raises `+3` each while `< 9`) | `ai.c:1548-1557` |
| Garbage raise | tallest `< 9` and garbage top (cols 2/3) `< 8` | `ai.c:1575` |
| Vision | `t = min(cy+2, 11)`, `b = max(cy−2, 0)`, `l = 0`, `r = 5` | `ai.c:268-286` |
| Distance "invalid" | 18 | `ai.c:894`, `:1070` |
| Sort sentinel | 12 | `ai.c:778-795` |
| Flash scan | rows 0–7, columns 0–5 | `AIFlashCheck.s` |
| Queue sizes | 15 commands, 25 moves (no bounds checks) | `include/ai.h` |
| AIPossibleCol rows | cursor row 1..8 only | `AIPossibleCol.s` |
| Garbage chain gate | `garbageRow ≥ 6` and `old_chain ≥ −3` | `UpdateAI.s:270-300` |
| AIChainVert1 guard | `from ≠ 0`, `to < 10` | `AIChainVert1.s` |
| AIChainVert3 slide codes | 111 (rows `from+1..to−1`), 222 (`from..to−1`) | `AIChainVert1.s:257`, `:343` |

`lastPlan` values **[R]**: 1 PossibleRow, 2 PossibleCol, 3 Combo45(5), 4 Combo45(4), 5 Combo3a, 6 Combo3b,
9 ComboX, 11 Vert1, 12 Vert2, 14 Vert4, 15 Vert5, 0x15–0x19 Hori1–5, 0x1E ChainGarbage1, 0x1F ChainPack,
0x20 ClearGarbage, 0x32 / 0x33 / 0x34 VolumeCheck (garbage branch / alert branch / fallback). InitAI sets 1.

---

## 7. Porting notes

### 7.1 Suggested Lua modules

Under `common/engine/computerPlayers/PplCpu/` (the `ComputerPlayer` interface in
`common/engine/computerPlayers/computerPlayer.md`):

| Module | Contents |
|---|---|
| `PplCpu.lua` | the ComputerPlayer implementation: `getInput()`, `setConfig()`, `getConfigs()` (difficulty × stage presets from §3.4); owns brain + RNG |
| `PplRandom.lua` | `AnimationRandom` with exact 32-bit and f32 behaviour (§4.3) |
| `PplBoard.lua` | read-only adapter: `type(row, col)`, `state(row, col)`, `old_chain`, `alert`, `garbageRow`, cursor fields, `fieldActive()`, all in PPL 0-based coordinates (§7.2–7.3); handles out-of-range reads |
| `PplBrain.lua` | `ai_t` fields, command/move queues, `AIAddCommand`, `AISetMove`, `clearQueues`, `AISpeedUpMove` |
| `PplHelpers.lua` | §1.9 and §1.10 helpers |
| `PplPlanner.lua` | `UpdateAI`, `expandCommands` |
| `PplChains.lua` | §2.1–2.2 (Vert1–5, Hori1–5) |
| `PplGarbage.lua` | §2.3 |
| `PplCombos.lua` | §2.4, §2.5 |
| `PplExecutor.lua` | `AIMove`, 2D/3D move → Panel Attack input bits |

Keep scratch tables (`AIrowCheck`, …) preallocated in the brain: Panel Attack's rule is no short-lived tables in the
gameplay loop. Give them 6 slots per colour (Vert4/5 overflow) and 8 colour rows if Panel Attack's colour 7
(squares) can appear.

### 7.2 Coordinates

| PPL | Panel Attack (2D) | Notes |
|---|---|---|
| row `r` (0 bottom … 11) | `panels[r + 1]` (1 bottom … 12) | PA row 0 is the incoming row (PPL `new_block`); rows above 12 do not exist in PPL. The AI never reads them |
| column `c` (0–5) | column `c + 1` | |
| `cursor.x` (left cell, 0–4) | `cur_col − 1` | |
| `cursor.y` | `cur_row − 1` | |
| 3D array column `v` (cursor pair at 4, 5) | board column `((cur_col − 1) + (v − 4)) % 18 + 1` | SPEC.md §9, with `cur_col` at planning time |

For 3D, either store **view** columns in commands and map them with the current `cur_col` at expansion time (this
reproduces PPL's stale-column behaviour exactly, since PPL's array columns *are* view columns), or store board columns
(fixes it). Pick one deliberately (§8).

Out-of-range reads (rows −1/12/13, column −1/6) appear in several functions (§2). In 2D treat them as empty
(type 0, state 0). That equals PPL for columns 6+ (always empty in 2D **[I]**) but not exactly for column −1 at row
`r` (PPL reads `block[r−1][17]`, also empty in 2D) or row −1 / 12+ (other memory).

### 7.3 Board concepts

| PPL | Panel Attack equivalent **[I]** |
|---|---|
| type 1–6 | `color` 1–6 |
| type 7 (`!`) | `color` 8 (shock). PA's colour 7 (squares) has no PPL counterpart: give it its own slot; it is not a `!` |
| type ≥ 8, 9 = garbage | `isGarbage` panels (and colour 9 colorless) |
| state 0 idle | `"normal"` (and `"landing"`, which PA allows to swap and match) |
| 1 falling | `"falling"` |
| 2/3 swapping | `"swapping"` |
| 5/6 hover | `"hovering"` (6 = `chaining`) |
| 7 flashing | `"matched"` while `timer > frameTimes.FACE` |
| 8 popping | `"matched"` (face part), `"popping"`, `"popped"` |
| `old_chain` | `0` if `chain_counter == 0`, else `−(chain_counter − 1)` (`chain_counter` starts at 2) |
| `chain_check[num]` | the CPU's own copy of last frame's `old_chain` |
| `well.raise > 0` | `manual_raise` |
| `well.alert` | a non-garbage panel in PA row 10+ (PPL row 9), or incoming garbage that would reach it |
| `well.state.death` | game-over grace running (stop time exhausted while topped out) |
| `cursor.delay ≠ 0` | a swap is animating (any `"swapping"` panel the cursor started) |
| `cursor.state` 1 / 2 / 4 | some panel matched, popping, popped, falling or hovering / a garbage panel is matched (converting) / garbage shake (`shake_time > 0`) |
| `cursor.waiting ≠ 0` | panels still falling or hovering |
| `CheckFieldActive` | any panel in rows 1–12 not `"normal"` |
| `garbageRow` | computed by the adapter in PPL coordinates: the lowest PPL row ≥ 1 with a garbage panel in PPL column 2 or 3 (PA row ≥ 2, columns 3–4) |

### 7.4 Inputs and timing

- `getInput` per frame: run `UpdateAI` on the current state (PPL plans after match detection of the previous frame),
  then `AIMove` to produce this frame's input. Map moves 1/2/3/4/5/7 to Left 2 / Right 1 / Up 8 / Down 4 / Swap 16 /
  Raise 32 (`computerPlayer.md`); emit 0 (idle) on other frames.
- **Swap results:** AI2DMove needs to know at once whether the swap was refused (move 5 clears the plan, move 6
  retries). Panel Attack decides later in the frame and may deny a swap that comes too soon after another
  (`Stack:controls`). Evaluate refusal with Panel Attack's own swap-legality check at decision time, and feed a denial
  back on the next frame.
- **2D quick moves** (one move per frame) can't repeat one direction in Panel Attack's input model, because holding a
  direction triggers auto-repeat timing (`cur_timer`). Either insert an idle frame between equal directions (2 frames
  per step: slower than PPL) or accept that. Faithfulness vs. Panel Attack's input model is a design decision.
- **3D:** this fork's rotation cadence (`Stack:cursorMoveFires`) already ignores a rotation while one runs, which
  matches PPL dropping the move. Keep `AI3DMove`'s "consume anyway".
- Planned rows go stale by one after each new row (§1.4). Reproduce it, or adjust commands on rise; it's an option.

---

## 8. Open questions

1. **AIChainVert5's timed swap**: with the cursor on row `from` at `(W−1, W)` or `(W, W+1)`, the swap fires as the
   column starts falling. Which panel ends up where is unclear from the code; it needs an emulator check.
2. **AIChainVert2's distance test** (`d = −where − c` when `c ≥ where`, `AIChainVert2.s:225-231`): bug or intent?
   As written, any `T` on the right of `To + 1` qualifies. Port bug-for-bug unless decided otherwise.
3. **Bug fidelity**: Hori3's unreset row, Hori5's `nl ~= 0`, Combo3a's index mix-up, AIComboCheck's row-as-column,
   Hori1's `from` guard, AIShortestD returning −1 (a slide from column −1). Keep all of them for PPL feel, or fix?
   This doc gives the faithful version.
4. **3D stale columns** (§5): reproduce (view columns) or fix (board columns)?
5. **GC names for N64 `0x18/0x1C/0x20`** (`chainLimit`, `lastPlan`, `step`): the GC struct has one int fewer.
   Behaviour is clear; names are not.
6. **`cursor.state == 3`** (AIVolumeCheck treats it as "full"): what sets it is not found in matched code.
7. **`well.raise < 0`**: `AIMove` counts it up to 0, but where it goes negative was not traced.
8. **`AIHoriMoveCheckCheck`**: read from the `#if 0` draft; only its first branch was checked against the m2c draft.
   Its purpose (avoid a premature vertical match while sliding) is inferred.
9. **`AIBoundaryCheck`/`AIClearGarbage` with types ≥ 8**: out-of-bounds in the original (3D, or odd garbage). This
   doc says skip them; confirm it never happens in 2D Stadium.
10. **Float rounding of `AnimationRandom`**: single precision is inferred from the C types. Check the compiled asm
    (`mul.s` vs `mul.d`) before relying on the edge case where it returns `max`.
11. **Switch2DBlocks / Switch3DBlocks refusal rules** (when move 5 "fails") are in unmatched asm and not decoded
    here; Panel Attack's own swap rules are the practical substitute.

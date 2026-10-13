# CPU difficulty ladder check (phase 4)

Does the ported PPL CPU get stronger with stage and difficulty, as PPL intends? Measured with CPU-vs-CPU matches,
2026-10-13, branch `stadium-balance`.

## Method

`balanceLauncher.lua` plays seeded VERSUS matches between two `PplCpu` presets on two engine stacks that target each
other, as `ClientMatch` sets up a VERSUS match (INTEGRATION §A5 "Two stacks"), with the Stadium mode's rules. The
engine part is `common/tests/engine/CpuVersusTestUtils.lua`, shared with the regression test.

```sh
H=/Users/mcosta/tools/love12-headless/run.sh
$H <repo> ./balanceLauncher.lua --seeds=30 H15:H1 H8:H3@4        # pairings; @n sets the stack level
$H <repo> ./balanceLauncher.lua --3d --seeds=30 L10:L1             # on the tower
$H <repo> ./balanceLauncher.lua --solo --seeds=10 N1 N2            # alone on an endless board, no garbage
```

- Presets: `H8` = Hard stage 8 (`E N H V S` = Easy .. Super Hard), `L5` = vs-CPU level 5 (DemoCPU, AI-SPEC §3.5).
- Stack level: the Stadium's (Easy 1, Normal 2, Hard and up 4; STADIUM-SPEC §6) unless `@n` says otherwise; vs-CPU
  levels default to 4.
- Seeds 1..N. Side A plays stack 1 on odd seeds and stack 2 on even ones. CPU seeds derive from the match seed as in
  `ClientMatch`. Deterministic: the same command prints the same table.
- Frame cap 18000 (5 minutes); a match still running then is a timeout (T). Errors are caught per match (E): there
  were none in any run.
- Speed: about 0.05-0.5 s per match (a minute of game time is about 0.1 s), so 30 seeds per pairing is cheap.
- Columns: wins A / B, draws, timeouts, mean length of finished matches, and per side per match: chains of x2+,
  chain links, longest chain, 4+ combos, panels cleared.
- Noise floor: S6 and S5 are the same preset (0xAF / speed 6 / unlimited); over 100 seeds they went 41-44 with 15
  timeouts, and 7-19 over the first 30. Read 30-seed results within about ±6 wins of 15 as a coin flip.

All numbers below are after the fixes in "Fixes made", unless marked "before".

## Results

### Within a difficulty, first vs last stage (2D, 100 seeds)

| Pairing | Level | A-B (T) | Mean length |
|---|---|---|---|
| E11 : E1 | 1 | **32-68** | 140 s |
| N14 : N1 | 2 | 82-17 (1) | 167 s |
| H15 : H1 | 4 | 100-0 | 59 s |
| V16 : V1 | 4 | 95-5 | 66 s |
| S16 : S1 | 4 | 90-5 (5) | 134 s |
| H8 : H3 | 4 | 63-37 | 83 s |
| H15 : H8 | 4 | 94-6 | 72 s |
| E3 : E2 | 1 | **19-81** | 132 s |
| N2 : N1 | 2 | **24-76** | 161 s |

### Adjacent stages (2D, 30 seeds, wins of the higher stage)

| Difficulty | 2:1 | 3:2 | 4:3 | 5:4 | 6:5 | 7:6 | 8:7 | 9:8 | 10:9 | 11:10 | 12:11 | 13:12 | 14:13 | 15:14 | 16:15 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Easy | 18 | **8** | 12 | 18 | 10 | 15 | 14 | 13 | 11 | 16 | | | | | |
| Normal | **5** | 20 | 13 | 16 | 19 | 18 | 18 | 23 | 20 | 20 | 13 | 19 | 15 | | |
| Hard | 21 | 14 | 15 | 17 | 11 | 22 | 17 | 22 | 10 | 18 | 13 | 16 | 14 | 18 | |
| Very Hard | 12 | 18 | 18 | 17 | 15 | 20 | 19 | 18 | 11 | 12 | 15 | 14 | 14 | 14 | 14 |
| Super Hard | 13 | 16 (2T) | 14 | 18 (4T) | 7 (4T) | 12 (1T) | 7 (2T) | 18 (6T) | 12 (8T) | 14 (4T) | 15 (6T) | 16 (7T) | 14 (6T) | 14 (6T) | 14 (6T) |

One stage is a small step (speed −1 every other stage), so neighbours are mostly coin flips; the ends of each ladder
are far apart. V12–V16 and S13–S16 play identical games (same `character` and speed; their chain limits are never
reached), as PPL's table makes them.

### Across difficulties at stage 5 (2D, 30 seeds)

| Pairing | Level 1 | Level 2 | Level 4 |
|---|---|---|---|
| N5 : E5 | 29-1 | 30-0 | 29-1 |
| H5 : N5 | 19-11 | 23-7 | 25-5 |
| V5 : H5 | 30-0 | 27-3 | 29-1 |
| S5 : V5 | 27-2 (1T) | 28-2 | 30-0 |
| S5 : E5 | 30-0 | 30-0 | 30-0 |

Where difficulties meet: N1 : E11 29-1 (level 2), H1 : N14 **10-20**, V1 : H15 **8-22**, S1 : V16 20-10 (level 4).
The first stage of Hard and Very Hard is slower than the last of the difficulty below (speed 16 vs 14, 11 vs 9), so
they overlap. That is PPL's table.

### vs-CPU levels 1-10, each against the one below (30 seeds, level 4)

| | 2:1 | 3:2 | 4:3 | 5:4 | 6:5 | 7:6 | 8:7 | 9:8 | 10:9 | 10:1 |
|---|---|---|---|---|---|---|---|---|---|---|
| Preset of the higher level | E9 | N3 | N12 | H6 | H14 | V3 | S10 | V15 | S15 | |
| 2D | **5** | 27 | 24 | 19 | 26 | 18 | 29 | **5** | 28 (1T) | 30 |
| 3D | **1** | 26 | 20 | 19 | 24 | 15 | 29 | **6** | 24 | 30 |

### Alone on the board, no garbage (10 seeds, mean survival, 300 s cap)

| 2D | E1 | E2 | E3 | E11 | N1 | N2 | N14 | H1 | H8 | H15 | V1 | V16 | S1 | S16 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Level | 1 | 1 | 1 | 1 | 2 | 2 | 2 | 4 | 4 | 4 | 4 | 4 | 4 | 4 |
| Mean (survived) | 289 (3) | 281 (3) | **211 (0)** | **222 (0)** | 300 (10) | **250 (0)** | 300 (10) | 205 (0) | 272 (3) | 300 (10) | 295 (7) | 300 (10) | 300 (10) | 300 (10) |

| 3D | E1 | E11 | N1 | N14 | H1 | H15 | V1 | V16 | S1 | S16 | L3 @8 | L8 @8 | L10 @8 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| After | 142 | 98 | 208 | 198 | 65 | 247 | 171 | 300 | 299 | 300 | 14 | 185 | 244 |
| Before | 142 | 76 | 208 | 90 | 44 | 87 | | | 129 | 104 | 13 | 64 | 40 |

vs-CPU levels on the tower, level 4: L8 121 → 300 s, L9 134 → 300 s, L10 89 → 300 s (all 10 seeds survive now).

### 3D pairings (30 seeds, level 4 unless noted)

| Pairing | L10 : L1 | L8 : L3 | S16 : S1 | H15 : H1 | S5 : H5 | H5 : N5 | N5 : E5 @2 | L5 : L4 | E11 : E1 @1 |
|---|---|---|---|---|---|---|---|---|---|
| After | 30-0 | 30-0 | 26-4 | 28-2 | 28-2 | 23-7 | 29-1 | 19-11 | **10-20** |
| Before | 28-2 | 27-3 | **18-12** | 24-6 | 30-0 | 22-8 | 26-4 | 17-13 | **8-22** |

3D matches are short (25-50 s against 60-150 s in 2D at the same presets): the tower has three times the panels and
the CPU works a 6-column window of it (AI-SPEC §5).

## Judgement

Strength rises with difficulty and, over a few stages, with stage, as PPL intends: across difficulties at one stage
the stronger side wins 19-30 of 30 at every stack level, and the ends of Normal, Hard, Very Hard and Super Hard are
82-100 % apart. Speed is the knob that shows. The exceptions are below; one is PPL's own design, two were port bugs.

## Anomalies and causes

### 1. Raising makes Easy and Normal weaker (PPL design, not changed)

E3–E11 lose to E2 and E1 (E3 : E2 19-81, E11 : E1 32-68), N2 loses to N1 (24-76), vs-CPU level 2 (E9) loses to
level 1 (E1) 5-25 in 2D and 1-29 on the tower. Alone on the board N2 never lasts 5 minutes; N1 always does.

- Cause: `character` bit 0x02, AIVolumeCheck's raise logic (`PplGarbage.lua` `volumeCheck`, the `RAISE` branch). It
  raises whenever the 6 columns hold fewer than 42 panels and the tallest is under 9 rows (`ai.c:1548-1557`), i.e. it
  keeps the stack around 7 rows high, and a manual raise wipes the stop time (PPL `RaiseBlocks` sets
  `extra_wait = 0`, PA's `handleManualRaise` `stop_time = 0`). E1/E2 and N1 lack the bit. A traced N2 game (seed 1,
  level 2) raised 16 times, at tallest columns of 7-8 rows, and topped out at 155 s.
- Proof: with bit 0x02 stripped from every preset (experiment only), E3 : E2 becomes 66-34, E11 : E1 76-24 and
  N2 : N1 47-47.
- The port matches PPL here (checked against `src/main/ai.c:1508-1600` and `animate.c:61-112`). PPL's raise rules are
  as harsh as PA's, and PPL's speed schedule is harsher, so this is how PPL's Easy/Normal CPU plays; against a human
  it means stage 3+ Easy CPUs top themselves out sooner.

### 2. A raise on a topped out stack ended the game (port bug, fixed)

PA ends the game on a manual raise while the stack is topped out (`Stack:checkGameOver`, `Stack.lua:1779`); PPL's
`RaiseBlocks` does nothing while the well is dead (`animate.c:83-86`). The CPU raised whenever its raise rule said
so, also with the top row full, so some losses were suicides: 4 of 100 N2 : N1 games, 2 of 100 H8 : H3, and 14 of
20 solo deaths of L10 on the tower at level 4. On the tower it was common because of anomaly 3.

### 3. On the tower the CPU raised all 18 columns off its 6-column view (3D adaptation gap, fixed)

The cause of "levels 8-10 top out by themselves in 10-15 s on the tower" and of L8 losing to L3 there. Traced:
L10 alone at level 8, seed 4. At the end of the countdown its view showed 37 panels, tallest 7 (the rest of the
tower: 1-7 rows), so it raised; each later turn brought a lower stretch of the tower into view and it raised again,
4 times in 7 s, until every column stood at 10-12. It topped out at 10.8 s with 0 panels cleared, on columns outside
its view.

AIScrollCheck only ever measures view columns 0-5 (AI-SPEC §5), but a raise lifts every column. PPL's 3D CPU has the
same flaw; Stadium 3D is ours (PLAN "Decisions taken", as with the board-column commands), so the raise logic now
takes the tallest column of the whole tower. 2D is unchanged.

### 4. vs-CPU level 9 is weaker than level 8 (PPL's DemoCPU table)

Level 9 is Very Hard stage 15 (speed 7), level 8 Super Hard stage 10 (speed 5): 5-25 in 2D, 6-24 on the tower.
`tetris.c:187-232` orders them that way.

### 5. Super Hard stalemates

Super Hard against Super Hard on level 4 runs past 5 minutes in up to a quarter of the games (S10 : S9 8 of 30).
Both sides keep up with PA's level 4 rise; on level 1 even S16 : S1 times out in 12 of 30. Elsewhere timeouts are
rare (1 in 100 N14 : N1, 1 in 30 V8 : V7 and L10 : L9). Not a bug; a human opponent ends these games.

### 6. Also found, not changed: a finished raise drops the plan

AI-SPEC §1.7 said PPL drops every plan when a raise finishes. The C says otherwise: `RaiseBlocks` sets `raise = 0`
(and so AIMove clears the queues) only when it cancels the raise; a raise that reaches its row sets `raise = −4`, and
the plan goes on (`ai.c:3133-3149`, `animate.c:70-111`). AI-SPEC §1.7 is corrected. The port still drops the plan
after every raise: keeping it needs the CPU to wait while PA ignores raises (`prevent_manual_raise`, until the
raised row is in), and that wait froze the CPU under garbage (`PplGarbageTests` topped out at 2389 of 7200 frames).
On the ladder it made no difference (E3 : E2 24-76, N2 : N1 23-77 with it).

## Fixes made

- `common/engine/computerPlayers/PplCpu/PplExecutor.lua`: move 7 (raise) on a topped out stack is refused like a
  raise the field cancels: no input, the plan is dropped. Test: `PplCpuTests` `noRaiseOnAToppedOutStack`, plus
  `cancelledRaiseDropsThePlan`.
- `common/engine/computerPlayers/PplCpu/PplGarbage.lua`: on the tower, AIVolumeCheck's raise logic uses the tallest
  column of the whole tower (`towerHeight`) for its height test. Test: `PplLadderTests` (L10 alone on the tower,
  seeds 6 and 8, lasts a minute; before the fix it topped out after 35 and 37 s).
- `docs/cpu-ai/AI-SPEC.md` §1.7: when PPL drops the plan after a raise.

`common/tests/engine/PplLadderTests.lua` (about 5 s) keeps the clearest results on fixed seeds: L10 beats L1, H15
beats H1, S5 beats H5 (2D), L10 beats L1 and L8 beats L3 (3D), each in at least 5 of 6 seeds, and the tower test
above.

## Recommendations

1. **Easy/Normal raising** (anomaly 1): decide after Michael plays it. Options, Stadium-only: drop bit 0x02 from Easy
   and Normal; or lower the raise limits for PA (e.g. 30 panels / tallest 7); or keep PPL's behaviour, which makes
   Easy 3-11 and Normal 2-14 top themselves out more than stage 1. A human may find "the stage 1 CPU is the hardest
   on Easy" odd.
2. **vs-CPU scale** (anomaly 4): our level picker is ours, not PPL's menu. Swap levels 8 and 9, or make level 9 a
   Super Hard stage between 10 and 15 (e.g. S13, speed 4), so the scale only goes up.
3. **Stadium 3D**: the tower CPU is still weaker than in 2D at the same preset (H1 survives 65 s alone on the tower
   vs 205 s in 2D; Easy and Normal CPUs top out on their own within 2-4 minutes). If Stadium 3D should feel like 2D,
   play it a stack level lower or with a slower rise.
4. **Super Hard stalemates**: PPL's speed schedule (`st_AdvanceLevel`, PLAN phase 4 option) would end them; not needed
   for human play.
5. Ladder steps of one stage are within noise; if stages should feel distinct, that needs PPL's speed schedule or
   per-stage stack levels, not CPU changes.

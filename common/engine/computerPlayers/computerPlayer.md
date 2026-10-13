This document describes the interface for computer players (CPUs) and how they interact with the game.

# Mechanism

A CPU is an alternative input device. It reads the engine `Stack` it plays and returns one input per frame, which goes
into the stack through `stack:receiveConfirmedInput` exactly like a human's input. Nothing else about the stack knows
it is played by a CPU, so a match against a CPU is recorded and replayed like any other match: the replay holds the
inputs and plays back without any CPU code.

`ComputerPlayer.lua` is the registry and holds the contract. Each implementation lives in its own folder under
`computerPlayers` and registers itself when it is required:

```lua
ComputerPlayer.register("SimpleCpu", SimpleCpu)
local cpu = ComputerPlayer.create("SimpleCpu", stack, {seed = 1234, level = 5})
```

# Interface

## Constructor

`Impl(stack, options)`, called through `ComputerPlayer.create`, which validates the options first:

| Option | Meaning |
|--------|---------|
| `seed` | integer for the CPU's own random generator, from `ComputerPlayer.deriveSeed(matchSeed, playerNumber)` |
| `level` | 1-10 on Pokémon Puzzle League's DemoCPU scale (`docs/stadium/AI-SPEC.md` §3.5) |
| `difficulty`, `stage` | a Stadium preset instead of a level: difficulty 1-5, stage 1 to `ComputerPlayer.STAGE_COUNTS[difficulty]` |

`ComputerPlayer.getPreset(options)` turns either form into the `(difficulty, stage)` pair.

## getInput

`cpu:getInput()` returns one `KeyDataEncoding` character: the stack's input for its next frame. Whoever drives the CPU
(`ClientMatch:run`, or a test) calls it once per frame, only while the stack is caught up
(`#stack.confirmedInput == stack.clock`) and before that frame runs, so the CPU sees the state after the previous
frame, the same view a human gets. It is never asked again for a frame, not even after a rollback.

Inputs are bit sums plus one, encoded through `KeyDataEncoding.base64encode`; the named constants (`KeyDataEncoding.left`
and so on) cover single buttons.

| Input | Value |
|-------|-------|
| Idle  | 0 |
| Right | 1 |
| Left  | 2 |
| Down  | 4 |
| Up    | 8 |
| Swap  | 16 |
| Raise | 32 |

e.g. swap + down is `16 + 4 + 1 = 21` → `base64encode[21]`.

## Rules

- __Never write to the stack__: not its panels, cursor, queues or timers. Reading is fine, as are read-only queries
  such as `stack:canSwap`.
- __Never use the panel generator's RNG, `math.random`, `love.math.random`, `os.time` or `love.timer`__. Use a generator
  of your own seeded from `options.seed`, so CPU vs CPU games are deterministic.
- Respect Panel Attack's controls: a new direction moves the cursor at once, the same direction again needs a released
  frame in between (held directions only repeat after a delay); on a 3D tower left/right turn it and presses during a
  turn are dropped.
- No short-lived tables in `getInput`: preallocate what you need, as for any code in the gameplay loop.

`common/tests/engine/ComputerPlayerTests.lua` checks these rules for `SimpleCpu`; run its checks against any new
implementation too.

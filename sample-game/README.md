# Saltmarsh Light — sample game

A short storylet game for dlua. You're the apprentice of an old lighthouse keeper. Get the key to the lamp room, keep the lamp fuelled through the night, and hope you're ready when the storm comes.

The game is written against the current [Varis Reference Manual](../docs/README.md). Where the spec forces a workaround, the code links to [`needed_extensions.md`](needed_extensions.md). [`extensions/proposed.lua`](extensions/proposed.lua) shows proposed syntax and is **not** loaded.

```sh
cd sample-game
../bin/dlua main.lua 7        # play with seed 7
../bin/dlua tools/check.lua   # scripted walkthrough + explain/analyze/save/replay checks
```

## Files

| File | Contents |
| --- | --- |
| `world.lua` | `build_world()`: schemas, keys, rules, starting facts. Also used as the `narrative.load` world factory |
| `qualities.lua` | `quality.define` metadata, display names, nil formatter |
| `content/decks.lua` | `:default`, `:market`, `:talk`, `:ending` deck configuration |
| `content/explore.lua` | Hub storylets: look, walk, locked doors, take/drop, rest, entering sub-decks |
| `content/lamp.lua` | Lighting and refuelling the lamp |
| `content/market.lua` | Random non-repeating market draw, purchases, a rumour |
| `content/keeper.lua` | Conversation tree as a deck of non-repeatable topics |
| `content/events.lua` | Clock, lamp burn, dawn, daily wage, storm scheduling, handler, ending switches |
| `content/endings.lua` | Ending deck |
| `game.lua` | Loads and seals content; session creation, load and period sync |
| `main.lua` | Minimal text host: presentation loop, event narration, observer, save/load |
| `tools/check.lua` | Author checks |

## Feature coverage

- **Datalog:**
  - symbols, including dynamic `logic.symbol`
  - facts generated in loops
  - recursion (`reachable`)
  - stratified negation over recursion (`cut_off`)
  - comparisons, guards (`where`) and zero-arity relations (`night`, `lamp_danger`)
  - world blocks, `logic.emptyworld`, local relations and local rules
- **Stateful:**
  - named and keyed relations
  - `set`/`delete`/`adjust`/`retract`
  - aggregates (`sum`, `count`)
  - transactions with `rollback`, inside and outside effects
- **Narrative:**
  - parameterized storylets, and choices with their own parameters and `when`
  - priority, weight, cooldown, `repeatable false`
  - deck config, `push_deck`/`pop_deck`/`replace_deck`, non-replacement draws
  - templates with `{#if query}` and `{#variant}`; `narrative.name` and a formatter
  - qualities with bounds
  - pre and post actions; `once_per` `:turn`, `:game`, `:always` and the custom `:day` period
  - `emit`, `schedule` + `on` handler, `defer`
  - `observe` + `flush`; save/load with an authored program and content version
  - `explain`, `analyze`, `replay_log`, `seed`/`limits`/`set_period`

## Status

Playable in the terminal with `../bin/dlua main.lua [seed]` (build with `make dlua` from the repo root). `tools/check.lua` passes, and a random-choice bot reached an ending on 40 of 40 seeds without errors or stranded menus.

Changes made when the game was first executed:

- The runtime gained storylet options `sticky true` (always listed, no draw slot, exempt from non-replacement history) and `order n` (display order, separate from `priority`), (REVIEW §2.6). `present()` itself is unchanged, so `main.lua` caches the presentation until a choice or load succeeds.
- `leave_market`/`end_talk` are `sticky`; the storm is scheduled once via `flag(:storm_scheduled)`; the key topic can be offered again after refusing; `haggle` requires resolve; dropping an item uses `set at(...)`.
- `G.load` no longer re-syncs periods, which had appended a spurious replay record and broken byte-identical save round trips.

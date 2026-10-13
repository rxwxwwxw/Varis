# The battle library

**Implemented.** The `battle` library runs one tower-defense battle from a table the project
provides. It is installed with the other core libraries. The simulation is native: no Lua runs
inside a battle step. Story code starts a battle, pumps it to its boundaries, plays the scenes
of its moments through the narrative session, and writes the outcome to the world. A project that
names the four battle hooks in its manifest gets all of that from the game host (`GameHost`, and
so the SDL3 player) without writing the loop.

This page describes only what the code implements. The sample that uses all of it is
`sample-td/` (*Lanternfall*, see its README); its tests are `sample-td/tests/*.lua`, run with
`bin/varis` (suite `sample-td`), and the engine's unit tests are `tests/unit/test_battle.d`.

## Starting and driving a battle

```lua
local h, problem = battle.new(setup)          -- nil, "field: message" when the setup is refused
h:place(1, 10, 4)                              -- tower kind 1 at axial (10, 4); true or false, reason
local r = h:pump(5000)                         -- "running", "moment", "won", "lost" or "withdrawn"
if r == "moment" then play(h:scene()) end      -- the scene named by the moment that paused it
local outcome = h:outcome()                    -- the table in "The outcome"
```

Tower kinds, enemy kinds, waves, sources, sinks and sectors are **1-based** in Lua; tiles are
axial `q`, `r` from 0.

### Commands

Commands are applied between steps and stamped with the current step. A refused command changes
nothing and is not logged; every accepted one is logged so the battle can be replayed.

| Method | Meaning |
| --- | --- |
| `h:place(kind, q, r)` | builds a tower. Refused: not revealed, a wall, occupied, a source or sink, an enemy there, not buildable, not enough credits |
| `h:sell(id)`, `h:upgrade(id)` | acts on a structure by id (levels 1–3; heroes refuse both) |
| `h:repair(id)` | restores a structure to full for half the missing hit points in credits |
| `h:move_hero(id, q, r)` | an order to walk. A hero with obedience under 100 may ignore it (drawn from the battle's seeded generator, so replay agrees) |
| `h:use_ability(id [, q, r])` | a hero's active ability: `repair`, `taunt`, `burn` (at a tile) or `shield` |
| `h:reveal(sector)` | reveals a fog sector (1-based): a host command, not a player's |
| `h:set_hp(id, hp)` | the silent judge's command: leave a structure with `hp` hit points |
| `h:sync(mods)` | applies the story's modifiers (below); returns the number applied and a list of `"entry: reason"` refusals |
| `h:set_speed(n)`, `h:pause([on])` | the view's speed (1–8) and pause. Host state: they never enter the simulation or the digest; `pump` returns `"paused"` while paused |

### Reading a battle

| Method | Result |
| --- | --- |
| `h:pump(limit)` | steps until a moment fires, the battle ends, or `limit` steps run |
| `h:scene()`, `h:moment()` | the scene of the moment that paused the battle; `{id, scene, trigger}` |
| `h:snapshot()` | every unit and enemy with tile, hit points, shield, level, ability cooldown, and which sectors are revealed. Read-only |
| `h:tile(q, r)` | `{wall, height, revealed, unit}` or nil off the map |
| `h:route(source)` | the tiles an enemy of that source walks to its sink, now |
| `h:cues()` | the last step's cues (`hit`, `death`, `leak`, `build`, `ruin`, `down`, `repaired`, `shielded`, `burned`, `summoned`, `taunted`, `reinforced`, `flare`, `healed`, `disobey`) |
| `h:outcome()`, `h:digest()`, `h:steps()` | the outcome table; the state digest (equal digests mean equal battles); steps run |
| `h:log()` | the accepted commands, as rows `{stamp, action, kind, q, r, target, a, b, c, d}` |
| `h:fork{moments=false, scale=n}` | a copy before the first step, replaying the build commands, with moments dropped and/or waves at `n` percent: the silent judge's tool |
| `battle.replay(setup, log)` | the outcome of the same battle from its command log (moments pass without scenes: the log holds what they did) |

## The setup

| Field | Meaning |
| --- | --- |
| `seed`, `map_seed` | integers; `map_seed` generates the terrain; `seed` is the battle's own generator |
| `width`, `height` | the map, from 1 to 1024 tiles on each side |
| `wall_density` | percent of generated walls (default about 12); a designed map sets 0 and draws walls as edits |
| `terrace_rows` | when positive, heights are terraces: `3 - r / terrace_rows`, at least 0 |
| `credits` | starting credits |
| `max_leaks` | the battle is lost when this many enemies reach a sink |
| `moment_cap` | how many non-closing moments may fire in one battle |
| `structure_room` | structures that may be placed or reinforced during the battle |
| `first_structure_id` | the first id given to structures placed during the battle |
| `attack_every` | enemies blocked by a structure or fighting a hero hit it every this many steps (default 1) |
| `edits` | `{q, r, wall}` entries that override the generated terrain |
| `revealed` | fog sectors revealed at the start (sector 1 is the first 16 by 9 tiles; six across for a 96-wide map) |
| `sinks` | `{q, r}` tiles enemies head for; must be open and revealed |
| `sources` | `{q, r, sink}`; `sink` indexes `sinks`; the tile must reach its sink |
| `structures` | `{id, kind, q, r, level, hp}` placed at the start; `hp` 0 or absent is the kind's full hit points |
| `heroes` | `{id, kind, q, r, hp, ability, passive, obedience}`; `kind` is the weapon, `ability` a kind used by `use_ability`, `passive` a kind that works by itself, `obedience` a percentage |
| `waves` | `{source, kind, count, every, start}` |
| `moments` | `{id, trigger, arg, arg2, arg3, scene}` (see triggers) |
| `towers` | tower kinds (below) |
| `enemies` | enemy kinds (below) |

Validation names the first problem by field (`structures.kind: no such tower kind`) and leaves the
world untouched. It also checks that every source reaches its sink over the map.

### Tower kinds

`{name, cost, range, damage, cooldown, hp, ability, radius, duration, jumps, power, reveal, buildable}`.
`buildable = false` kinds are for heroes and the story (abilities, the Bellfrey, militia).

| `ability` | Behaviour |
| --- | --- |
| `single` | damages the enemy nearest its sink within `range` |
| `splash` | the same, and every enemy within `radius` of the target |
| `slow` | damages and slows the target for `duration` steps |
| `chain` | damages the target, then up to `jumps` nearer enemies each within `radius` of the last |
| `burn` | damages and sets the target alight: `power` per step for `duration` steps. As a hero ability: sets every enemy within `radius` of a tile alight, and when `reveal` is non-zero reveals that tile's fog sector |
| `aura` | towers and units within `radius` do `power` percent more damage (capped at 100) |
| `shield` | every `cooldown` steps, gives the friendly unit within `radius` that needs it most a shield of `power` |
| `repair` | every `cooldown` steps, restores `power` hit points to the most damaged friendly within `radius`. As a hero ability: all within `radius` |
| `taunt` | a hero ability: for `duration` steps, enemies within `radius` are pulled to the hero and fight it |
| `summon` | enemies only (below) |

Damage is `damage * (100 + 50 per level above 1 + auras + bonds + global + hero modifier) / 100`,
less the target's armour, at least 1.

### Enemy kinds

`{name, hp, speed, armour, bounty, structure_damage, shield, summon, summon_every, summon_cap, burn_radius, burn_power, burn_every}`.
`speed` is progress per step in 1/1024 of a tile. `shield` absorbs damage first. `summon` names an
enemy kind (that does not itself summon) produced every `summon_every` steps, `summon_cap` times.
`burn_*`: every `burn_every` steps, structures and heroes within `burn_radius` take `burn_power`.

Enemies walk a flow field toward their sink. When no open path exists they attack the structure in
their way. An enemy next to a hero fights it. A hero is downed, not destroyed, at zero hit points.
Shields absorb before hit points for structures and heroes alike.

## Moments and triggers

A moment pauses the battle and names a scene. Each moment fires at most once. The closing moments
`battle_won` and `battle_lost` fire at the end and do not count toward `moment_cap`.

| Trigger | `arg` | `arg2` | `arg3` | Fires when |
| --- | --- | --- | --- | --- |
| `step` | step count | | | the battle has run that many steps |
| `wave_start` | wave number (1-based) | | | the first enemy of that wave has spawned |
| `structure_destroyed` | structure id | | | the structure has been ruined |
| `leak_count` | count | | | that many enemies have reached a sink |
| `hero_downed` | hero id, or 0 for any | | | a hero has been downed |
| `hero_hp_below` | hero id | percentage | | the hero is alive and below that percentage |
| `heroes_near` | hero id | second hero id | distance | both are alive within that many tiles |
| `enemy_kind_seen` | enemy kind (1-based) | | | an enemy of that kind has spawned |
| `battle_won`, `battle_lost` | | | | the battle ends that way |

Validation refuses a moment that names a hero or structure that the setup does not contain, so a
moment about a hero is listed only when that hero is deployed. A moment that names an unknown scene
is refused by the host before the battle starts.

## Modifiers: `battle_sync`

After a moment's scene the host calls the project's `battle_sync(session, context)` and gives the
result to `h:sync`. `context.downed` is the id of a hero a moment found fallen. Every sync starts
from a clean slate: bonds, global and hero modifiers are re-sent whole; events are sent once.

| Entry | Fields | Effect |
| --- | --- | --- |
| `hero_mods` | `{hero, radius, damage, obedience, rate}` | added to the hero's ability radius, weapon damage percent, obedience points, ability power percent |
| `bonds` | `{a, b, within, damage}` | while both are alive within `within` tiles, towers within 3 tiles of either do `damage` percent more |
| `global` | `{damage, bounty}` | percent more damage for every tower; percent more bounty |
| `orders` | `{hero, order = "hold"/"move"/"follow", q, r, target}` | the story's orders; never ignored |
| `reinforce` | `{kind, q, r}` | an allied structure appears at or near the tile |
| `heal` | `{lantern = n}` or `{hero, amount}` or `{near_hero, radius, amount}` or `{structure, amount}` | `lantern` takes `n` leaks off; a downed hero stands again |
| `damage` | `{hero, amount}` | hit points lost (a hero may go down) |
| `reveal` | `{sector, ...}` | reveals fog sectors (1-based) |
| `end_with` | `"withdrawn"` | the battle ends; `pump` returns `"withdrawn"` |

## The outcome

```
result      "running", "won", "lost" or "withdrawn"
steps, kills, leaks, credits, digest
sink_leaks  {[i] = leaks that reached sink i}
seen        {enemy kinds met, 1-based}
revealed    {[sector] = true}
structures  {[i] = {id, kind, q, r, hp, level, sold, destroyed}}   towers only, in slot order
heroes      {[i] = {id, hp, downed}}
```

## The project hooks and the game host

A project manifest may name four functions (`"module.function"`, resolved like `after_choose`):

| Hook | Called | Returns |
| --- | --- | --- |
| `battle_request(session)` | after every boundary of the hub | a table (the request), or nil |
| `battle_setup(session, request)` | when there is a request | the setup table |
| `battle_sync(session, context)` | when a moment's scene has ended | the modifiers table |
| `battle_result(session, outcome, info)` | when the player goes on after the battle | nothing; it writes the world. `info = {request, setup}` |

`GameHost` runs a battle from them: **build** (commands accepted at step 0), then **begin** (the
silent judge: a raid on a copy at 30 percent chips the thinnest structure, never destroying it),
then **night** (pumped at the player's speed; a moment starts its scene on the same session and the
view shows its beats over the battle), then **ended**. The player then goes on (`battle_result`),
retries (the world returns to the snapshot taken when the battle was asked for) or abandons (the
world returns to before the choice that asked for it).

There is no saving during a battle: `GameHost.save` refuses with a reason in every phase, and the
autosave is the world at the battle's start, so Continue begins the battle again. Nothing the
battle does is saved except through `battle_result`.

`session:record_input(:battle, text)` records a battle in the session's replay log; the sample's
result hook writes the night, the result and the digest.

## Determinism

The simulation uses integers only. It reads no clock and no file; the only random numbers are the
obedience draws of a hero's orders, from the setup's seed. Enemies are removed in index order, so
the same setup and commands give the same digest on every platform. A run to step N equals a rerun
to step N, and a command log replays to the same outcome. The step allocates nothing (checked in
`tests/unit/test_battle.d` with the collector's counters).

## Static checks

`varis check` reads battle data without running it: a table with `ability = "..."` or
`trigger = "..."` is checked for unknown ability and trigger names (`unknown-ability`,
`unknown-trigger`, with a suggestion), missing tower fields (`missing-battle-field`), a moment's
scene (`unknown-scene`) and a trigger's literal arguments (`bad-battle-argument`), each at the
literal's position. Computed values are left to the bridge's validation when the battle starts.

## Not implemented

Travelling projectiles (every shot is hit-scan with a cosmetic flight), Dijkstra route costs, a
`varis battle` command (the sample's text host runs a night headless: `bin/varis main.lua --bot`),
the 435,600-tile overview texture and incremental route updates, and the moment cap spacing rule.

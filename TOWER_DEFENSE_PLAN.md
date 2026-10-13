# Plan: a native hex tower-defense battle, bridged to the Varis story engine

Status (October 12, 2026), landed: **TD1 and TD2** (the `source/varis/game/` leaf: hex, terrain,
fog, route, kinds, types, battle; tests in `tests/unit/test_battle.d`, suite `battle`), and, with
the sample *Lanternfall* (`sample-td/`, [SAMPLE_TD_PLAN.md](SAMPLE_TD_PLAN.md)), slices of the rest:
**TD3** (the four hooks run by `GameHost`: setup validation, moments as scenes, sync, result, abandon
and retry by snapshot, no save during a battle; `lib/battle.d`), **TD4** (the SDL battle view,
`tools/sdl/battleview.d`: prisms with terrace lift, billboards, camera, picking, HUD with reasons,
moment overlay), a **TD5** slice (four zoom bands, fog, minimap, a frame per band in the smoke; not
the overview texture or caches), **TD6** (hub to battle and back, the silent raid and forecast,
economy, fog growth, sources and sinks appearing) and **TD7** content (all ten primitives, heroes
with trust and bonds, injury and death rules, the French pack). The behaviour is described in
[docs/battle.md](docs/battle.md). Not yet: TD0's budgets in `benchmarks/targets.toml` and the render
spike, travelling projectiles, Dijkstra costs, `varis battle`, the 435,600-tile view caches. Changes
from this plan: the simulation also draws the obedience of heroes from its seeded generator (replay
agrees); an enemy next to a hero fights it; `attack_every` paces melee; `wall_density` and
`terrace_rows` let a map be designed; modifiers are commands in the log (`replay` agrees).
TD2 simplifications, recorded for TD7 and **since closed**: heroes, aura, shield, summon, repair,
taunt and burn are simulated; hit-scan is kept; fields are plain BFS.
Measured at TD2 (scratch harness, release, M1): reference scale (2,000 enemies, 200 towers) mean
0.017 ms and max 0.11 ms per step; stress (10,000 enemies, 600 towers) mean 0.049 ms and max 0.18 ms.
These scenarios are a single corridor where enemies die early, so they are a floor, not a full
battle. The rest of this document is the plan.

Earlier status: **plan only. Nothing in this document is implemented**, except two
measurement programs, `benchmarks/experiments/td_tick.lua` and `benchmarks/experiments/td_native.d`,
whose numbers are in §1. The manual in `docs/` remains the only definition of what the language does
today. Section 2 records the owner's decisions of October 12 and the defaults used elsewhere; the
owner can overturn any default.

Goal: the battle half of the tower-defense / visual-novel hybrid (memory note of October 11, 2026;
§3). The battle is a **native D simulation** with a 2.5D, pointy-top hex view in the SDL3 player.
It is joined to the story engine by a narrow bridge: the world model decides what a battle starts
with and what it means afterwards, and the player's relationships with the characters (heroes)
shape the battle; the battle reports what happened. Story moments can interrupt a battle.

The design in one paragraph: **the world decides meaning, the battle simulates, the host draws.**
Datalog rules turn relationships and story state into a `BattleSetup`; a deterministic integer
simulation in `source/varis/game/` runs the battle at a fixed step with no Lua in its loop; named
moments pause it and play ordinary scenes; a `BattleOutcome` goes back through one transaction. A
battle is atomic: there is no saving during one, and abandoning it restores the snapshot taken at
its start.

## 1. What was measured

Release builds, the development Mac (Apple Silicon), CPU milliseconds. The scenario is the same
in both programs: pointy-top axial hex tiles with about 12 % blocked; a breadth-first flow field
to one sink; towers with hex-disc footprints (radius 3); each tower picks the enemy nearest the
sink in range, ties to the lowest id; damage summed per enemy and applied; every enemy moves one
hex. The native program is a toy (one damage kind, no projectiles or statuses); a real step costs
several times more per enemy.

| Live enemies / towers | Relational step (Varis, `td_tick.lua`) | Native step (D, `td_native.d`) |
| ---: | ---: | ---: |
| 1,000 / 120 | 3.18 ms | 0.014 ms |
| 3,000 / 300 | 9.50 ms | 0.061 ms |
| 10,000 / 600 | not run (about 44 ms at 8,000, earlier run) | 0.21 ms |
| per enemy per step | about 3,200 ns | **15–21 ns** |

| Map of 435,600 tiles (880 × 495) | Native, arrays | Relational, as facts |
| --- | ---: | ---: |
| Full flow field (breadth-first) | **5–6 ms**, 2 MB | needs a corridor; 500,000 keyed facts load in 350 ms and take 133 MB |

What follows:

1. **The simulation is native** (§2, B1). About 150× cheaper per enemy; a 3,600-step judge at
   3,000 enemies is 0.2 s rather than 30 s; no garbage-collector pressure in the loop.
2. **The map is arrays**, a seed plus edits (B7). A full flow field over the whole revealed map
   costs 5 ms, so there is no corridor restriction and no materialised geometry.
3. **What stays relational is what the engine is good at**: relationships, injuries, unlocks,
   fortress layout, story flags and the rules that turn them into battle parameters and
   consequences (§5). Rule heads cannot compute (manual §4.4), which is fine for decisions and
   wrong for kinetics; that is the line.
4. **The relational simulation is recorded, not built** (Appendix A), with the findings that
   were useful anyway: set semantics collapse equal contributions (a `sum` over a relation that
   drops its source gave 14 instead of 18), query results are unordered, and the narrative
   scheduler commits once per action instance.

## 2. Decisions

"Owner" means the owner said it; "Prior" is from the October 11 brainstorm and is only a starting
point; "Plan" was proposed here.

| # | Decision | Source | Consequence |
| --- | --- | --- | --- |
| B1 | **The tower-defense simulation is native D**, with no Lua in its loop. The VN engine sees it only through the bridge of §5: setup in, moments, outcome out. | Owner, Oct 12 | §4–§6. Modders get data (kind tables, setup derivation) first; more hooks later (B2). |
| B2 | **More hooks for mods later.** The first version exposes data (kinds, rules in the setup hook), not callbacks into the loop. | Owner, Oct 12 | Hook names and the kind tables are kept namespaced and versioned so callbacks can be added without a format break. |
| B3 | **No saving during a battle.** A battle is atomic: leaving it restores the snapshot taken at its start; the autosave is written at battle start and after the result is applied. VN moments inside a battle are not save points. | Owner, Oct 12 | No native blob in saves, no envelope, no save-format change. Replay and rewind come from determinism (§6.4). |
| B4 | **The fortress persists in relations.** Structures (id, kind, tile, level, hp, ruin), hero state and the map's edits are facts; the simulation receives them at battle start and returns changes. | Owner, Oct 12 | Storylets can ask `when { destroyed(:bridge_tower) }` with no special support. |
| B5 | **2.5D, pointy-top hexes, zoomable.** Pointy-top axial coordinates; a tilted projection with elevation and billboard sprites; a camera zoom with level-of-detail bands (§7). | Owner, Oct 12 | The view is render state; it never affects the simulation and is not saved. |
| B6 | **Fixed-step integer simulation**, 20 steps per second by default; positions in 1/1024 of a tile; floats only in rendering. The simulation never reads a clock. | Plan | Bit-exact on every platform; the renderer interpolates. |
| B7 | **Map = seed + edits.** Terrain and height are pure functions of `(seed, q, r)` using integer hashing; player and story changes are edit facts; fog is a set of revealed sectors. | Plan | Saves stay small; 500,000 tiles cost memory in arrays only. |
| B8 | **One simulation, three drivers**: the live battle, the headless judge (silent mid-week evaluation) and tests/bots. | Plan | One source of truth for balance; `varis battle` plays a setup file headlessly. |
| B9 | **A new leaf module group `source/varis/game/`** that imports nothing from Varis (neither the core, the world model nor the narrative layer). `services/battlehost.d` translates between it and the engine. | Plan (touches D9) | `tools/check_sources.py` gains the rule; AGENTS §4.1 and §6 change in TD1. |
| B10 | **Heroes are story characters** with a battle role. Their relationships (qualities and bond facts) are inputs to the setup; their state after the battle is decided by the world, not by the simulation. | Prior + Plan | §3, §5.4. The simulation reports "downed", the story decides injured or dead. |
| B11 | **Weekly cadence** (prior): about 50 rounds; 6 (maybe 12) periods a week; Wednesday–Friday judged silently; Saturday a real-time battle where play is repairing towers and moving units. | Prior | The machinery is here (periods and the judge); designing the week is game design after TD6. |

## 3. The game, as far as the engine must know it

Priors from the October 11 brainstorm and the October 12 messages, not designs:

- About 20 hours; at most about 50 rounds; one battle per round, a few minutes long.
- Map 16:9, about 500,000 tiles at the end: 80 × 45 revealed at the start, the rectangle growing
  16 columns and 9 rows per round (880 × 495, about 436,000 tiles, at round 50); more sources
  (where enemies appear) and sinks (where they must not arrive) as the map opens.
- A hero mechanic: the player's relationship with each character changes parts of the battle.
- Some enemies damage towers; characters can be injured or die.
- Choices made during a battle can change other stats; short VN moments during a battle let
  characters interact.
- Everything outside the battle is the existing story machinery (storylets, scenes, stage,
  qualities, saves, localization).

What the bridge must therefore carry: relationships and story state in; hero state, structure
state, rewards and flags out; named moments that interrupt; a small closed set of story-driven
changes back into a running battle (§5.3).

## 4. Architecture

```
  tools/sdl   BattleView, camera, HUD, input            (draws from BattleView; no engine calls)
  services    BattleHost: setup, moments, result, retry (the only place Lua and `game` meet)
  narrative   session, scenes, qualities, saves         (unchanged)
  world model relations, rules, queries                 (unchanged)
  core        Lua                                       (unchanged)
  game        hex, terrain, fog, route, kinds, battle   (leaf: imports nothing from Varis)
```

Ownership of every piece of data:

| Data | Authoritative in | Crosses the bridge as |
| --- | --- | --- |
| Relationships, bonds, hero injuries and deaths, unlocks, story flags, economy totals | Relations (the world) | Derived into `BattleSetup` at start, re-derived into `Modifiers` after each VN pause |
| Fortress: structures, levels, hp, ruins; map edits; revealed sectors | Relations (sparse, hundreds of rows) | In `BattleSetup`; changes returned in `BattleOutcome` |
| Kind tables (towers, enemies, heroes, abilities), waves | Project data (Lua tables, content tier) | In `BattleSetup` |
| Positions, hp, cooldowns, statuses, projectiles, orders, per-battle fog visibility | The simulation | Only the outcome summary crosses back |
| Camera, zoom, selection, UI state | The view | Never; settings file only |

Module layout (all new; each `.d` has the licence header and is listed in the Makefile):

| Module | Content |
| --- | --- |
| `game/hex.d` | Pointy-top axial maths on integers: tile id `(q + 1024) * 4096 + (r + 1024)`, neighbours, distance, disc, ring, line, in-bounds. `@nogc nothrow`, no allocation. |
| `game/terrain.d` | Chunked terrain from `(seed, q, r)` by integer hashing (no libm): biome and integer height 0–7; edit overlay; passability. |
| `game/fog.d` | Sectors of 16 × 9 tiles, revealed set, visibility queries. |
| `game/route.d` | Breadth-first and Dijkstra flow fields per sink over the revealed map, blockers and costs; full recompute and a bounded incremental update. |
| `game/kinds.d` | `TowerKind`, `EnemyKind`, `HeroKind`, `Ability`: plain structs; validation returns a status and a message. |
| `game/battle.d` | Simulation state as structure-of-arrays, the step, commands, moments, cues, digest. |
| `game/types.d` | `BattleSetup`, `Modifiers`, `Command`, `Moment`, `Cue`, `BattleOutcome`, `BattleView`. |
| `services/battlehost.d` | `BattleHost`: runs the hooks, owns the pump, plays moment scenes, applies the result, handles abandon and retry. |
| `tools/sdl/battleview.d` | `BattleWidget` and the HUD widgets; camera, projection, picking, level of detail. |

## 5. The bridge

### 5.1 Contract

The project manifest (`project.lua`) names four optional functions, resolved like `after_choose`:

| Manifest field | Called | Receives | Returns |
| --- | --- | --- | --- |
| `battle_request` | at each boundary, read-only | the session | `nil` or `{id, kind, round, ...}` (set by an ordinary choice effect, e.g. a fact `battle_pending`) |
| `battle_setup` | when a battle starts | the session, the request | a `BattleSetup` table |
| `battle_sync` | after each VN pause in a battle | the session | a `Modifiers` table |
| `battle_result` | when a battle ends | the session, the outcome table, `{judged, silent}` | nothing; writes the world in one transaction |

All four are ordinary Lua project code; the first three are read-only queries over the world and
may be written as rules plus a loop (§5.4). Hooks are called only at idle boundaries, never from
the simulation loop. `services/battlehost.d` converts the returned tables to `game/types.d`
structs and validates them (unknown kind, tile outside the map, missing sink) with diagnostics
that name the field; a failed validation refuses to start the battle and the world is untouched.

### 5.2 Setup and outcome

| `BattleSetup` | Content |
| --- | --- |
| identity | `seed` (derived from the session seed and the round), round, kind (`saturday`, `judge`), step rate |
| map | map seed, region, edit list, revealed sectors, sources, sinks |
| fortress | structures `{id, kind, tile, level, hp}` |
| heroes | `{id, kind, tile, hp, stats, mods}`; deployment tiles |
| kinds | tower, enemy, hero and ability tables for the kinds used |
| waves | `{source, kind, count, every, start, escort...}` |
| modifiers | global multipliers (damage, speed, income, repair), per-hero stat changes, **bonds** `{a, b, bonus, range}` |
| moments | `{id, trigger, scene, once = true}` (§5.3) |
| rules | win and lose conditions (sinks held, waves cleared, time) |

| `BattleOutcome` | Content |
| --- | --- |
| result | `won`, `lost`, `withdrawn`; steps run; digest |
| structures | `{id, hp, destroyed, level}` for every changed one |
| heroes | `{id, hp, downed, kills, damage_taken, deployed_steps}` |
| economy | credits earned and spent, bounties |
| flags | moments fired, first sightings (`enemy_kind_seen`), leaks by sink |
| map | edits made (craters, cleared tiles) |

`battle_result` is the only place the world changes because of a battle. It decides what "downed"
means: injured until round N, dead, or merely shaken, from relationships and decisions made in
moments. The simulation never kills a character; it reports.

### 5.3 Moments, commands, sync

**Moments.** A moment is `{trigger, scene}` in the setup. Triggers are a closed vocabulary the
simulation evaluates natively and cheaply; each fires at most once per battle and the host
enforces a per-battle cap so a battle is not a series of interruptions:

`step(n)`, `wave_start(n)`, `hero_hp_below(hero, pct)`, `hero_downed(hero)`, `structure_destroyed(id|kind)`,
`leak_count(n)`, `heroes_near(a, b, distance)`, `enemy_kind_seen(kind)`, `battle_won`, `battle_lost`.

When one fires the simulation returns a `Moment` from `step()`, the host stops pumping, plays the
named scene with `session.playScene` (existing machinery: say, menu, input, effect beats; the
scene's effects write the world as usual), and while the scene is active draws it over the dimmed
map. When the scene stack empties the host does **not** call `present()` (which would draw the
storylet deck and consume session RNG); a `battleActive` flag in `GameHost` suppresses it.
Pre-phase actions still run while a scene is presented, as in any scene.

**Sync.** After a moment's scene the host calls `battle_sync`, a re-derivation of the mutable part
of the setup. `Modifiers` is a closed list so the world cannot corrupt the simulation:

| Entry | Effect |
| --- | --- |
| `hero_mods` | stat and ability changes per hero |
| `bonds` | the bond list replaced |
| `global` | damage, speed, income, repair multipliers |
| `orders` | a hero retreats, holds, or follows another |
| `reinforce` | spawn units of a kind at a tile (allies or enemies) |
| `heal`, `damage` | hit points of a hero or structure |
| `reveal` | reveal a sector |
| `end` | end the battle with a named result (a story decision to flee) |

**Commands.** Player input during a battle is not narrative: `place`, `sell`, `upgrade`, `repair`,
`move_hero`, `use_ability`, `set_speed`, `pause`. They are stamped with the step index at which
they apply and appended to the battle's command log.

### 5.4 Relationships into the battle

Relationships are ordinary qualities and facts. Rules derive the battle parameters; the setup
hook reads the result with a query:

```lua
-- checked in the engine (October 12, 2026): with trust 4 and 1 these give mira rally 2 and obey 4,
-- dane obey 1 and guarded 1, and the bond; relation names are illustrative
rule hero_mod(?h, :rally, 2)     :- hero(?h), quality(?h, :trust, ?t), ?t >= 3
rule hero_mod(?h, :obey, ?o)     :- hero(?h), quality(?h, :trust, ?o)
rule bond(?a, ?b, 4)             :- bond_fact(?a, ?b, ?x), ?x >= 3, deployed(?a), deployed(?b)
rule hero_mod(?h, :guarded, 1)   :- hero(?h), injured(?h), not healed(?h)
```

The simulation uses the numbers deterministically: `obey` becomes the probability that a hero
follows a player order, drawn from the battle's own seeded generator; bonds add to damage or
cooldown when both heroes are within `range` hexes; `rally` is an aura. None of this runs Lua
during the battle.

### 5.5 Save, abandon, retry, replay

- **Saves are unchanged.** No battle state is ever in a save (B3). A save during a battle is
  refused with a reason; the F5/F9 keys and the pause menu say so.
- At battle start the host calls `session:save()` once and keeps the text in memory, and writes
  the autosave. **Abandon** and **retry** restore that text (`GameHost.restore`), which also undoes
  whatever the moment scenes wrote. Quitting during a battle and choosing Continue starts the
  battle again.
- **Replay and debugging** come from determinism: `(setup, seed, command log, moment choices)`
  reproduce the outcome and digest exactly. The host keeps the log in memory and may write it to a
  sidecar file; `varis battle` replays it headlessly to any step. At the end the host calls
  `session:record_input(:battle, "<round>:<seed>:<result>:<digest>")` (a portable string; a plain
  table is rejected by the codec) so the session's replay log shows that the battle happened and
  how it ended, in one record.

## 6. The simulation

### 6.1 State and style

Structure-of-arrays (`tile[]`, `progress[]`, `hp[]`, `kind[]`, `status[]`, … per entity class),
capacity chosen in `begin()`, nothing allocated in the step. Entities have stable integer ids;
removal compacts in index order so iteration order is the same on every platform. Code follows
AGENTS §3: `@nogc nothrow` kernels, status returns, no exceptions, no associative arrays or
Phobos ranges; a kernel that runs out of room returns "need more room" and its caller grows the
buffers (AGENTS §3.2).

### 6.2 The step

One fixed step, in this order, with ties broken by entity id:

| Phase | Work |
| --- | --- |
| 0 | Apply commands stamped for this step, then `Modifiers` queued by the host. |
| 1 | Spawn due waves and reinforcements; allocate ids. |
| 2 | Heroes: orders, movement, abilities (obedience drawn from the battle generator). |
| 3 | Enemies: move along the flow field of their sink, or attack the structure blocking the next hex. |
| 4 | Towers and heroes: bucket enemies by tile, pick targets (nearest the sink, ties lowest id), fire, cooldowns, statuses applied. |
| 5 | Enemy attacks on structures and heroes; hp updated. |
| 6 | Status ticks; deaths, bounties, leaks; structures at 0 hp become ruins; heroes at 0 hp become **downed**. |
| 7 | Evaluate triggers; the first `Moment` pauses the loop. Evaluate win and lose rules. |
| 8 | Fill the cue buffer (hits, deaths, leaks, builds, abilities) for audio and effects. |

Projectiles are hit-scan in the first version, with a visual flight time carried by the cue;
travelling projectiles are a TD7 decision (§12).

### 6.3 Data-driven kinds

Kinds are plain structs filled from Lua tables in content-tier files: range, damage, damage type,
cooldown, cost, hit points, speed, armour, abilities from a closed set of primitives (single
target, splash, chain, slow, burn, aura, shield, summon, repair, taunt). A designer or a modder
composes kinds from primitives and changes numbers. A new primitive is a D change until the hooks
of B2 arrive. `varis check` validates the tables like any other content.

### 6.4 Determinism and testing

- Integers only; the generator is SplitMix64 from `BattleSetup.seed`; no `float` in state; no
  clock; no iteration over unordered containers.
- `digest()` hashes the enumerated fields of the state (not raw struct bytes, so padding cannot
  matter). Golden battles (fixed setup, scripted commands) must give the same digest on every
  supported OS.
- `varis battle setup.json [--commands log] [--until N] [--digest]` runs headlessly; the bot, the
  judge and the SDL smoke tests all call the same `Battle`.
- A battle can be rewound by re-running from the start (about 0.2 s for 3,600 steps at the
  reference scale), so the workbench's story-level "rewind" needs no snapshots.

### 6.5 Judging

The judge runs the same `Battle` on a copy of the setup with its own derived seed, headless and as
fast as it can (about 0.1–2 s). What it *means* is an owner decision (§12, item 1). The plan
supports both readings with one mechanism: `battle_result` is called with `judged = true` and
`silent = true` (no toasts, no scene), and the project either applies consequences or only
records a forecast fact that storylets can read ("the north wall will not hold").

## 7. The battle view: 2.5D, pointy-top, zoomable

Render-only state: nothing here affects the simulation or a save, and drawing makes no engine
call.

### 7.1 Projection and elevation

With hex size `S` (centre to corner, in world units), pointy-top axial `(q, r)` and integer
height `h` from the terrain store:

```
x = S * sqrt(3) * (q + r / 2)
y = S * 1.5 * r * T  -  h * Z
```

`T` is the vertical squash (default 0.58) and `Z` the pixel height of one elevation level
(default `0.35 * S * T`), both in the manifest. A tile is drawn as a prism: a squashed top face
and up to two visible side faces (to the lower neighbours at the front, down to the base on a
cliff), shaded by constant factors. Sprites are billboards anchored at the tile centre, not
squashed. Camera rotation is out of scope in the first version (60° steps could come later).

### 7.2 Draw order and picking

Back to front by row: for each visible row, tile prisms, then decals (range rings, build
previews), then entities of that row sorted by screen `y` then `x`, then effects and cue sprites;
bars and labels last, in screen space. A front cliff covers what is behind it for free.
Entities draw at `lerp(previous, current, alpha)` of the last two steps.

Picking inverts the flat projection to a candidate hex, then tests the elevated top faces of the
candidate and its neighbours from front to back; entities are tested first by screen-space hit
shapes. Both are small, allocation-free functions with unit tests.

### 7.3 Zoom and level of detail

Zoom is a scale factor on world units, applied about the cursor for the wheel and pinch, with
keys `+`/`−`, `Home` to fit the revealed region, and a short ease. The range is "whole revealed
region" (about 16 px per hex at the start, 1–2 px at the end) up to about 1.5× the default
(default: 64 px hex width at 1280 × 720). Pan: drag with the middle or right button, or arrows/WASD;
the camera is clamped to the revealed area plus a margin. Bands, by on-screen hex width:

| Band | Hex width | Terrain | Entities | Overlays |
| --- | ---: | --- | --- | --- |
| Overview | < 12 px | One CPU-composited overview texture (terrain, fog, structures) | Dots (`SDL_RenderPoints`) | None |
| Tactical | 12–28 px | Flat or low prisms from vertex arrays | Icons, hp as colour | Selected range ring |
| Standard | 28–80 px | Full prisms | Sprites, facings, hp bars | Rings, bonds, orders |
| Close | > 80 px | Full prisms with detail | Animation frames, labels, projectile trails | All |

The HUD is in UI units and does not scale with the camera; the existing text-size setting
(80–175 %) applies to it. A moment may take the camera: ease to the hero, then back.

### 7.4 Fog

Unrevealed sectors are drawn dark with a soft edge from per-vertex colour; revealed sectors
normal. A third "remembered" state is not in the first version. Revealing a sector (a round
passing, a story `reveal`) animates over a few frames.

### 7.5 Bridge and player work

| # | Item | Today | Needed |
| --- | --- | --- | --- |
| S1 | Draw primitives | `v_rect`, `v_outline`, whole-texture `v_draw`, `v_clip` | `v_geometry` (coloured and textured triangles, `SDL_RenderGeometry`), `v_points`, `v_lines`, `v_draw_region`, `v_target` (render to texture), `v_texture_new`/`v_texture_update` (streaming overview). Each with a headless smoke check. |
| S2 | Input | left-down, motion, wheel, keys down | right and middle buttons, button-up, drag, key-up (held pan keys), modifiers, precise wheel; touch and pinch later. |
| S3 | Frame loop | 16 ms sleep per frame, engine called on events | Fixed-step accumulator over `v_ticks`; `pump()` per frame with a step cap (5); a slow machine runs the battle slower, never skips steps; frame pacing or vsync. |
| S4 | `BattleWidget` | `MapView` draws a node graph | Camera, projection, picking, culling to visible rows, layers, bands. Vertex buffers preallocated; no allocation per frame. |
| S5 | HUD | status panel, toasts | Credits and integrity, wave bar, build palette with costs and `because` reasons, hero panel (hp, trust, abilities), speed (pause, 1×, 2×, 4×), minimap from the overview texture, selection panel. Built from the existing toolkit. |
| S6 | Moment overlay | scene drawing in `GamePlayer` | The existing scene presentation drawn over the dimmed battle view. |
| S7 | Manifest `battle` | `map` place graph | hex size, `tilt`, `elevation`, terrain colours or atlas, kind → sprite with three drawn facings (three more mirrored), effect styles, fog colour, zoom limits and bands. Placeholder art is polygons and vertex colours. |
| S8 | Audio | channels, one-shots | A pooled track set for cues, de-duplicated per step. |
| S9 | Smoke | `VARIS_SMOKE_PLAY=ui` | `VARIS_SMOKE_PLAY=battle`: scripted commands and zoom levels, one frame capture per band, and the digest compared with the headless run. |

## 8. Content and tools

- `sample-td/` (working directory; title open): project manifest with the four hooks, kind
  tables, a few rounds of waves, two or three heroes with trust qualities, three or four moments
  as scenes, an economy. Same tiers and layout as `sample-rpg/`; its own test suite.
- `varis check`: kind tables, wave references and moment scenes are checked statically (unknown
  kind, unknown scene, trigger arguments).
- `varis battle` (headless runner) and a bot for balance gates ("rounds 1–10 are winnable with the
  starting budget; a no-build run loses by round 3").
- A **battle inspector** for the workbench: the setup, the current step's state as tables, the
  cue log and the digest. It reads `Battle`, never mutates it.
- Localization: kind, hero and cue names go through `name.<symbol>`; moment scenes are ordinary
  scenes with line ids; French is the first pack.

## 9. Budgets

Provisional. The M1 column is what the stage gates assert (absolute budgets in
`benchmarks/targets.toml`); the low-end column assumes the owner's open decision 3 default of ten
times slower than the M1 and is a design target.

| Measure | Reference scale | M1 budget (spike) | Low-end (×10) |
| --- | --- | ---: | ---: |
| Simulation step | 2,000 enemies, 200 towers, 6 heroes | ≤ 1 ms (0.03 toy) | ≤ 10 ms of a 50 ms step |
| Simulation step, stress | 10,000 enemies, 600 towers | ≤ 4 ms (0.21 toy) | not a target |
| Flow field, full revealed map | 435,600 tiles | ≤ 8 ms (5–6) | ≤ 80 ms: incremental update on build |
| Judge | 3 minutes = 3,600 steps, reference scale | ≤ 2 s | ≤ 20 s, off the frame |
| `battle_setup` / `battle_sync` / `battle_result` | 200 structures, 6 heroes | ≤ 50 / 20 / 50 ms | — |
| Battle-start snapshot (`session:save()`) | existing budget | ≤ 50 ms | — |
| Render frame | 6,000 visible tiles, 600 entities, standard band | ≤ 8 ms | 30 fps |
| Render frame, overview band | whole map | ≤ 3 ms | 30 fps |
| Memory | map arrays plus simulation at 10,000 enemies | ≤ 16 MB; chunk and geometry cache capped at 64 MB | — |

## 10. Stages

None depends on the Lua-core performance stages (L, X); all proceed beside them. Benchmark stages
must not run alongside other heavy jobs.

| Stage | Deliverable | Exit test |
| --- | --- | --- |
| **TD0** | Freeze the contract: §5 types, hook names, trigger vocabulary and `Modifiers` list written as a `docs/battle.md` draft; a `td_native` benchmark group with absolute budgets; a render spike (prisms via `SDL_RenderGeometry`, painter's order, picking) to confirm the §9 render budgets and the level-of-detail thresholds. | Budgets recorded in `benchmarks/targets.toml`; the spike's frame times in this document; every §12 item still "default" or "decided". |
| **TD1** | `game/`: hex, terrain (hashing, heights, edits), fog, route; layer rule in `tools/check_sources.py`; AGENTS §4.1/§6; unit tests (`test_battle.d`, manifest counts updated). | Hex identities and distances; golden hash of generated regions identical on two machines; flow field equals a reference BFS on random maps; layer check passes. |
| **TD2** | The simulation (`battle.d`, `kinds.d`, `types.d`): all §6.2 phases, commands, moments, cues, digest; `varis battle`; a bot. | Golden battles with fixed digests; two runs identical; replay from a command log identical; a rerun to step N equals a run through step N; step budgets held; no allocation in the step (checked with a counting allocator in tests). |
| **TD3** | The bridge: manifest fields, the four hooks on a test project, validation diagnostics, moments → scenes, sync, result, abandon and retry by snapshot, `record_input`; the `battleActive` flag in `GameHost`. | Host unit tests with status returns: a bad setup is refused and the world is untouched; a moment plays its scene and its effect changes the next sync; abandon restores the world bytes exactly; the sample-game golden and `make test` unchanged. |
| **TD4** | SDL battle view MVP: S1–S5 for the standard band, flat-shaded prisms, camera with zoom and pan, picking, commands, pause and speed; moment overlay (S6). | `make test-sdl` renders a battle and equals the headless digest; a scripted session builds, zooms, picks and finishes; frame budget met at the standard band. |
| **TD5** | Zoom and scale: all four bands, overview texture, culling, chunk and geometry caches, minimap, fog rendering, the 435,600-tile map; incremental route update. | Budgets of §9 for render and flow field; one capture per band in the smoke test; zoom limits and fit behave at the first and the last revealed size. |
| **TD6** | Game loop: hub ↔ battle by `battle_request`, weekly periods, the silent judge, economy, fog growth, sources and sinks appearing, autosave at start and result. | A scripted ten-round run through the player: no stuck state, every boundary saves and loads, abandon and retry work, `varis play` text host plays the same rounds with the headless battle. |
| **TD7** | Content: heroes with trust and bonds, enemy kinds that damage structures and heroes, six to eight tower kinds, moments, the injured/dead rules in `battle_result`, a decision on travelling projectiles, French pack, art pass beyond polygons, balance gates. | Bot clears rounds 1–10 under budget and fails without building; every kind and moment is reachable; `l10n status` complete. |
| **TD8** | Documentation and integration: `docs/battle.md` (setup, hooks, triggers, kinds, authoring guide), AGENTS §5/§6/§8, ROADMAP, coverage entries, `make test`, `make bench-check`, `make test-sdl`. | All gates pass; sample-game check unchanged. |

TD0–TD3 need no SDL and no art. A first playable battle with placeholder polygons is TD4.

## 11. Risks

| # | Risk | Mitigation |
| --- | --- | --- |
| R1 | **Two sources of truth.** A value changed in a moment's scene while the simulation holds its own copy. | The authority table (§4) and a closed `Modifiers` list; the simulation never reads relations and the world never reads simulation state except through the outcome. |
| R2 | **Moddability.** Modders cannot add mechanics without D. | Kind tables and a primitive set from day one; hook points reserved (B2); the relational alternative stays documented (Appendix A). Owner's call. |
| R3 | **Moment storms** make a battle feel like a cutscene reel. | Once-only triggers, a per-battle cap, a minimum number of steps between moments, tests that count moments in the bot's runs. |
| R4 | **2.5D complexity** (occlusion, picking on elevated tiles, billboards on slopes, art in six facings). | Painter's order by row; a render spike in TD0; flat-shaded polygons first; three drawn facings mirrored; unit tests for picking. |
| R5 | **Zoom range is large** (16 px to 1.5× default; 435,600 tiles). | Four bands with an overview texture and culling (§7.3); caches capped; measured in TD5. |
| R6 | **Retry cost**: restoring the start snapshot takes as long as a load. | Within the existing 50 ms save budget; measured in TD3. |
| R7 | **A long battle with no save** frustrates players. | Battles are minutes long (prior); the autosave at start and the immediate retry; revisit if the owner finds it hurts. |
| R8 | **Native code outside Lua's safety**: a simulation bug can crash the process. | Status returns and bounds-checked debug builds (`make varis-checked`) in tests; the digest and replay make a crash reproducible from a setup file. |
| R9 | **Scope**: weekly design, heroes' content, art and balance are large and are game design. | TD6 builds the cadence; TD7 content is capped at the numbers above; sample-td stays small. |
| R10 | **The SDL player is untested off macOS arm64.** | Smoke checks stay headless; portability is milestone 37's, not this plan's. |

## 12. Open decisions (owner)

Until decided, the default applies and each change says so (AGENTS §1.3, item 9).

| # | Question | Default |
| --- | --- | --- |
| 1 | What does judging mean: consequences applied silently, or a forecast stored for story to read? Do judged battles use the real seed? | The same battle on a copy with a derived seed; consequences applied silently (prior), with the forecast variant one project switch away. |
| 2 | Is "downed" for heroes recoverable within a battle (a revive ability)? Who can die permanently? | Downed heroes stay down for the battle; the world decides injury or death afterwards. |
| 3 | Do enemies path around structures, attack them, or both? | Around if a path exists; otherwise attack the blocking structure. |
| 4 | Is elevation gameplay (high ground range bonus) or only visual? | Visual in v1; a rule-driven bonus is a TD7 content decision. |
| 5 | Hit-scan or travelling projectiles. | Hit-scan with a cosmetic flight (v1); travelling in TD7 if a kind needs it. |
| 6 | Hero control: direct (the player moves them) or orders with obedience from trust. | Orders with an obedience roll from trust. |
| 7 | Camera rotation in 60° steps. | Not in v1. |
| 8 | Which hooks to add for mods first (B2): behaviour callbacks at coarse events (on hit, on death), or custom triggers and modifiers. | Not before TD8; keep names stable. |
| 9 | Title, art direction, and whether `sample-td/` reuses the Hollowbrook town as its story frame. | Working title only; placeholder polygons. |
| 10 | "The interface is zoomable" read as the battle camera. Should the HUD also scale with it? | No: the HUD follows the text-size setting. |
| 11 | Simulation rate. | 20 steps per second. |

## 13. Conventions

- New D code follows AGENTS §3; every new `.d` file has the licence header and is listed in the
  Makefile; the `game` modules import nothing from Varis (B9).
- No change to `proto.code`, fingerprints, save formats or the sample games (D12). The only new
  session record is a `record_input` of kind `battle`, which exists today.
- The simulation never reads wall-clock time, a file, or Lua; only the host maps real time to steps.
- Engine inspection is read-only; the inspector, the view and the debugger never mutate a battle
  and consume no session random numbers.
- Wording and assets stay out of content identity; tower, enemy and hero names are presentation data.
- Commits are focused: engine and simulation with their tests, content separately.

## Appendix A: the relational simulation, recorded and not built

Before the native split the plan modelled towers, enemies and waves as relations with a
transaction per step (`benchmarks/experiments/td_tick.lua`). It worked, and is kept as the
alternative should modding the loop in Lua become more important than speed.

| Live enemies / towers | Move query | Apply moves | Target and damage query | Apply damage | Step |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 200 / 40 | 0.20 | 0.17 | 0.31 | 0.00 | 0.68 ms |
| 500 / 80 | 0.47 | 0.40 | 0.70 | 0.03 | 1.61 ms |
| 1,000 / 120 | 0.91 | 0.83 | 1.39 | 0.06 | 3.18 ms |
| 3,000 / 300 | 2.67 | 2.54 | 4.11 | 0.18 | 9.50 ms |
| 1,000 / 120, moves sorted by id | 0.91 | 3.72 | 1.31 | 0.06 | 5.99 ms |

| Map tiles as facts | Load | Heap | First query | One write afterwards |
| ---: | ---: | ---: | ---: | ---: |
| 50,000 | 29 ms | 11 MB | 0.8 ms | 0.004 ms |
| 500,000 | 350 ms | 133 MB | 13 ms | 0.005 ms |

What it would have needed, and why it was dropped: a host command to run a procedure outside a
choice (`session:run`), effect-side random numbers, coalesced replay records (the replay log and
event history are saved and grow per command), transient relations excluded from saves, a
materialised geometry invariant (rule heads cannot compute), a corridor-limited flow field, and a
judge that took seconds to minutes. The patterns it validated remain valid for the setup
derivation of §5.4: aggregates (`sum`, `min`, `max`) do the arithmetic; a contribution relation must
carry its source or equal contributions collapse; query results are unordered, so sort only where
order is observable.

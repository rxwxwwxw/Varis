# Lanternfall: a tower-defense / visual-novel hybrid

Marrow Hill is built in terraces above a valley of fog. Every dusk the Dim climbs the switchbacks
towards the Lantern, and the Lantern burns only while somebody minds it. You are the new Warden,
with an old key and a letter, and three people who do not yet trust you: **Ilse**, who builds and
mends the lamps; **Corvin**, the retired captain who knows the roads; **Wren**, the courier child
who sees the Dim first. Four nights. The battle is real time and played on a 2.5D hex map; the story
decides what each battle starts with and what it means afterwards.

This is the **integration sample of the battle engine** (`SAMPLE_TD_PLAN.md`): every feature of the
battle bridge, the native simulation and the view is used at least once on the main path, and the
battle changes the story's world in ways the player can see.

```sh
make varis varis-sdl                          # from the repository root (needs SDL3 packages)
bin/varis-sdl sample-td/presentation.json     # the game: dusk hub, build, night, dawn
cd sample-td && ../bin/varis main.lua 7       # the same game in a terminal (--bot plays itself)
python3 tools/suite test --suite sample-td    # the sample's tests (about 15 s)
VARIS_SMOKE_PLAY=battle bin/varis-sdl sample-td/presentation.json --smoke build/sdl/lanternfall.bmp
```

The art and audio are generated placeholders (`python3 tools/gen_assets.py`); the battle itself is
drawn from the simulation, so only the story scenes need pictures. Replace a file in `assets/` with
finished art of the same name and nothing else changes.

## How it plays

| Part | What the player does |
| --- | --- |
| **Dusk** (hub) | Talk to the heroes (once a night each; the choices move trust), see to the infirmary, rebuild ruins, read the journal, then *Go up to the terraces*. |
| **Build** (battle view, paused) | Place, upgrade and sell lamps with 1–5 and a click; select a hero and click the ground to order a move. Zoom with the wheel, pan with arrows/WASD, `F` fits the map. *Begin the night* ends the phase. |
| **The silent days** | Nothing is shown. A raid on a copy chips the thinnest lamp; the engine's forecast is recorded and appears at the next dusk as Corvin's warning. |
| **Night** (battle) | A few minutes in real time at x1, x2 or x4: repair, move heroes, use their abilities (Ilse mends, Corvin taunts, Wren's flare burns and reveals). Story moments pause the battle and play ordinary scenes; the player's choices become modifiers. |
| **Dawn** | The result in the words the night earned; decisions about the bridge and the scree; then rest. |

There is no saving during a night. *Abandon* returns to the dusk before *Go up*; *Try again* restores
the world exactly as it was when the night began; the autosave is that snapshot, so Continue starts
the night again.

## What it exercises

| Engine feature | Where |
| --- | --- |
| `battle_request` set by an ordinary choice | `content/hub.varis` (`go_up`) |
| `battle_setup` derived by rules from relationships, fortress, flags | `game.lua` `battle_setup`, rules in `world.lua` (`deployed`, `obeys`, `ward`, `rally`, `wide_flare`, `reliable_repair`, `bonded`) |
| Setup validation refuses a bad setup and leaves the world untouched | `tests/bridge.lua` (seven fixtures), `varis check` negative fixtures in `tests/check/fixtures/battle` |
| All ten triggers | `battle/setup.lua` (moments), covered by `tests/branches.lua` |
| All nine modifier entries | `battle/sync.lua`, covered by `tests/branches.lua` |
| `battle_result`: ruins, injuries, trust, edits, fog, food, flags | `game.lua` `battle_result`; `tests/both_directions.lua` |
| Judged raid and forecast, both deterministic | `G.judge`, `G.forecast`; `tests/judge.lua` |
| Abandon, retry, no save during a battle | `tests/bridge.lua`, `tests/novice.lua`, `GameHost` unit test |
| Map = seed + edits, terraces, cliffs with gaps, sealed east road, fog rings | `battle/setup.lua` |
| Two sources and two sinks (the Mill, night 3) | `battle/setup.lua`, `battle/waves.lua` |
| All ten ability primitives | towers bolt/chime/hoar/arc/beacon; wraith shield + summon; maw burn; Ilse repair; Corvin taunt; Wren flare; Ilse ward from trust |
| Determinism: digests, rerun to step N, command-log replay | `tests/determinism.lua` |
| Window equals headless | `tests/sample_game/sdl_test.py` (`lanternfall()`) |
| Localization | `l10n/`, `packs/fr`, `tests/l10n.lua` |
| Static checks of battle data | `varis check` (clean) |

## Files

| File | Contents |
| --- | --- |
| `project.lua` | The manifest: entry, session/load hooks, the four battle hooks, locales |
| `world.lua`, `qualities.varis`, `game.lua` | Schemas and rules; quality metadata and names; sessions, hooks, the host loop, journal |
| `content/` | Hub storylets (`hub.varis`), people (`heroes.varis`) |
| `scenes/` | Characters and procedures, prologue, moments, dawns, endings |
| `battle/` | `kinds.lua`, `waves.lua`, `setup.lua` (map and setups), `sync.lua` (decisions to modifiers) |
| `tools/` | `bot.lua` (the scripted player), `gen_assets.py`, `fr_draft.py` |
| `tests/` | `bridge`, `determinism`, `branches`, `novice`, `both_directions`, `judge`, `hub`, `l10n` |
| `main.lua` | The terminal host |

## As built, against the plan

`SAMPLE_TD_PLAN.md` is the outline; the differences are recorded here and in its status note.

- **Fog growth.** Night *n* starts with a (n+2) x (n+2) block of 16 x 9 sectors (48 x 27, 64 x 36,
  80 x 45, 80 x 45); winning shows the next ring. Wren's flare reveals the valley (96 x 54) on night 4.
- **Terraces.** Four levels of 14 rows, one cliff row between them with a single gap; the map is
  axial, so a rectangle of tiles draws as a parallelogram.
- **The Lantern's gate.** The Lantern stands in a ring of walls with one gap held by the Bellfrey;
  while the bell stands the Dim must break it. `structure_destroyed(bellfrey)` is that moment.
- **Heroes fight.** An enemy next to a hero fights it, so heroes are downed on the road; a hero
  downed twice (or left behind on night 4) is dead.
- **Judge.** The raid chips a structure silently before the night; the forecast is made at dawn for
  the next night and shown at dusk.
- **Moments.** The nine modifier entries and ten triggers are all used on the main path; the
  scripted choices of the tests reach every ending.
- **Not built.** Travelling projectiles, the `varis battle` command (the text host's `--bot` plays a
  night headless), the stress setup of 10,000 enemies as a player-visible mode (the unit tests run
  it), and music cues per night.

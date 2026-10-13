# Plan: *Lanternfall*, a fifteen-minute tower-defense / visual-novel sample

Status (October 12, 2026): **implemented as `sample-td/`** (*Lanternfall*), stages SA–SH in one
slice, on the engine work of [TOWER_DEFENSE_PLAN.md](TOWER_DEFENSE_PLAN.md) (`source/varis/game/`,
`lib/battle.d`, the battle bridge in `GameHost`, the SDL battle view). What was built, and where it
differs from this outline, is in [sample-td/README.md](sample-td/README.md) ("As built"); the sample's
suite is `sample-td` (about 15 s, in `make test-fast`), plus the SDL smoke in `make test-sdl`. The
manual in `docs/` (see [docs/battle.md](docs/battle.md)) remains the only definition of what the
language does today. Differences worth knowing before reading on: the fog rings, the Lantern's gate
(Bellfrey), heroes fighting in melee, judge-at-dawn forecasts, and the cuts listed at the end of the
README (projectiles, `varis battle`, stress mode for players).

Goal: a second hybrid sample, `sample-td/`, whose job is to be the **integration test of the
battle engine**. About fifteen minutes of play across four nights. Every feature of the battle
bridge, the native simulation and the 2.5D view is used at least once on the main path, and the
battle changes the visual-novel world in ways the player can see: ruins in the hub, injured
characters missing from conversations, relationships that decide who obeys, flags that change the
ending. The story is small on purpose; the coverage is the point.

## 0. How to read this plan

- §1 is the game. §2 is the coverage table, the reason the game is shaped as it is: each row
  names an engine feature and the place in the game that exercises it.
- §3–§6 are the content outline: nights, heroes, moments and consequences, endings.
- §7 is how it is tested; §8 the files; §9 the defaults; §10 the stages, which follow the
  engine's; §11 the risks.
- Where the game would need an engine decision still open in the engine plan, the default stated
  there is used and listed in §9.

## 1. The game

**Premise.** Marrow Hill is a village built in terraces on a steep hillside above a valley full of
fog. Every dusk the Dim climbs the switchback roads towards the great Lantern at the top, and the
village survives only while the Lantern burns. You are the new Warden, arrived on the first night
with nothing but an old key and a letter. Three people stand with you: **Ilse**, the lampwright
who builds and mends the towers; **Corvin**, the retired captain who knows the roads; **Wren**,
the courier child who sees the Dim first. They do not yet trust you, and a lantern burns brightest
for people who do.

**Shape.** Four nights. Each night is a compressed week:

| Part | What the player does | Engine |
| --- | --- | --- |
| **Dusk** (hub) | Talk to the heroes, spend what the village has, decide something that matters later, read the journal. Storylets and scenes; no battle yet. | Existing story machinery |
| **Build** (battle view, paused) | Place, upgrade and sell lantern towers, deploy the heroes; zoom and pan over the terraces. | Battle commands at step 0 |
| **The silent days** | Nothing is shown. The engine judges the placed defences on a copy and applies the consequences without telling the player (a raid that chips a tower, a forecast stored for the story). | Silent judge |
| **Night** (battle) | A few minutes of real time; repair, move heroes, use abilities; story moments interrupt at named points. | Native battle, moments |
| **Dawn** (aftermath) | Scenes and hub changes that depend on exactly what happened. | `battle_result`, rules, storylets |

**Length.** About 15–16 minutes at normal speed, about 14½ with 2× in the two long battles (the
timetable is §3.1); 2× and 4× speed shorten battles. The headless bot is meant to play the whole
game in seconds; that is a budget for TD2, not a measurement.

**Presentation.** One 2.5D, pointy-top terraced map in the SDL3 player (cliffs, four terrace
levels, a road, ruins), a hub that reuses the Hollowbrook-style status panel, scenes with the
stage and portraits, and a battle HUD with a hero panel showing trust.

## 2. What it must exercise

Each row is a requirement of the engine plan; the right-hand column is where this game uses it.
A feature with no place in the game is a gap in the sample, not an exemption.

### 2.1 The bridge

| Engine feature | Where it is exercised |
| --- | --- |
| `battle_request` set by an ordinary choice effect | The hub choice "Go up to the terraces" sets a fact; the host starts the build phase. |
| `battle_setup` derived by rules from relationships, fortress and flags | `battle/setup.lua`: trust → obedience, rally and ward; bonds; unlocked kinds; deployed heroes; waves scaled by village morale; moments chosen by story state (a moment is only listed if its characters are present and alive). |
| Setup validation refuses a bad setup and leaves the world untouched | A test fixture with an unknown kind, an off-map tile and a missing sink (§7). |
| Moments and every trigger | Table 5.1. |
| `battle_sync` and every modifier entry | Table 5.2. |
| `battle_result`: structures, heroes, economy, flags, map edits | Table 5.3 and the consequences of §5. |
| Judged, silent result and the forecast variant | Nights 2–4 (§3). Both variants are used: attrition is applied; a forecast fact is stored. |
| Snapshot at battle start, abandon, retry, autosave at start and result | "Abandon" in the pause menu; "Try again" on the defeat screen; tests (§6). |
| No save during a battle | F5/F9 and the menu refuse with a reason in every battle phase, including inside a moment. |
| Pre-phase actions keep running during a moment's scene; the hub deck is not drawn | Test: the session's RNG state is the same before and after a moment (§7). |

### 2.2 The simulation

| Engine feature | Where |
| --- | --- |
| Map = seed + edits; fog by sector; the revealed rectangle growing 16 × 9 per night | Revealed 48 × 27 → 64 × 36 → 80 × 45 → 96 × 54 tiles. A collapsed bridge and a cleared scree path are map edits that persist. |
| Sources and sinks appearing | A second source on night 3; a second sink (the Mill) on night 3, so leaks are attributed per sink. |
| Flow field around structures; attack the blocker when there is no path | A wall of towers on the east road on night 3 makes husks attack it. |
| All ten ability primitives | Towers: Bolt (single target), Chime (splash), Hoar Lamp (slow), Arc Lamp (chain), Beacon (aura). Enemies: Wraith (shield, summon), Maw (burn). Heroes: Ilse (repair), Corvin (taunt), Wren (Flare: burn and reveal). Ward from high trust is a shield on a tower. |
| Commands: `place`, `sell`, `upgrade`, `repair`, `move_hero`, `use_ability`, `set_speed`, `pause` | The tutorial asks for each; the bot uses all. |
| Statuses, bounties, leaks, ruins, downed heroes | Every night. |
| Determinism: digest, command-log replay, rerun to a step | Golden digest per night (§7). |
| Elevation as a visual and as picking input | Terraces and cliffs; picking tests on the upper terrace behind a cliff. |
| Obedience from trust drawn from the battle's own generator | Low trust: Corvin sometimes ignores "hold" until a scene fixes it. |

### 2.3 The view

| Engine feature | Where |
| --- | --- |
| Zoom bands (overview, tactical, standard, close) | The intro pans from overview to close; the finale's Maw is first seen in the overview band; the smoke test captures a frame per band. |
| Fit-to-revealed, zoom about the cursor, pan, clamp | Tutorial prompts; the Build phase. |
| Camera taken by a moment, then returned | Every moment eases to the character concerned. |
| Fog edge and reveal animation | Night 3 opening; Wren's Flare reveal on night 4. |
| Picking: entity first, then elevated tile | Placing on an upper terrace; selecting a hero in a crowd. |
| HUD: credits, wave bar, build palette with `because` reasons, hero panel, speed, minimap | Reasons such as "Not on a cliff", "You need 40 lamp-oil". |
| Moment overlay: a scene drawn over the dimmed battle | Every moment. |
| Cues: sound and effect per hit, death, leak, build, ability | All, de-duplicated per step. |

### 2.4 Around the engine

| Feature | Where |
| --- | --- |
| Localization | A French pack for kind names, hero names, HUD labels, hub text and every moment scene; language switch at the pause menu; `varis l10n status` complete. |
| `varis check` on battle data | Kind tables, wave and moment references, trigger arguments; negative fixtures in §6. |
| `varis battle` headless runner, bot, battle inspector | §7. |
| Existing story machinery | Decks, `require … because`, templates (`{#select}`, `{#plural}`), qualities with labels, `observe` toasts, scene input and menus, `procedure` + `effect` beats. |
| Scale | A hidden test-only `stress` setup (880 × 495 tiles, 10,000 enemies) for `varis battle` and an overview-band smoke frame. Not on the player's path. |

## 3. The four nights

Revealed sizes and counts are targets for the bot, not hard limits.

| | Night 1: Dusk | Night 2: Husks | Night 3: The second road | Night 4: Lanternfall |
| --- | --- | --- | --- | --- |
| New | Wren joins; Bolt, Chime | Hoar Lamp; husks (break structures) | Arc Lamp; wraiths; east source; Mill sink; fog grows to 80 × 45 | Beacon; the Maw; the valley is revealed |
| Enemies | about 30 dimlings, a few hounds | about 70 incl. husks | about 160 incl. wraiths | about 300 plus the Maw |
| Map | 48 × 27 | 64 × 36 | 80 × 45 | 96 × 54 |
| Silent judge | none (tutorial) | a raid on the thinnest wall; forecast `weak(east_wall)` if it is thin | raid; forecast of leaks at the Mill | raid on the Bellfrey; forecast of the Lantern's hp |
| Interrupting moments (cap 3; 4 on night 4) | 1 | 2 | 3 | 4 |
| Players learn | build, place, zoom, pause | repair, orders, trust matters | abilities, bonds, two fronts | everything, with consequences |

### 3.1 Timetable (target, normal speed)

| Part | Dusk | Build | Night | Dawn | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Prologue and intro (scene, overview → close) | 1:30 | | | | 1:30 |
| Night 1 | 0:20 | 0:30 | 1:10 | 0:30 | 2:30 |
| Night 2 | 0:35 | 0:30 | 1:30 | 0:40 | 3:15 |
| Night 3 | 0:35 | 0:35 | 2:00 | 0:45 | 3:55 |
| Night 4 | 0:25 | 0:30 | 2:30 | 1:00 | 4:25 |
| Ending scene | | | | 1:00 | 1:00 |
| **Total** | | | | | **about 16:35; about 14:30 with 2× in two battles** |

## 4. Heroes and relationships

Relationships are ordinary qualities and facts, which is what the engine plan's bridge reads.

| Hero | Role and ability | Trust 0–5 raised by | Battle effects (derived by rules) |
| --- | --- | --- | --- |
| **Ilse** | Lampwright; *Repair* (restores a structure's hp over a few steps) | Letting her choose placements; backing her over Corvin | Trust ≥ 2: obeys orders reliably; ≥ 4: *Ward* (a shield on the nearest tower); her repair rate rises with trust |
| **Corvin** | Retired captain; *Taunt* (pulls nearby enemies to him) | Honouring his road knowledge; protecting Wren | Trust ≥ 2: obeys; ≥ 4: *Rally* (an aura on towers near him); at trust 0–1 he sometimes holds instead of moving |
| **Wren** | Courier; *Flare* (burn in an area; reveals a radius) | Asking about the valley; covering her in a moment | Trust ≥ 3: Flare radius +1 and reveals; at hp below 40 % the moment of night 2 fires |
| Ilse–Corvin **bond** | | A scene in night 3 when they fight side by side | While both deployed within 3 hexes: +damage on towers near them |
| Wren–Corvin **bond** | | Night 2 choice to cover her | Corvin's taunt radius +1 near Wren |

Heroes carry `injured_until` and `dead` facts written only by `battle_result` (§5.3). An injured
hero is not deployed, is missing from the hub's conversation list and appears in the infirmary
scene; a dead hero's lines are replaced by a short remembrance and his or her bonds are removed.

## 5. Moments, sync and consequences

### 5.1 Moments (every trigger at least once)

| Night | Trigger | Scene (summary) | Choice and what it syncs (§5.2) |
| --- | --- | --- | --- |
| 1 | `wave_start(1)` | Corvin: "Watch the road." Wren runs in and joins. | None (teaching beat). |
| 2 | `enemy_kind_seen(husk)` | Ilse and Corvin disagree how to meet armour. | *Focus fire* (Corvin gets taunt, towers +damage) or *Let the lamps work* (global damage +, trust Ilse +1). |
| 2 | `hero_hp_below(wren, 40)` | Wren is cut off. | *Corvin, cover her* (orders: follow; trust Wren +1, Corvin −1) or *Hold the line* (global damage +). |
| 3 | `heroes_near(ilse, corvin, 3)` | They are forced to cooperate; the argument ends. | None; the bond is created by the sync. |
| 3 | `leak_count(5)` | Villagers on the Mill road. | *Call the militia* (reinforce: allied militia at the Mill tile) or *Order the Mill evacuated* (heal the Lantern, income −). |
| 3 | `step(1200)` | The east light fails; Ilse asks for a minute. | *Give her the minute* (heal structures near her) or *No time* (no change; her trust −1). |
| 4 | `wave_start(3)` | The Maw arrives; first seen in the overview band. | Camera pulls out; no choice. |
| 4 | `hero_downed(any)` | Who goes to the fallen? | The downed hero is healed (heal) at the cost of another's orders; or *Leave them* (damage to the hero; flags `left_behind`). |
| 4 | `structure_destroyed(bellfrey)` | The bell goes silent. | *Wren's Flare* (reveal the valley; burn the approach) or *Rally at the Lantern* (orders: all heroes retreat to the Lantern). |
| 4 | `leak_count(12)` (offered once) | The line breaks. | *Sound the retreat* (`end` with `withdrawn`) or *Stand* (global damage + and trust −1 for everyone). |
| 4 | `battle_won` | The valley clears. | None; result is applied after the scene. |
| 4 | `battle_lost` | The Lantern gutters. | None; leads to the defeat screen. |

The per-battle cap counts interruptions that can pause the battle; the closing `battle_won` and
`battle_lost` scenes do not count, and the cap is a setup field, raised to 4 for the finale.
Coverage: `step`, `wave_start`, `hero_hp_below`, `hero_downed`, `structure_destroyed`, `leak_count`,
`heroes_near`, `enemy_kind_seen`, `battle_won`, `battle_lost` — all ten triggers.

### 5.2 Modifiers (every entry at least once)

| Entry | Where it is used |
| --- | --- |
| `hero_mods` | Night 2 husk choice (Corvin's taunt), night 3 Ilse's minute |
| `bonds` | Night 3 Ilse–Corvin scene replaces the bond list |
| `global` | Several choices (damage, income) |
| `orders` | Night 2 cover, night 4 rally |
| `reinforce` | Night 3 militia |
| `heal` | Night 3 Ilse's minute, night 4 rescue, night 3 evacuation |
| `damage` | Night 4 "Leave them" |
| `reveal` | Night 4 Wren's Flare |
| `end` | Night 4 retreat |

### 5.3 What the result writes (the battle changes the VN world)

| Battle event | World change | Where the player sees it |
| --- | --- | --- |
| A structure is destroyed (Bellfrey, Mill, a gate, any tower) | A `ruin` fact at its tile; `morale` −; for the Bellfrey the hub background loses the bell | Hub backdrop; a "Rebuild" storylet with a cost; the dusk scene has no bell; Wren mourns |
| Leaks at the Mill sink | `food` − the leak count | Mill storylet and NPC lines change; income falls; a morale line |
| Hero downed | `injured_until = night + 1`, or `dead` if downed twice or left behind on night 4 | Infirmary scene; missing from the talk list; the hero panel greys out; an obituary line |
| Hero covered or ignored in a moment | Trust deltas | Next night's obedience, rally and ward; hub conversation ladder |
| A hero's kills and damage taken | A small trust or pride change | Aftermath scene wording (`{#plural}`, `{#select}`) |
| Collapsed bridge or cleared scree (map edit) | `terrain_edit` | The next night's route; the overlook scene shows the change; the map in the hub |
| Fog reveal (round growth and Flare) | `revealed(sector)` | A new hub place, the Valley Overlook; the map overlay |
| First sighting of a kind | `seen(kind)` | Journal and bestiary storylets unlock |
| Judge forecast `weak(east_wall)` | A forecast fact | Corvin's dusk line and, if the wall falls, "I told you" in the aftermath |
| Judge attrition | A tower's hp reduced before the night | A tower arrives damaged; Ilse comments when she repairs it |
| Decisions in moments | Flags (`evacuated_mill`, `held_the_line`, `left_behind`, `retreated`) | Ending selection and dialogue variants |

The world also changes the battle (§2.1): the relationships and flags above are read again at the
next setup. The "both directions" test of §7 asserts each row.

## 6. Endings

| Ending | Condition |
| --- | --- |
| **The Lantern keeps** | Night 4 won, nobody dead |
| **Kept, at a cost** | Won, one hero dead or the Bellfrey a ruin with morale low |
| **Withdrawal** | The retreat was sounded; the village survives but the Lantern is carried down |
| **Dimmed** | Lost; the player may retry from the battle's start or accept this ending |

Each ending has a variant line per hero depending on trust (three bands), so three playthroughs
that differ only in relationships read differently.

## 7. Testing

The sample is the engine's integration test; its tests are listed because they are the exit tests
of the engine stages.

| Test | What it proves |
| --- | --- |
| **Golden digests** | A scripted bot plays each night with fixed commands and moment choices; the battle digest equals the checked-in value on every supported OS. |
| **Determinism** | Each night twice, headless and then through the SDL smoke test: equal digests. A rerun to step N equals a run through step N. A command log replays to the same outcome. |
| **Branch coverage bot** | Enumerates the moment choices (a few dozen combinations) and plays every one: no stuck state, every ending reachable, every trigger and every modifier entry observed at least once (a coverage report prints the matrix of §5). |
| **Novice bot** | Builds nothing: loses night 2 or 3 with a retry offered; the retry restores the snapshot bytes exactly. |
| **Abandon and no-save** | Abandon in the build phase and inside a moment restores the world bytes and the session RNG; F5/F9 are refused with a reason in every battle phase; Continue after quitting mid-battle starts the battle again. |
| **Bridge validation** | Fixtures with an unknown kind, an off-map tile, a missing sink, a moment naming an unknown scene and a duplicate id each refuse to start, name the field, and leave the world byte-identical. |
| **Both directions** | For each row of §5.3 a test asserts the world fact after a scripted battle and, where there is one, the hub or scene text that depends on it; for relationships, that changing trust changes the derived setup. |
| **Judge** | The silent judge changes the world and shows nothing; the forecast variant stores a fact and changes no structure; both are deterministic. |
| **No allocation, bounded time** | The step runs under the counting allocator; the budgets of the engine plan §9 hold at the sample's scale and at the `stress` setup. |
| **Localization** | `varis l10n status` is complete for `fr`; a moment scene renders translated; the language switch inside a moment keeps its position. |
| **Checker** | `varis check` is clean; negative fixtures for each static battle check fail with source ranges. |
| **Smoke** | `VARIS_SMOKE_PLAY=battle` plays a scripted session including zooms through all four bands and one capture per band; the intro's overview-to-close pan has no frame over budget. |
| **Regression** | `sample-game`, `sample-rpg` and `sample-vn` golden suites are unchanged. |

## 8. Files

```
sample-td/
  project.lua  presentation.json  README.md
  world.lua  qualities.lua  game.lua  main.lua       (text host: `varis play`; runs the headless battle)
  content/    hub dusk heroes journal ruins endings
  scenes/     prologue moments_n1 moments_n2 moments_n3 moments_n4 dawn_n1..n4 endings
  battle/     kinds.lua waves.lua setup.lua sync.lua result.lua   (the four hooks and their data)
  locales/    fr.lua
  tests/      branches bot_golden abandon bridge both_directions judge l10n
  tools/      gen_assets.py  bot.lua  stress_setup.lua
  assets/     placeholders (SVG, synthesized WAV, polygon-drawn terrain)
```

Kept separate from the existing samples (D12); its own suite `sample-td` in `tests/manifest.toml`.
Kind tables and setup derivation follow the content tier: literal declarations, no helper
functions in content files.

## 9. Defaults and open items

| # | Item | Default used |
| --- | --- | --- |
| 1 | Title, setting and tone | *Lanternfall*, a terraced village; working title only |
| 2 | Judge semantics (engine plan §12, item 1) | Both variants appear: attrition applied silently and a forecast fact stored |
| 3 | A hero can die | Only through the §5.3 rules (downed twice, or left behind in night 4) |
| 4 | Enemies attack structures only when no path exists | As the engine plan's default |
| 5 | Elevation is visual only | Yes; one optional rule ("high ground +1 range") is behind a project switch and has its own test |
| 6 | Hit-scan projectiles with a cosmetic flight | Yes |
| 7 | Reusing the Hollowbrook town | No; a new, smaller setting |
| 8 | Art | Placeholder polygons and generated sprites; real art replaces a file by name |
| 9 | Mod hooks | None in this sample; the data tables are the modding surface |

## 10. Stages

Each stage lands when the engine stage it depends on has passed its exit test, so there is always
a slice that runs. Stage names SA–SH are this sample's; TD stages are the engine's.

| Stage | Needs | Deliverable | Exit test |
| --- | --- | --- | --- |
| **SA** ✅ | TD2 | Kind tables, waves, one map, the headless night 1 and 2 on the bot; golden digests | The bot and `bin/varis main.lua --bot` in place of `varis battle`; `tests/determinism.lua` |
| **SB** ✅ | TD3 | The four hooks; heroes and relationships as rules; moments for nights 1–2 as scenes; result rules (ruin, injury, trust); abandon and retry | `tests/bridge.lua`, `tests/both_directions.lua`, `tests/novice.lua`, the `GameHost` unit test |
| **SC** ✅ | TD4 | Build and night in the SDL view with placeholder polygons; moment overlay; HUD with reasons | `VARIS_SMOKE_PLAY=battle`: the window's night equals the headless digest (`tests/sample_game/sdl_test.py`) |
| **SD** ✅ | TD5 | All four nights; fog growth; two sources and sinks; the zoom bands used by the story (overview pan, Maw reveal) | One capture per band in the smoke; step budgets at the sample's scale and at 880 x 495 / 10,000 enemies in `test_battle.d` |
| **SE** ✅ | TD6 | The hub and dusk storylets, journal, ruins and rebuild, the silent judge and forecast, whole-game autosave points, endings | `tests/branches.lua`, `tests/novice.lua`, `tests/judge.lua` |
| **SF** ✅ | TD7 | Content depth within §3–§5: all ten primitives, every trigger and every modifier entry on the main path; the French pack; the conditional rules for death | `tests/branches.lua` asserts the matrix; `varis l10n status` shows 147 drafted, none untranslated |
| **SG** ◐ | | Art and audio placeholders from `gen_assets.py`, music and cues, text-size and layout checks at the three size classes | Placeholders and sound cues done; smoke runs at the regular size only |
| **SH** ✅ | TD8 | README, `docs/battle.md` examples taken from the sample, AGENTS §5/§6 rows, ROADMAP | `make test`, `make test-sdl`, the sample's check |

## 11. Risks

| Risk | Mitigation |
| --- | --- |
| The sample grows into a game (more nights, more heroes, more kinds) and the engine work waits on it | The coverage table (§2) is the scope; anything not in it is out. |
| Fifteen minutes of real time makes the tests slow | The bot plays at full speed with no rendering; the SDL smoke runs a short scripted session, not a whole game. |
| Moments make the battle feel like a cutscene reel | One or two on nights 1–2; the cap and the spacing rule from the engine plan; the bot counts them; the finale's fourth moment is a candidate to cut. |
| Relationship rules are hard to read | Every derived modifier has a name shown in the hero panel tooltip, from the same table the rule used. |
| Content is not stable until the engine contract is frozen (TD0) | SA starts only after TD2; earlier work is the outline above and placeholder data. |

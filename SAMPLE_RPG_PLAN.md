# Plan: *The Hollowbrook Summer*, a Twine-style RPG for the SDL3 player

Status (October 12, 2026): **plan approved, nothing implemented.** This document is a plan, not a
description of current behaviour; the manual in `docs/` remains the only definition of what the
language does. Update the status notes below as stages land.

Goal: a second complete sample game, `sample-rpg/`, that pushes the engine closer to a real
game: a town to explore, situations that raise stats, outcomes gated on those stats
(`strength > 50`), a character-creation opening, and a playable run of about 15 minutes that
does not repeat text. It is played in the SDL3 player (`varis-sdl`).

## 0. Decisions (owner, October 12, 2026)

| # | Decision |
| --- | --- |
| 1 | **Scene `effect` beat approved** (gap 1 below): scenes can run a registered named effect, so scene input and menu choices reach the world. |
| 2 | **`require {…} because "…"` approved** (gap 2, ROADMAP milestone 40 slice): choices that pass `when` but fail `require` are presented disabled, with a reason. |
| 3 | Name and location: `sample-rpg/`, working title *The Hollowbrook Summer*. |
| 4 | Fonts: rely on system fonts for now. Later, vendor an OFL font (for example Noto Sans) if wanted. |
| 5 | Include the **French translation pack**, to exercise the localization pipeline and language switching. |
| 6 | This plan is committed as `SAMPLE_RPG_PLAN.md`. |

## 1. Finding that shapes the work

The SDL3 player today drives scene-only games with an **empty world** and closes when the scene
ends (`docs/presentation.md`, `SceneHost`). It has no storylet hub screen, no stat panel and no
world-model save/load. Most of this plan is host and UI work; the game content comes second.

## 2. The game

**Premise.** You spend 10 days at your aunt's house in the river town of Hollowbrook before the
Midsummer Trials: three contests (Strength, Wits, Charm), with guild patronage as the prize. You
need an entry fee, trained stats and allies.

**Length.** 10 days × 3 slots = about 30 turns, plus about 2 minutes of creation and intro and 2
minutes of finale: 15–17 minutes, 2,500–3,500 words read per run. About 8,000–9,000 words are
authored so no run sees everything. Non-repetition comes from non-replacement decks and tiered
"training ladders" (3–4 distinct passages per skill).

### Character creation (`:creation` deck, stage attributes for the look)

| Step | Options | Effect |
| --- | --- | --- |
| Name | Free text (scene `input` beat, Unicode) | Stored in the world through the `effect` beat |
| Family | Farmers, merchants, scholars, dock folk, fallen gentry | Stat bumps, starting coins, a relationship fact, gate tags (merchant: market discount) |
| Temperament | Nerdy, athletic, charming, scrappy loner | +10 to a stat; an "interest" that opens different day-1 options |
| Quirks | Two of six (night owl, stubborn, animal friend, …) | Facts feeding derived rules such as `training_bonus` |
| Spare points | Spend 6 points in a loop | Bounded qualities; rollback on overspend |
| Look | Outfit × hair | Sprite attributes on the `player` character |
| Confirm | Accept or start over | Transactional reset |

### Stats, time, map

- Strength, Wits, Charm, Grit: 0–100; starting 20–60; training gives +2 to +6.
- Coins, Stamina (0–10), standing with 5 NPCs (−5 to 5). Time is `day` and `slot` with a custom
  `:day` period.
- Places (9): House, Square, Market, Forge, Archive, Tavern "Gilded Heron", Docks, Old Quarry,
  Festival Green (opens day 10). The Bridge to the quarry is broken until repaired.

### Situations (about 45 authored, about 30 seen per run)

- **House:** chores with Aunt Odile, read Dad's books, cook, sleep (ends the day).
- **Forge (Mara):** bellows, lift the anvil (`strength > 50`), mentorship, mend a lock.
- **Archive (Pell):** riddle chain; forbidden shelf (`wits ≥ 60` plus trust) holding a quarry map.
- **Market:** a daily 3-draw deck (pickpocket, haggling, lost child, rigged dice); shop items.
- **Tavern:** open mic (`charm ≥ 40`), arm-wrestling, evening-only rumours.
- **Docks:** unloading, fishing, three-route bridge repair (Wits + Strength; or Charm to recruit
  the town; or 15 coins).
- **Quarry:** wall climb (`strength ≥ 50`) for a cache; race against the rival Dane.
- **Square:** notice board, gossip circle, the stolen-banner mystery (`count(clues) ≥ 3`).
- **Cutscenes (scenes):** intro, meeting Mara, the rival, the Trials ceremony, 5 epilogues.

Gates besides `strength > 50`: `wits ≥ 45` with `strength ≥ 40`, `sum(standing) ≥ 8`,
`count(clues) ≥ 3`, `not has(item)`, `reachable(...)`, family and quirk tags. Endings key off
the best stat (`max`), trial results and allies.

## 3. Engine feature coverage

| Area | Used for |
| --- | --- |
| Relations | symbols and dynamic `logic.symbol`; facts from loops; recursion (`reachable`, `heard_of`); stratified negation (`isolated`); guards and comparisons; zero-arity relations (`night`, `festival_eve`) |
| Stateful | keyed relations; `set`/`delete`/`adjust`/`retract`; aggregates `count`/`sum`/`max`; transactions with `rollback` (shop, point-buy); local relations and rules; world blocks; `emptyworld`/inherited worlds for a forecast |
| Narrative | parameterized storylets and choices; priority, weight, cooldown, `repeatable`, `sticky`, `order`; decks with draw and no-replacement; push/pop/replace/reset; templates (`{#if query}`, variants, named variants, plural, select); qualities with bounds and labels; `require … because` |
| Time and events | pre and post actions; `once_per` `:turn`/`:game`/`:always`/`:day`; `emit`, `schedule`, `on`, `defer`; `observe` + `flush` for stat-up toasts |
| Scenes | say, narration, show, hide, background, audio (music, ambience, sfx), input, menu, jump, call, return, set, **effect**, transition, pause, ended; character attributes and slots |
| Persistence and tools | save/load with content version and program fingerprint; `explain`; `analyze`; replay log; `varis check`, `test`, `play`, `lsp`, workbench |
| Localization | French pack (`locales/fr`): storylet titles and texts, plural and select branches, character names, scene lines; language switch in the pause menu; `varis l10n` status/extract |

## 4. What the engine and host need

### A. Host work (no language change; the bulk)

1. **`GameHost`** in `source/varis/services/` (status-returning, like `SceneHost`): loads a
   project through the manifest hooks (`session`, `load`); presents storylets, scene beats and
   stage; exposes HUD data (visible qualities with labels and bounds); exposes an events-since
   stream; saves and restores through the authored world factory; never calls the engine from
   the render path.
2. **SDL bridge** (`tools/sdl/bridge.c`): several font sizes, a text-texture cache, mouse motion
   (hover), wheel, digit and F-keys, rect outlines, fullscreen toggle.
3. **Player screens** (`tools/sdl/main.d` split into modes):
   - Title: New / Continue / Settings / Quit.
   - Hub: top bar (place, day/slot, coins); stat bars; background and NPC sprites; bottom text
     panel with scroll; numbered choice list (1–9, mouse, arrows); disabled choices with reasons.
   - Toasts from `observe`.
   - Overlays: Journal (clues, quests, allies), Inventory, Character sheet, Map (click to
     travel using `reachable`), History.
   - Pause and settings: save/load slots, volume, text speed, language.
   - Ending screen with summary and play again.
4. **Manifest** (`presentation.json`): `project`, start mode, UI theme, icons, HUD layout. A
   manifest without `project` keeps today's behaviour.

### B. Language and runtime changes (approved)

| # | Change | Minimal form |
| --- | --- | --- |
| 1 | **Scene `effect` beat** | `{kind=:effect, name=:id, args={...}}` runs a registered named effect in its own transaction, with scalar locals or literals as arguments. Portable data; fingerprinted by structure; no yield; no RNG; included in format-3 saves; checked by `varis check`. Manual §6.11 updated in the same change. |
| 2 | **`require … because`** | A choice clause `require { goals } because "text"`. A choice that passes `when` but fails `require` is presented with `enabled=false`, a rendered reason and no usable token. The reason is a template (translatable, key `<storylet>.<choice>.because`). `narrative.explain` supplies the same diagnosis. Wording stays out of content identity; the `require` goals are structure and are in it. |

Both are language-level: each needs manual text, executable tests, checker coverage, a
`docs/coverage.md` entry, and confirmation that fingerprints and saves of existing content
(`sample-game`, `sample-vn`) are unchanged.

### C. Design conventions that need no change

- **Consequence text:** effects `emit(:say, narrative.template(...))`; the host shows these as
  a result block. Larger outcomes start a scene.
- **Backgrounds from storylets:** a tiny stage-only scene per place (background, show, return)
  played from the walk effect and auto-acknowledged. A `narrative.stage{}` effect operation is a
  possible later nicety, not part of this plan.
- **HUD numbers** come from the host reading qualities; narrative text uses threshold
  conditions (`{#if query …}`), not raw numbers.

## 5. File layout

```
sample-rpg/
  project.lua  presentation.json  README.md
  world.lua  qualities.lua  game.lua  main.lua     (text host for `varis play`)
  content/   decks creation town house forge archive market tavern docks quarry
             square gossip events trials endings
  scenes/    intro mara rival festival epilogues
  locales/   fr.lua
  tests/     story gating saveload replay norepeat l10n
  tools/     gen_assets.py  check.lua  bot.lua
  assets/    (stubs)
```

Kept separate from `sample-game/` (D12), which must keep passing. `sample-rpg` gets its own
suite in `tests/manifest.toml`.

## 6. Assets (all stubbed by `tools/gen_assets.py`; SVG and synthesized WAV, like `sample-vn`)

| Kind | Count | Stub |
| --- | --- | --- |
| Backgrounds 1280×720 | about 13 (9 places, night variants for house and square, title, ending cards) | Flat colour plus label |
| NPC sprites | 7 NPCs × 3 expressions | Coloured silhouette with name |
| Player sprite | outfit (3) × hair (3) × expression (2) | Same |
| Portraits | 8 characters × 3 expressions | Coloured square |
| UI | panel, button, bar frame, 8 icons (stats, coin, sun/moon), logo, cursor | Drawn with rects first; icon files optional |
| Music | title, day, evening, trial, ending (5 loops) | Synthesized tone |
| Ambience | market, river, forge (3) | Filtered noise |
| SFX | click, stat-up, coin, success, fail, door (6) | Short blips |
| Font | system fallback (Arial / DejaVu Sans) | Later: vendored OFL font such as Noto Sans; the French pack needs Latin-1 coverage only |

## 7. Stages

| Stage | Deliverable | Exit test |
| --- | --- | --- |
| **S0** | Design notes, manifest, schemas, map, qualities, asset stubs, content skeleton | `varis check` clean; text host boots |
| **S1** | `GameHost` and D unit tests | `make test`, including status returns and failed-load atomicity |
| **S2** | SDL screens and UI kit | `make test-sdl` smoke renders the hub; screenshot captured |
| **S3** | Language changes B1 and B2 (manual, checker, fingerprints, tests) | Regression and golden suites unchanged; sample-game check passes |
| **S4** | Creation plus the core loop (time, stamina, 3 places) | Author tests; playable slice |
| **S5** | Remaining places, events, rules, trials, endings | Bot reaches every ending; `analyze` finds no dead ends |
| **S6** | Audio, transitions, toasts, journal and map overlays, balance, French pack | No-repeat test; run length 12–18 minutes at reading pace; `varis l10n status` complete for `fr` |
| **S7** | Docs and integration | `make test`, `make bench-check`, sample-game check; `docs/presentation.md`, AGENTS §5/§6 and ROADMAP updated |

S3 may be pulled ahead of S2 if the host wants `enabled` and the effect beat from the start.

## 8. Conventions

- New D code follows AGENTS §3: return values, no new `throw`, little Phobos in runtime code.
  Tools and tests may use Phobos.
- Every new `.d` file has the licence header and is listed in the Makefile.
- Layers hold: the host lives in `services/`, the player in `tools/sdl/`.
- No change to `proto.code`, fingerprints of existing content, or the existing save formats
  without asking.
- Assets and wording stay out of content identity.
- UI inspection is read-only and consumes no random numbers.
- Commits are focused: engine changes with their tests, content separately.

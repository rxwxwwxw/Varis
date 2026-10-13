/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Data that crosses the bridge (TOWER_DEFENSE_PLAN.md §5.2, §5.3): the battle setup, moments,
/// commands, cues and the outcome. The simulation reads these and never reads Lua or relations.
/// Leaf module (plan B9).
module varis.game.types;

import varis.game.kinds;
import varis.game.terrain : TileEdit;

/// Moment triggers: the closed vocabulary of §5.3. `arg` is the step, the 1-based wave number,
/// the structure id, or the leak count, depending on the trigger.
enum Trigger : ubyte {
    step,
    waveStart,
    structureDestroyed,
    leakCount,
    battleWon,
    battleLost,
    /// any hero (arg 0) or the hero with id `arg` has been downed
    heroDowned,
    /// the hero with id `arg` is alive and below `arg2` percent of its hit points
    heroHpBelow,
    /// heroes `arg` and `arg2` are both alive and within `arg3` tiles of each other
    heroesNear,
    /// an enemy of kind `arg` (0-based) has spawned
    enemyKindSeen,
}

/// A point where the battle pauses and a named scene plays. `scene` is a scene id the host knows.
struct MomentSpec {
    int id;
    Trigger trigger;
    int arg;
    string scene;
    /// Fires at most once per battle; every moment in this version is once-only.
    bool once = true;
    /// hero_hp_below: the percentage; heroes_near: the second hero. Unused otherwise.
    int arg2;
    /// heroes_near: the distance in tiles.
    int arg3;
}

/// A tower placed at the start of the battle; its hit points come from its kind.
struct StructureSpec {
    int id;
    int kind;
    int q, r;
    /// Starting level (0 or 1 for the first) and hit points (0 for the kind's full hit points).
    int level;
    int hp;
}

/// A hero deployed for the battle. A hero fires like a tower of its kind, blocks its tile like a
/// structure, and is downed (not destroyed) at zero hit points. Heroes cannot be sold or upgraded.
struct HeroSpec {
    int id;
    /// The hero's weapon, an index into the setup's tower kinds.
    int kind;
    int q, r;
    int hp;
    /// Tower kind used by `use_ability` (repair, taunt, burn or shield); -1 for none.
    int ability = -1;
    /// Tower kind that works by itself (aura, shield or repair), derived from trust; -1 for none.
    int passive = -1;
    /// Percent chance (0..100) that a player's order is carried out.
    int obedience = 100;
}

/// Where enemies appear, and the sink they head for (an index into `BattleSetup.sinks`).
struct SourceSpec {
    int q, r;
    int sink;
}

/// `count` enemies of `kind` from `source`, one every `every` steps, the first at step `start`.
struct WaveSpec {
    int source;
    int kind;
    int count;
    int every;
    int start;
}

/// Everything a battle starts with. The arrays must outlive the battle.
struct BattleSetup {
    /// Seed for anything the battle draws; the host derives it from the session seed.
    ulong seed;
    int width, height;
    ulong mapSeed;
    const(TileEdit)[] edits;
    /// Fog sectors revealed at the start (indices, see `varis.game.fog`).
    int[] revealedSectors;
    /// Sinks as axial `[q, r]` pairs.
    int[2][] sinks;
    SourceSpec[] sources;
    StructureSpec[] structures;
    HeroSpec[] heroes;
    WaveSpec[] waves;
    MomentSpec[] moments;
    TowerKind[] towers;
    EnemyKind[] enemies;
    int credits;
    /// Wall and height parameters of the generated terrain (see `MapRegion`).
    int wallThreshold = 30;
    int terraceRows;
    /// First id given to structures placed during the battle; 0 for one past the highest id.
    int firstStructureId;
    /// Enemies blocked by a structure hit it every this many steps (1 hits every step).
    int attackEvery = 1;
    /// The battle is lost when this many enemies have reached a sink.
    int maxLeaks;
    /// At most this many non-closing moments fire in one battle (§5.3, R3).
    int momentCap;
    /// Structures that may be placed during the battle, beyond those in the setup.
    int structureRoom;
}

enum CommandKind : ubyte {
    place,
    sell,
    upgrade,
    /// Host-only: reveal a fog sector. Story and the round cadence use it; players do not.
    reveal,
    /// A player's order: hero `target` walks to `q`, `r`. May be ignored (see `HeroSpec.obedience`).
    moveHero,
    /// Hero `target` uses its active ability; `q`, `r` is the target tile where one is needed.
    useAbility,
    /// Restores structure `target` to full hit points for credits.
    repair,
    // The modifier commands below are what `battle_sync` produces (§5.4); each is logged so a
    // battle replays from its log. They carry integers in `a`..`d`.
    /// hero `target`: a = extra ability radius, b = percent damage, c = obedience points,
    /// d = percent ability power.
    heroMod,
    /// forget every bond, hero modifier and global modifier (a sync starts from here)
    bondsClear,
    /// bond of heroes `target` and `a`: b = distance in tiles, c = percent damage near them
    bondAdd,
    /// a = percent damage for every tower, b = percent bounty
    global,
    /// story order: hero `target`; a = 0 hold, 1 move to q, r, 2 follow hero b
    order,
    /// an allied structure of tower kind `towerKind` appears at or near q, r
    reinforce,
    /// a = 0 the Lantern (leaks reduced by c), 1 hero `target` +c, 2 structures within b of hero
    /// `target` +c, 3 structure `target` +c
    heal,
    /// hero `target` loses `a` hit points
    damage,
    /// the battle ends as withdrawn
    end,
    /// Host-only (the silent judge): structure `target` is left with `a` hit points.
    setHp,
}

/// A command. `stamp` is the step at which it was applied (set by `Battle.command`).
struct Command {
    CommandKind action;
    int stamp;
    /// place: the tower kind. Unused otherwise.
    int towerKind;
    int q, r;
    /// sell and upgrade: the structure id; reveal: the sector; hero commands: the hero id.
    int target;
    int a, b, c, d;
}

enum CueKind : ubyte {
    hit,
    death,
    leak,
    build,
    ruin,
    sell,
    upgrade,
    /// a hero was downed; a = hero id, b = its kind
    down,
    /// a hero ignored an order; a = hero id
    disobey,
    /// a structure was repaired; a = its id, b = hit points restored
    repaired,
    /// a shield was set on a unit; a = its id, b = shield size
    shielded,
    /// enemies were set alight; a = enemy count, b = source unit or enemy id
    burned,
    /// an enemy summoned another; a = summoner id, b = kind
    summoned,
    /// a hero taunted; a = hero id
    taunted,
    /// an ally appeared; a = id, b = kind
    reinforced,
    /// a sector was revealed by an ability; a = sector
    flare,
    /// the Lantern or a unit was healed; a = unit id or 0 for the Lantern, b = amount
    healed,
}

/// A presentation cue for audio and effects. `a` and `b` depend on the kind (see the simulation).
struct Cue {
    CueKind kind;
    int a, b;
}

enum Outcome : ubyte {
    running,
    won,
    lost,
    /// the story sounded the retreat (a modifier `end`)
    withdrawn,
}

/// What `Battle.step` reports: the battle went on, a moment paused it, or it ended.
enum StepResult : ubyte {
    running,
    moment,
    won,
    lost,
    withdrawn,
}

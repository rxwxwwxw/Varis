/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Kinds of towers and enemies (TOWER_DEFENSE_PLAN.md §6.3, TD2): plain structs filled from content
/// tables. An ability is one primitive from a closed set; a primitive the simulation does not
/// implement yet is refused by validation rather than ignored. Leaf module (plan B9).
module varis.game.kinds;

@nogc nothrow:

/// The ten ability primitives of §6.3. All ten are simulated (TD7 slice): the first four fire at
/// enemies; `burn` ignites; `aura`, `shield` and `repair` support friendly units; `taunt` and
/// `summon` change what enemies do.
enum Primitive : ubyte {
    singleTarget,
    splash,
    slow,
    chain,
    burn,
    aura,
    shield,
    summon,
    repair,
    taunt,
}

/// True for the primitives the simulation runs in this version (all of them).
bool isSimulated(Primitive primitive) {
    return primitive <= Primitive.taunt;
}

/// Primitives a hero may use as an active ability (`use_ability`).
bool isActiveAbility(Primitive primitive) {
    return primitive == Primitive.repair || primitive == Primitive.taunt
        || primitive == Primitive.burn || primitive == Primitive.shield;
}

/// Primitives that work by themselves as a passive of a tower or a hero.
bool isPassiveAbility(Primitive primitive) {
    return primitive == Primitive.aura || primitive == Primitive.shield || primitive == Primitive.repair;
}

/// A tower. Numbers are whole units: distances in tiles, times in steps, damage in hit points.
struct TowerKind {
    string name;
    int cost, range, damage, cooldown, hp;
    Primitive primitive;
    /// splash: radius around the target; chain: range of each jump (in tiles).
    int radius;
    /// slow: steps the slow lasts.
    int duration;
    /// chain: number of extra targets after the first.
    int jumps;
    /// burn: damage per step; aura: percent added to damage; shield: hit points of the shield;
    /// repair: hit points restored.
    int power;
    /// false for kinds only heroes and the story use (hero abilities, militia)
    bool buildable = true;
    /// burn used as a hero ability: reveals the fog sector under the target when non-zero.
    int reveal;
}

/// An enemy. `speed` is progress per step in 1/1024 of a tile, so 1024 is one tile per step.
struct EnemyKind {
    string name;
    int hp, speed, armour, bounty;
    /// Hit points taken per step by the structure this enemy is blocked by.
    int structureDamage;
    /// A shield that absorbs this much damage before hit points are lost.
    int shield;
    /// summon: the enemy kind produced (-1 for none), every `summonEvery` steps, `summonCap` times
    /// per summoner. A summoned kind may not summon.
    int summonKind = -1;
    int summonEvery, summonCap;
    /// burn: every `burnEvery` steps, structures and heroes within `burnRadius` tiles take
    /// `burnPower` damage.
    int burnRadius, burnPower, burnEvery;
}

/// Progress units per tile.
enum int tileProgress = 1024;

/// Highest level a structure can reach by upgrading.
enum int maxLevel = 3;

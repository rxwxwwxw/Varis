/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The battle simulation (TOWER_DEFENSE_PLAN.md §6, TD2): structure-of-arrays state, one fixed
/// step in a fixed order, player and host commands stamped with the step at which they apply,
/// moments that pause the loop, cues for the view, and a digest of the whole state.
///
/// Rules of this module: integers only; no clock, file, Lua or random source other than the
/// setup's seed (not drawn in this version); no iteration over unordered containers. Enemies
/// that die or leak are removed by compaction in index order, so the same setup and commands
/// always give the same state on every platform. Leaf module (plan B9).
///
/// Simplifications of this version, each recorded in TOWER_DEFENSE_PLAN.md §10 for TD7:
/// projectiles are hit-scan; a taunt pulls enemies by a greedy step rather than a field; heroes
/// walk by a breadth-first search recomputed each time they move.
module varis.game.battle;

import varis.game.fog;
import varis.game.hex;
import varis.game.kinds;
import varis.game.route;
import varis.game.terrain;
import varis.game.types;

/// Most targets a chain tower may hit in one shot (its first target plus jumps).
enum int maxChain = 8;
/// A hero walks one tile every this many steps.
enum int heroStepEvery = 4;
/// Tiles around a bonded hero that a bond's damage bonus reaches.
enum int bondRadius = 3;
/// Cues recorded in one step; more are counted in `cueDropped`.
enum int cueCapacity = 4096;

/// A refused setup or command: `field` names the entry (static text), `index` the array entry
/// (-1 when there is none), `message` says why. An empty message means success.
struct Problem {
    string field;
    int index = -1;
    string message;

    bool ok() const {
        return message.length == 0;
    }
}

struct Battle {
    BattleSetup setup;
    MapRegion map;
    Fog fog;
    int width, height, tiles;
    int sinkCount;
    int[] sinkTile, sourceTile;
    ubyte[] fogStorage;

    // terrain and routing (recomputed when structures or fog change)
    bool[] wall, revealed, routeOpen, routeThrough;
    int[] structureAt;
    int[] openParent, openDistance, throughParent, throughDistance;
    int[] scratchQueue;
    bool fieldsDirty;
    // scratch list of enemies found by `enemiesWithin`, sized to the enemy capacity
    int[] within;

    // structures: stable slots, never reused, so the digest and ids stay meaningful
    int structureCount;
    int[] sId, sKind, sTile, sHp, sLevel, sCooldown, sMaxHp;
    bool[] sAlive, sIsHero, sDowned, sSold;
    int nextStructureId;
    // support state: shields, the aura bonus of this step, heroes' abilities, orders and mods
    int[] sShield, sAura, sAbilityKind, sPassiveKind, sAbilityCd, sPassiveCd, sObedience;
    int[] sMoveTarget, sMoveCd, sFollow, sTauntUntil, sTauntRadius;
    int[] sModRadius, sModDamage, sModObedience, sModRate;
    // bonds and global modifiers (replaced by battle_sync)
    int bondCount;
    int[8] bondA, bondB, bondWithin, bondPct;
    int globalDamage, globalBounty;
    // the battle's generator: drawn only for orders that may be ignored
    ulong rngState;
    int rngDraws;
    // scratch for hero walking
    bool[] heroBlocked;
    int[] heroParent, heroDistance;
    bool[] kindSeen;

    // enemies: compacted in spawn order
    int enemyCount, nextEnemyId;
    int[] eId, eKind, eTile, eProgress, eHp, eSink, eSlow, eAttack;
    int[] eShield, eBurn, eBurnPower, eSummonCd, eSummoned, eBurnCd, eTaunt;
    bool[] eLeaked;
    // per-step buckets of enemies by tile, for tower targeting
    int[] bucketHead, bucketNext;
    uint[] bucketStamp;
    uint generation;

    // waves and moments
    int[] waveSpawned;
    bool[] waveStarted, momentFired;
    int momentsFired;
    int[] leaksPerSink;

    // progress
    int stepIndex, credits, leaks, kills, firedMoment = -1;
    Outcome outcome;
    Cue[] cues;
    int cueCount, cueDropped;
    /// Commands accepted so far, stamped with the step at which they were applied.
    Command[] log;

    /// Checks a setup without building anything. Empty result means the setup can start.
    static Problem validate(const BattleSetup s) {
        if (s.width <= 0 || s.height <= 0 || s.width > 1024 || s.height > 1024)
            return Problem("width, height", -1, "the map must be 1 to 1024 tiles on each side");
        if (s.credits < 0)
            return Problem("credits", -1, "credits cannot be negative");
        if (s.maxLeaks < 1)
            return Problem("maxLeaks", -1, "maxLeaks must be at least 1");
        if (s.momentCap < 0 || s.structureRoom < 0)
            return Problem("momentCap, structureRoom", -1, "caps cannot be negative");
        foreach (i, k; s.towers) {
            immutable fires = k.primitive <= Primitive.chain || (k.primitive == Primitive.burn && k.buildable);
            if (s.attackEvery < 1)
                return Problem("attackEvery", -1, "attackEvery must be at least 1");
            if (k.cost < 0 || k.range < 0 || k.hp < 1 || k.damage < 0 || k.cooldown < 1 || (fires && k.damage < 1))
                return Problem("towers", cast(int) i, "cost and range must be >= 0; hp and cooldown >= 1; damage >= 1 for a tower that fires");
            if (k.primitive == Primitive.summon)
                return Problem("towers.ability", cast(int) i, "summon is an enemy ability");
            if (k.primitive == Primitive.burn && (k.power < 1 || k.duration < 1))
                return Problem("towers.power", cast(int) i, "a burn tower needs power >= 1 and duration >= 1");
            if ((k.primitive == Primitive.aura || k.primitive == Primitive.shield || k.primitive == Primitive.repair)
                    && (k.power < 1 || k.radius < 1))
                return Problem("towers.power", cast(int) i, "aura, shield and repair need power >= 1 and radius >= 1");
            if (k.primitive == Primitive.taunt && (k.radius < 1 || k.duration < 1))
                return Problem("towers.radius", cast(int) i, "a taunt needs radius >= 1 and duration >= 1");
            if (k.primitive == Primitive.splash && k.radius < 1)
                return Problem("towers.radius", cast(int) i, "a splash tower needs radius >= 1");
            if (k.primitive == Primitive.slow && k.duration < 1)
                return Problem("towers.duration", cast(int) i, "a slow tower needs duration >= 1");
            if (k.primitive == Primitive.chain && (k.jumps < 1 || k.jumps >= maxChain || k.radius < 1))
                return Problem("towers.jumps", cast(int) i, "a chain tower needs 1 to 7 jumps and radius >= 1");
        }
        foreach (i, e; s.enemies)
            if (e.hp < 1 || e.speed < 1 || e.speed > tileProgress || e.armour < 0 || e.bounty < 0
                    || e.structureDamage < 0 || e.shield < 0)
                return Problem("enemies", cast(int) i, "hp >= 1, speed 1 to 1024, the other numbers >= 0");
        foreach (i, e; s.enemies) {
            if (e.summonKind >= 0) {
                if (e.summonKind >= s.enemies.length || s.enemies[e.summonKind].summonKind >= 0)
                    return Problem("enemies.summon", cast(int) i, "a summon names an enemy kind that does not itself summon");
                if (e.summonEvery < 1 || e.summonCap < 1)
                    return Problem("enemies.summon", cast(int) i, "a summoner needs summon_every >= 1 and summon_cap >= 1");
            }
            if (e.burnPower > 0 && (e.burnRadius < 1 || e.burnEvery < 1))
                return Problem("enemies.burn", cast(int) i, "a burning enemy needs burn_radius >= 1 and burn_every >= 1");
        }

        auto map = MapRegion(s.width, s.height, s.mapSeed, s.edits, s.wallThreshold, s.terraceRows);
        auto fogGrid = new ubyte[fogSectorCount(s.width, s.height)];
        Fog grid;
        grid.setup(s.width, s.height, fogGrid);
        foreach (sector; s.revealedSectors)
            if (sector < 0 || sector >= grid.sectorCount())
                return Problem("revealedSectors", -1, "sector index outside the map");
        foreach (sector; s.revealedSectors)
            grid.reveal(sector);

        if (s.sinks.length == 0)
            return Problem("sinks", -1, "a battle needs at least one sink");
        foreach (i, sink; s.sinks) {
            if (!map.inside(sink[0], sink[1]) || map.isWall(sink[0], sink[1]))
                return Problem("sinks", cast(int) i, "a sink must be an open tile inside the map");
            if (!grid.isRevealed(sink[0], sink[1]))
                return Problem("sinks", cast(int) i, "a sink must be on a revealed sector");
        }
        foreach (i, src; s.sources) {
            if (src.sink < 0 || src.sink >= s.sinks.length)
                return Problem("sources.sink", cast(int) i, "no such sink");
            if (!map.inside(src.q, src.r) || map.isWall(src.q, src.r) || !grid.isRevealed(src.q, src.r))
                return Problem("sources", cast(int) i, "a source must be an open, revealed tile inside the map");
        }
        foreach (i, w; s.waves) {
            if (w.source < 0 || w.source >= s.sources.length)
                return Problem("waves.source", cast(int) i, "no such source");
            if (w.kind < 0 || w.kind >= s.enemies.length)
                return Problem("waves.kind", cast(int) i, "no such enemy kind");
            if (w.count < 1 || w.every < 1 || w.start < 0)
                return Problem("waves", cast(int) i, "count and every must be >= 1; start >= 0");
        }
        foreach (i, st; s.structures) {
            if (st.kind < 0 || st.kind >= s.towers.length)
                return Problem("structures.kind", cast(int) i, "no such tower kind");
            if (!map.inside(st.q, st.r) || map.isWall(st.q, st.r) || !grid.isRevealed(st.q, st.r))
                return Problem("structures", cast(int) i, "a structure must be on an open, revealed tile");
            foreach (j; 0 .. i) {
                if (s.structures[j].id == st.id)
                    return Problem("structures.id", cast(int) i, "structure ids must be unique");
                if (s.structures[j].q == st.q && s.structures[j].r == st.r)
                    return Problem("structures", cast(int) i, "two structures on one tile");
            }
            foreach (src; s.sources)
                if (src.q == st.q && src.r == st.r)
                    return Problem("structures", cast(int) i, "a structure cannot stand on a source");
            foreach (sink; s.sinks)
                if (sink[0] == st.q && sink[1] == st.r)
                    return Problem("structures", cast(int) i, "a structure cannot stand on a sink");
        }
        foreach (i, h; s.heroes) {
            if (h.kind < 0 || h.kind >= s.towers.length)
                return Problem("heroes.kind", cast(int) i, "no such tower kind");
            if (h.hp < 1)
                return Problem("heroes.hp", cast(int) i, "a hero needs hp >= 1");
            if (h.obedience < 0 || h.obedience > 100)
                return Problem("heroes.obedience", cast(int) i, "obedience is a percentage from 0 to 100");
            if (h.ability >= cast(int) s.towers.length || (h.ability >= 0 && !isActiveAbility(
                    s.towers[h.ability].primitive)))
                return Problem("heroes.ability", cast(int) i, "an ability is a repair, taunt, burn or shield kind");
            if (h.passive >= cast(int) s.towers.length || (h.passive >= 0 && !isPassiveAbility(
                    s.towers[h.passive].primitive)))
                return Problem("heroes.passive", cast(int) i, "a passive is an aura, shield or repair kind");
            if (!map.inside(h.q, h.r) || map.isWall(h.q, h.r) || !grid.isRevealed(h.q, h.r))
                return Problem("heroes", cast(int) i, "a hero must stand on an open, revealed tile");
            foreach (st; s.structures) {
                if (st.id == h.id)
                    return Problem("heroes.id", cast(int) i, "a hero id must not repeat a structure id");
                if (st.q == h.q && st.r == h.r)
                    return Problem("heroes", cast(int) i, "a hero and a structure on one tile");
            }
            foreach (j; 0 .. i) {
                if (s.heroes[j].id == h.id)
                    return Problem("heroes.id", cast(int) i, "hero ids must be unique");
                if (s.heroes[j].q == h.q && s.heroes[j].r == h.r)
                    return Problem("heroes", cast(int) i, "two heroes on one tile");
            }
            foreach (src; s.sources)
                if (src.q == h.q && src.r == h.r)
                    return Problem("heroes", cast(int) i, "a hero cannot stand on a source");
            foreach (sink; s.sinks)
                if (sink[0] == h.q && sink[1] == h.r)
                    return Problem("heroes", cast(int) i, "a hero cannot stand on a sink");
        }
        foreach (i, m; s.moments) {
            if (m.scene.length == 0)
                return Problem("moments.scene", cast(int) i, "a moment needs a scene");
            foreach (j; 0 .. i)
                if (s.moments[j].id == m.id)
                    return Problem("moments.id", cast(int) i, "moment ids must be unique");
            final switch (m.trigger) {
            case Trigger.step:
                if (m.arg < 0)
                    return Problem("moments.arg", cast(int) i, "step(n) needs n >= 0");
                break;
            case Trigger.waveStart:
                if (m.arg < 1 || m.arg > s.waves.length)
                    return Problem("moments.arg", cast(int) i, "wave_start(n) needs a wave number 1 to the number of waves");
                break;
            case Trigger.structureDestroyed:
                bool known = false;
                foreach (st; s.structures)
                    known = known || st.id == m.arg;
                if (!known)
                    return Problem("moments.arg", cast(int) i, "structure_destroyed names no structure in the setup");
                break;
            case Trigger.leakCount:
                if (m.arg < 1)
                    return Problem("moments.arg", cast(int) i, "leak_count(n) needs n >= 1");
                break;
            case Trigger.heroDowned:
                if (m.arg != 0 && !heroKnown(s, m.arg))
                    return Problem("moments.arg", cast(int) i, "hero_downed names no hero in the setup");
                break;
            case Trigger.heroHpBelow:
                if (!heroKnown(s, m.arg))
                    return Problem("moments.arg", cast(int) i, "hero_hp_below names no hero in the setup");
                if (m.arg2 < 1 || m.arg2 > 100)
                    return Problem("moments.arg2", cast(int) i, "hero_hp_below takes a percentage from 1 to 100");
                break;
            case Trigger.heroesNear:
                if (!heroKnown(s, m.arg) || !heroKnown(s, m.arg2))
                    return Problem("moments.arg", cast(int) i, "heroes_near names a hero the setup does not contain");
                if (m.arg3 < 1)
                    return Problem("moments.arg3", cast(int) i, "heroes_near needs a distance of at least 1");
                break;
            case Trigger.enemyKindSeen:
                if (m.arg < 0 || m.arg >= s.enemies.length)
                    return Problem("moments.arg", cast(int) i, "enemy_kind_seen names no enemy kind");
                break;
            case Trigger.battleWon:
            case Trigger.battleLost:
                break;
            }
        }

        // every source must reach its sink over the walls and the revealed map
        auto blocked = new bool[s.width * s.height];
        foreach (t; 0 .. blocked.length) {
            immutable q = cast(int)(t % s.width), r = cast(int)(t / s.width);
            blocked[t] = map.isWall(q, r) || !grid.isRevealed(q, r);
        }
        auto parent = new int[blocked.length], distance = new int[blocked.length];
        auto queue = new int[blocked.length];
        foreach (i, src; s.sources) {
            immutable sink = s.sinks[src.sink];
            buildField(blocked, s.width, s.height, regionIndex(s.width, s.height, sink[0], sink[1]),
                    parent, distance, queue);
            immutable sourceIndex = regionIndex(s.width, s.height, src.q, src.r);
            if (distance[sourceIndex] == unreachable)
                return Problem("sources", cast(int) i, "this source cannot reach its sink");
        }
        return Problem.init;
    }

    /// Builds the battle from a valid setup. The arrays of `s` must outlive the battle. A refused
    /// setup returns its problem and leaves this battle unusable (do not call `step`).
    Problem begin(BattleSetup s) {
        immutable problem = validate(s);
        if (!problem.ok())
            return problem;
        setup = s;
        width = s.width;
        height = s.height;
        tiles = width * height;
        map = MapRegion(width, height, s.mapSeed, s.edits, s.wallThreshold, s.terraceRows);
        fogStorage = new ubyte[fogSectorCount(width, height)];
        fog.setup(width, height, fogStorage);
        foreach (sector; s.revealedSectors)
            fog.reveal(sector);

        wall = new bool[tiles];
        revealed = new bool[tiles];
        routeOpen = new bool[tiles];
        routeThrough = new bool[tiles];
        structureAt = new int[tiles];
        foreach (t; 0 .. tiles)
            wall[t] = map.isWall(t % width, t / width);

        sinkCount = cast(int) s.sinks.length;
        sinkTile = new int[sinkCount];
        foreach (i; 0 .. sinkCount)
            sinkTile[i] = regionIndex(width, height, s.sinks[i][0], s.sinks[i][1]);
        sourceTile = new int[s.sources.length];
        foreach (i, src; s.sources)
            sourceTile[i] = regionIndex(width, height, src.q, src.r);
        openParent = new int[sinkCount * tiles];
        openDistance = new int[sinkCount * tiles];
        throughParent = new int[sinkCount * tiles];
        throughDistance = new int[sinkCount * tiles];
        scratchQueue = new int[tiles];

        immutable unitCapacity = cast(int)(s.structures.length + s.heroes.length) + s.structureRoom;
        sId = new int[unitCapacity];
        sKind = new int[unitCapacity];
        sTile = new int[unitCapacity];
        sHp = new int[unitCapacity];
        sMaxHp = new int[unitCapacity];
        sLevel = new int[unitCapacity];
        sCooldown = new int[unitCapacity];
        sAlive = new bool[unitCapacity];
        sIsHero = new bool[unitCapacity];
        sDowned = new bool[unitCapacity];
        sSold = new bool[unitCapacity];
        sShield = new int[unitCapacity];
        sAura = new int[unitCapacity];
        sAbilityKind = new int[unitCapacity];
        sPassiveKind = new int[unitCapacity];
        sAbilityCd = new int[unitCapacity];
        sPassiveCd = new int[unitCapacity];
        sObedience = new int[unitCapacity];
        sMoveTarget = new int[unitCapacity];
        sMoveCd = new int[unitCapacity];
        sFollow = new int[unitCapacity];
        sTauntUntil = new int[unitCapacity];
        sTauntRadius = new int[unitCapacity];
        sModRadius = new int[unitCapacity];
        sModDamage = new int[unitCapacity];
        sModObedience = new int[unitCapacity];
        sModRate = new int[unitCapacity];
        foreach (st; s.structures) {
            immutable slot = structureCount;
            addUnit(st.id, st.kind, st.q, st.r, s.towers[st.kind].hp, false);
            if (st.level > 1)
                sLevel[slot] = st.level > maxLevel ? maxLevel : st.level;
            if (st.hp > 0)
                sHp[slot] = st.hp < sMaxHp[slot] ? st.hp : sMaxHp[slot];
        }
        if (s.firstStructureId > nextStructureId)
            nextStructureId = s.firstStructureId;
        foreach (h; s.heroes) {
            immutable slot = structureCount;
            addUnit(h.id, h.kind, h.q, h.r, h.hp, true);
            sAbilityKind[slot] = h.ability;
            sPassiveKind[slot] = h.passive;
            sObedience[slot] = h.obedience;
        }
        heroBlocked = new bool[tiles];
        heroParent = new int[tiles];
        heroDistance = new int[tiles];
        kindSeen = new bool[s.enemies.length];
        rngState = s.seed ^ 0xA5A5_5A5A_1234_4321UL;

        int enemyCapacity = 0;
        foreach (w; s.waves) {
            enemyCapacity += w.count;
            immutable summons = s.enemies[w.kind].summonKind >= 0;
            if (summons)
                enemyCapacity += w.count * s.enemies[w.kind].summonCap;
        }
        eId = new int[enemyCapacity];
        eKind = new int[enemyCapacity];
        eTile = new int[enemyCapacity];
        eProgress = new int[enemyCapacity];
        eHp = new int[enemyCapacity];
        eSink = new int[enemyCapacity];
        eSlow = new int[enemyCapacity];
        eAttack = new int[enemyCapacity];
        eLeaked = new bool[enemyCapacity];
        eShield = new int[enemyCapacity];
        eBurn = new int[enemyCapacity];
        eBurnPower = new int[enemyCapacity];
        eSummonCd = new int[enemyCapacity];
        eSummoned = new int[enemyCapacity];
        eBurnCd = new int[enemyCapacity];
        eTaunt = new int[enemyCapacity];
        bucketNext = new int[enemyCapacity];
        within = new int[enemyCapacity];
        bucketHead = new int[tiles];
        bucketStamp = new uint[tiles];

        waveSpawned = new int[s.waves.length];
        waveStarted = new bool[s.waves.length];
        momentFired = new bool[s.moments.length];
        leaksPerSink = new int[sinkCount];
        credits = s.credits;
        cues = new Cue[cueCapacity];
        refreshFields();
        return Problem.init;
    }

    private void addUnit(int id, int kind, int q, int r, int hp, bool hero) {
        immutable slot = structureCount++;
        sId[slot] = id;
        sKind[slot] = kind;
        sTile[slot] = regionIndex(width, height, q, r);
        sHp[slot] = hp;
        sMaxHp[slot] = hp;
        sLevel[slot] = 1;
        sAlive[slot] = true;
        sIsHero[slot] = hero;
        sAbilityKind[slot] = -1;
        sPassiveKind[slot] = -1;
        sObedience[slot] = 100;
        sMoveTarget[slot] = -1;
        structureAt[sTile[slot]] = slot + 1;
        // hero ids live in their own range; they must not push structure ids upward
        if (!hero && id >= nextStructureId)
            nextStructureId = id + 1;
    }

    private static bool heroKnown(const BattleSetup s, int id) {
        foreach (h; s.heroes)
            if (h.id == id)
                return true;
        return false;
    }

    /// Recomputes the two flow fields of every sink. Called when structures or fog change.
    void refreshFields() {
        foreach (t; 0 .. tiles) {
            revealed[t] = fog.isRevealed(t % width, t / width);
            routeThrough[t] = wall[t] || !revealed[t];
            routeOpen[t] = routeThrough[t] || structureAt[t] != 0;
        }
        foreach (sink; 0 .. sinkCount) {
            immutable base = sink * tiles;
            buildField(routeOpen, width, height, sinkTile[sink],
                    openParent[base .. base + tiles], openDistance[base .. base + tiles], scratchQueue);
            buildField(routeThrough, width, height, sinkTile[sink],
                    throughParent[base .. base + tiles], throughDistance[base .. base + tiles], scratchQueue);
        }
        fieldsDirty = false;
    }

    /// Applies a command now, stamped with the current step. Returns false with the reason in
    /// `refusal` when the command cannot apply; a refused command changes nothing and is not logged.
    bool command(Command c, out string refusal) {
        c.stamp = stepIndex;
        if (outcome != Outcome.running) {
            refusal = "the battle has ended";
            return false;
        }
        bool accepted;
        final switch (c.action) {
        case CommandKind.place:
            accepted = place(c, refusal);
            break;
        case CommandKind.sell:
            accepted = sell(c, refusal);
            break;
        case CommandKind.upgrade:
            accepted = upgrade(c, refusal);
            break;
        case CommandKind.reveal:
            if (c.target < 0 || c.target >= fog.sectorCount())
                refusal = "no such sector";
            else if (!fog.reveal(c.target))
                refusal = "that sector is already revealed";
            else {
                fieldsDirty = true;
                accepted = true;
            }
            break;
        case CommandKind.moveHero:
            accepted = moveHero(c, refusal);
            break;
        case CommandKind.useAbility:
            accepted = useAbility(c, refusal);
            break;
        case CommandKind.repair:
            accepted = repairStructure(c, refusal);
            break;
        case CommandKind.heroMod:
            accepted = modHero(c, refusal);
            break;
        case CommandKind.bondsClear:
            bondCount = 0;
            globalDamage = 0;
            globalBounty = 0;
            foreach (s; 0 .. structureCount) {
                sModRadius[s] = 0;
                sModDamage[s] = 0;
                sModObedience[s] = 0;
                sModRate[s] = 0;
            }
            accepted = true;
            break;
        case CommandKind.setHp:
            accepted = setHp(c, refusal);
            break;
        case CommandKind.bondAdd:
            accepted = addBond(c, refusal);
            break;
        case CommandKind.global:
            globalDamage = c.a;
            globalBounty = c.b;
            accepted = true;
            break;
        case CommandKind.order:
            accepted = orderHero(c, refusal);
            break;
        case CommandKind.reinforce:
            accepted = reinforce(c, refusal);
            break;
        case CommandKind.heal:
            accepted = heal(c, refusal);
            break;
        case CommandKind.damage:
            accepted = damageHero(c, refusal);
            break;
        case CommandKind.end:
            outcome = Outcome.withdrawn;
            accepted = true;
            break;
        }
        if (accepted)
            log ~= c;
        return accepted;
    }

    /// Advances one step (or reports the outcome again when the battle has ended). A moment
    /// pauses the battle: the host plays it, then calls `step` again.
    StepResult step() {
        if (outcome == Outcome.running) {
            if (fieldsDirty)
                refreshFields();
            cueCount = 0;
            cueDropped = 0;
            spawnWaves();
            enemyAbilities();
            auraPhase();
            moveHeroes();
            moveEnemies();
            fireTowers();
            supportPhase();
            burnTicks();
            attackStructures();
            removeDead();
            ++stepIndex;
            if (leaks >= setup.maxLeaks)
                outcome = Outcome.lost;
            else if (allWavesSpawned() && enemyCount == 0)
                outcome = Outcome.won;
        }
        return evaluateMoments();
    }

    /// Hash of the enumerated state: step, economy, structures, enemies, waves, moments and fog.
    /// Equal digests mean equal battles. Padding and array capacity do not enter the hash.
    ulong digest() const {
        ulong h = 14_695_981_039_346_656_037UL;
        h = hashAdd(h, stepIndex);
        h = hashAdd(h, credits);
        h = hashAdd(h, leaks);
        h = hashAdd(h, kills);
        h = hashAdd(h, cast(int) outcome);
        h = hashAdd(h, nextStructureId);
        h = hashAdd(h, nextEnemyId);
        foreach (s; 0 .. structureCount) {
            h = hashAdd(h, sId[s]);
            h = hashAdd(h, sKind[s]);
            h = hashAdd(h, sTile[s]);
            h = hashAdd(h, sHp[s]);
            h = hashAdd(h, sLevel[s]);
            h = hashAdd(h, sCooldown[s]);
            h = hashAdd(h, sAlive[s] ? 1 : 0);
            // hashed only when set, so a battle without downed heroes keeps its digest
            if (sDowned[s])
                h = hashAdd(h, 1);
        }
        foreach (e; 0 .. enemyCount) {
            h = hashAdd(h, eId[e]);
            h = hashAdd(h, eKind[e]);
            h = hashAdd(h, eTile[e]);
            h = hashAdd(h, eProgress[e]);
            h = hashAdd(h, eHp[e]);
            h = hashAdd(h, eSink[e]);
            h = hashAdd(h, eSlow[e]);
            h = hashAdd(h, eAttack[e]);
            h = hashAdd(h, eLeaked[e] ? 1 : 0);
        }
        // support state is hashed only where it is set, so a battle that does not use it keeps
        // the digest it had before these features existed
        foreach (s; 0 .. structureCount) {
            if (sShield[s] != 0)
                h = hashAdd(h, 1_000_000L + s * 4 + sShield[s] * 1000);
            if (sMoveTarget[s] >= 0 || sFollow[s] != 0)
                h = hashAdd(h, 2_000_000L + s * 4 + sMoveTarget[s] * 7 + sFollow[s]);
            if (sAbilityCd[s] != 0 || sPassiveCd[s] != 0)
                h = hashAdd(h, 3_000_000L + s * 4 + sAbilityCd[s] * 31 + sPassiveCd[s]);
            if (sTauntUntil[s] != 0)
                h = hashAdd(h, 4_000_000L + s * 4 + sTauntUntil[s]);
            if (sModRadius[s] != 0 || sModDamage[s] != 0 || sModObedience[s] != 0 || sModRate[s] != 0)
                h = hashAdd(h, 5_000_000L + s * 4 + sModRadius[s] * 3 + sModDamage[s] * 5 + sModObedience[s] * 7 + sModRate[s] * 11);
        }
        foreach (e; 0 .. enemyCount) {
            if (eShield[e] != 0 || eBurn[e] != 0 || eSummonCd[e] != 0 || eSummoned[e] != 0 || eBurnCd[e] != 0)
                h = hashAdd(h, 6_000_000L + e * 4 + eShield[e] * 3 + eBurn[e] * 5 + eBurnPower[e] * 13
                        + eSummonCd[e] * 17 + eSummoned[e] * 19 + eBurnCd[e] * 23);
        }
        if (rngDraws != 0) {
            h = hashAdd(h, cast(long) rngState);
            h = hashAdd(h, rngDraws);
        }
        foreach (b; 0 .. bondCount)
            h = hashAdd(h, 7_000_000L + bondA[b] * 31 + bondB[b] * 37 + bondWithin[b] * 41 + bondPct[b]);
        if (globalDamage != 0 || globalBounty != 0)
            h = hashAdd(h, 8_000_000L + globalDamage * 3 + globalBounty);
        foreach (w; 0 .. waveSpawned.length) {
            h = hashAdd(h, waveSpawned[w]);
            h = hashAdd(h, waveStarted[w] ? 1 : 0);
        }
        foreach (m; 0 .. momentFired.length)
            h = hashAdd(h, momentFired[m] ? 1 : 0);
        foreach (sink; 0 .. sinkCount)
            h = hashAdd(h, leaksPerSink[sink]);
        foreach (sector; 0 .. fog.sectorCount())
            h = hashAdd(h, fog.revealed[sector]);
        return h;
    }

    /// The cues of the last step, for audio and effects.
    const(Cue)[] lastCues() const {
        return cues[0 .. cueCount];
    }

    /// Number of enemies alive now.
    int enemiesAlive() const {
        return enemyCount;
    }

    /// The field distance (in steps) of enemy `e` to its sink, or `unreachable`.
    int enemyDistance(int e) const {
        immutable at = eSink[e] * tiles + eTile[e];
        if (openDistance[at] != unreachable)
            return openDistance[at];
        return throughDistance[at];
    }

    private void spawnWaves() {
        foreach (w, wave; setup.waves) {
            if (waveSpawned[w] >= wave.count || stepIndex < wave.start)
                continue;
            if ((stepIndex - wave.start) % wave.every != 0)
                continue;
            immutable src = wave.source;
            immutable slot = enemyCount++;
            eId[slot] = nextEnemyId++;
            eKind[slot] = wave.kind;
            eTile[slot] = sourceTile[src];
            eProgress[slot] = 0;
            eHp[slot] = setup.enemies[wave.kind].hp;
            eSink[slot] = setup.sources[src].sink;
            eSlow[slot] = 0;
            eAttack[slot] = -1;
            eLeaked[slot] = false;
            initEnemySupport(slot, wave.kind);
            kindSeen[wave.kind] = true;
            ++waveSpawned[w];
            waveStarted[w] = true;
        }
    }

    private void initEnemySupport(int slot, int kind) {
        immutable k = setup.enemies[kind];
        eShield[slot] = k.shield;
        eBurn[slot] = 0;
        eBurnPower[slot] = 0;
        eSummonCd[slot] = k.summonKind >= 0 ? k.summonEvery : 0;
        eSummoned[slot] = 0;
        eBurnCd[slot] = k.burnPower > 0 ? k.burnEvery : 0;
        eTaunt[slot] = -1;
    }

    private void moveEnemies() {
        foreach (e; 0 .. enemyCount) {
            if (eHp[e] <= 0)
                continue;
            int speed = setup.enemies[eKind[e]].speed;
            if (eSlow[e] > 0) {
                speed = speed / 2 > 0 ? speed / 2 : 1;
                --eSlow[e];
            }
            if (eAttack[e] >= 0) {
                if (sAlive[eAttack[e]])
                    continue;
                eAttack[e] = -1;
            }
            // an enemy next to a hero fights it
            {
                immutable q0 = eTile[e] % width, r0 = eTile[e] / width;
                foreach (step; neighbourOffsets) {
                    immutable idx = regionIndex(width, height, q0 + step[0], r0 + step[1]);
                    if (idx < 0)
                        continue;
                    immutable occupant = structureAt[idx];
                    if (occupant != 0 && sIsHero[occupant - 1] && sAlive[occupant - 1]) {
                        eAttack[e] = occupant - 1;
                        eProgress[e] = 0;
                        break;
                    }
                }
                if (eAttack[e] >= 0)
                    continue;
            }
            eProgress[e] += speed;
            if (eProgress[e] < tileProgress)
                continue;
            eProgress[e] -= tileProgress;
            immutable at = eSink[e] * tiles + eTile[e];
            immutable sinkAt = sinkTile[eSink[e]];
            immutable pulled = tauntStep(e);
            if (pulled == -2)
                continue;
            if (pulled >= 0) {
                eTile[e] = pulled;
                continue;
            }
            if (eTile[e] == sinkAt) {
                leak(e);
                continue;
            }
            immutable next = openDistance[at] != unreachable ? openParent[at] : throughParent[at];
            if (next < 0) {
                leak(e);
                continue;
            }
            if (structureAt[next] != 0) {
                eAttack[e] = structureAt[next] - 1;
                eProgress[e] = 0;
                continue;
            }
            eTile[e] = next;
        }
    }

    private void leak(int e) {
        eHp[e] = 0;
        eLeaked[e] = true;
    }

    private void fireTowers() {
        ++generation;
        foreach (e; 0 .. enemyCount) {
            if (eHp[e] <= 0)
                continue;
            immutable t = eTile[e];
            if (bucketStamp[t] != generation) {
                bucketStamp[t] = generation;
                bucketHead[t] = -1;
            }
            bucketNext[e] = bucketHead[t];
            bucketHead[t] = e;
        }
        foreach (s; 0 .. structureCount) {
            if (!sAlive[s])
                continue;
            if (sCooldown[s] > 0) {
                --sCooldown[s];
                continue;
            }
            immutable kind = setup.towers[sKind[s]];
            // support kinds act in `supportPhase` and `auraPhase`; a taunt is only ever ordered
            if (kind.primitive == Primitive.aura || kind.primitive == Primitive.taunt
                    || kind.primitive == Primitive.shield || kind.primitive == Primitive.repair
                    || kind.primitive == Primitive.summon)
                continue;
            immutable target = nearestEnemy(sTile[s], kind.range);
            if (target < 0)
                continue;
            immutable pct = 100 + 50 * (sLevel[s] - 1) + sAura[s] + globalDamage + sModDamage[s];
            immutable damage = kind.damage * pct / 100;
            final switch (kind.primitive) {
            case Primitive.singleTarget:
                hit(s, target, damage);
                break;
            case Primitive.splash: {
                    immutable centre = eTile[target];
                    hit(s, target, damage);
                    foreach (other; enemiesWithin(centre, kind.radius))
                        if (other != target)
                            hit(s, other, damage);
                    break;
                }
            case Primitive.slow:
                hit(s, target, damage);
                if (eHp[target] > 0 && eSlow[target] < kind.duration)
                    eSlow[target] = kind.duration;
                break;
            case Primitive.chain:
                chainFrom(s, target, kind, damage);
                break;
            case Primitive.burn:
                hit(s, target, damage);
                ignite(target, kind.power, kind.duration);
                break;
            case Primitive.aura:
            case Primitive.shield:
            case Primitive.summon:
            case Primitive.repair:
            case Primitive.taunt:
                break;
            }
            sCooldown[s] = kind.cooldown - 1;
        }
    }

    private void ignite(int e, int power, int duration) {
        if (eHp[e] <= 0)
            return;
        if (eBurn[e] < duration)
            eBurn[e] = duration;
        if (eBurnPower[e] < power)
            eBurnPower[e] = power;
    }

    private int tileDistance(int a, int b) const {
        return hexDistance(a % width, a / width, b % width, b / width);
    }

    /// Damage on every enemy that is burning.
    private void burnTicks() {
        foreach (e; 0 .. enemyCount) {
            if (eBurn[e] <= 0 || eHp[e] <= 0)
                continue;
            eHp[e] -= eBurnPower[e];
            --eBurn[e];
            if (eBurn[e] == 0)
                eBurnPower[e] = 0;
        }
    }

    /// Resets and recomputes the percent damage bonus of every unit: auras, then bonds.
    private void auraPhase() {
        foreach (s; 0 .. structureCount)
            sAura[s] = 0;
        foreach (s; 0 .. structureCount) {
            if (!sAlive[s])
                continue;
            applyAura(s, sKind[s]);
            if (sPassiveKind[s] >= 0)
                applyAura(s, sPassiveKind[s]);
        }
        foreach (b; 0 .. bondCount) {
            immutable a = slotOf(bondA[b]), c = slotOf(bondB[b]);
            if (a < 0 || c < 0 || !sAlive[a] || !sAlive[c])
                continue;
            if (tileDistance(sTile[a], sTile[c]) > bondWithin[b])
                continue;
            foreach (t; 0 .. structureCount) {
                if (!sAlive[t] || sIsHero[t])
                    continue;
                if (tileDistance(sTile[t], sTile[a]) <= bondRadius || tileDistance(sTile[t], sTile[c]) <= bondRadius)
                    sAura[t] += bondPct[b];
            }
        }
        foreach (s; 0 .. structureCount)
            if (sAura[s] > 100)
                sAura[s] = 100;
    }

    private void applyAura(int owner, int kindIndex) {
        immutable kind = setup.towers[kindIndex];
        if (kind.primitive != Primitive.aura)
            return;
        foreach (t; 0 .. structureCount) {
            if (t == owner || !sAlive[t])
                continue;
            if (tileDistance(sTile[owner], sTile[t]) <= kind.radius)
                sAura[t] += kind.power;
        }
    }

    /// Shield and repair kinds (towers and hero passives), and the cooldown of hero abilities.
    private void supportPhase() {
        foreach (s; 0 .. structureCount) {
            if (!sAlive[s])
                continue;
            if (sAbilityCd[s] > 0)
                --sAbilityCd[s];
            immutable main = setup.towers[sKind[s]];
            if ((main.primitive == Primitive.shield || main.primitive == Primitive.repair) && sCooldown[s] == 0) {
                if (supportAct(s, main, main.radius))
                    sCooldown[s] = main.cooldown;
            }
            if (sPassiveKind[s] >= 0) {
                if (sPassiveCd[s] > 0) {
                    --sPassiveCd[s];
                } else {
                    immutable passive = setup.towers[sPassiveKind[s]];
                    if (passive.primitive != Primitive.aura && supportAct(s, passive, passive.radius))
                        sPassiveCd[s] = passive.cooldown;
                }
            }
        }
    }

    /// A shield or a repair on the friendly unit within `radius` of `owner` that needs it most.
    /// Returns false when there was nobody to help.
    private bool supportAct(int owner, const TowerKind kind, int radius) {
        immutable rate = 100 + sModRate[owner];
        int best = -1;
        foreach (t; 0 .. structureCount) {
            if (!sAlive[t] || tileDistance(sTile[owner], sTile[t]) > radius)
                continue;
            if (kind.primitive == Primitive.shield && sShield[t] >= kind.power * rate / 100)
                continue;
            if (kind.primitive == Primitive.repair && sHp[t] >= sMaxHp[t])
                continue;
            if (best < 0 || sHp[t] * sMaxHp[best] < sHp[best] * sMaxHp[t])
                best = t;
        }
        if (best < 0)
            return false;
        if (kind.primitive == Primitive.shield) {
            sShield[best] = kind.power * rate / 100;
            cue(CueKind.shielded, sId[best], sShield[best]);
        } else {
            immutable before = sHp[best];
            sHp[best] += kind.power * rate / 100;
            if (sHp[best] > sMaxHp[best])
                sHp[best] = sMaxHp[best];
            cue(CueKind.repaired, sId[best], sHp[best] - before);
        }
        return true;
    }

    /// Heroes walk toward their order, one tile every `heroStepEvery` steps.
    private void moveHeroes() {
        foreach (s; 0 .. structureCount) {
            if (!sAlive[s] || !sIsHero[s])
                continue;
            int target = sMoveTarget[s];
            bool following = false;
            if (sFollow[s] != 0) {
                immutable f = slotOf(sFollow[s]);
                if (f >= 0 && sAlive[f]) {
                    target = sTile[f];
                    following = true;
                } else {
                    sFollow[s] = 0;
                }
            }
            if (target < 0 || target == sTile[s])
                continue;
            if (following && tileDistance(sTile[s], target) <= 1)
                continue;
            if (sMoveCd[s] > 0) {
                --sMoveCd[s];
                continue;
            }
            sMoveCd[s] = heroStepEvery - 1;
            heroBlocked[] = routeOpen[];
            heroBlocked[sTile[s]] = false;
            buildField(heroBlocked, width, height, target, heroParent, heroDistance, scratchQueue);
            if (heroDistance[sTile[s]] == unreachable) {
                sMoveTarget[s] = -1;
                continue;
            }
            immutable next = heroParent[sTile[s]];
            if (next < 0 || structureAt[next] != 0)
                continue;
            bool occupied = false;
            foreach (e; 0 .. enemyCount)
                if (eHp[e] > 0 && eTile[e] == next) {
                    occupied = true;
                    break;
                }
            if (occupied)
                continue;
            structureAt[sTile[s]] = 0;
            sTile[s] = next;
            structureAt[next] = s + 1;
            fieldsDirty = true;
            if (next == sMoveTarget[s] && !following)
                sMoveTarget[s] = -1;
        }
    }

    /// Enemies that summon or burn do so on their own clock.
    private void enemyAbilities() {
        immutable count = enemyCount;
        foreach (e; 0 .. count) {
            if (eHp[e] <= 0)
                continue;
            immutable kind = setup.enemies[eKind[e]];
            if (kind.summonKind >= 0 && eSummoned[e] < kind.summonCap) {
                if (--eSummonCd[e] <= 0 && enemyCount < eId.length) {
                    immutable slot = enemyCount++;
                    eId[slot] = nextEnemyId++;
                    eKind[slot] = kind.summonKind;
                    eTile[slot] = eTile[e];
                    eProgress[slot] = 0;
                    eHp[slot] = setup.enemies[kind.summonKind].hp;
                    eSink[slot] = eSink[e];
                    eSlow[slot] = 0;
                    eAttack[slot] = -1;
                    eLeaked[slot] = false;
                    initEnemySupport(slot, kind.summonKind);
                    kindSeen[kind.summonKind] = true;
                    ++eSummoned[e];
                    eSummonCd[e] = kind.summonEvery;
                    cue(CueKind.summoned, eId[e], kind.summonKind);
                }
            }
            if (kind.burnPower > 0 && --eBurnCd[e] <= 0) {
                eBurnCd[e] = kind.burnEvery;
                int hurt = 0;
                foreach (s; 0 .. structureCount) {
                    if (!sAlive[s] || tileDistance(eTile[e], sTile[s]) > kind.burnRadius)
                        continue;
                    harm(s, kind.burnPower);
                    ++hurt;
                }
                if (hurt > 0)
                    cue(CueKind.burned, hurt, eId[e]);
            }
        }
    }

    /// Damage to a unit: its shield first, then its hit points; at zero a hero is downed and a
    /// structure ruined.
    private void harm(int s, int amount) {
        if (sShield[s] > 0) {
            immutable absorbed = sShield[s] < amount ? sShield[s] : amount;
            sShield[s] -= absorbed;
            amount -= absorbed;
        }
        sHp[s] -= amount;
        if (sHp[s] <= 0 && sAlive[s]) {
            if (sIsHero[s])
                down(s);
            else
                ruin(s);
        }
    }

    /// A taunted enemy within a taunting hero's radius is pulled toward it. Returns the tile to
    /// move to, -2 to stay (the enemy attacks), or -1 when no taunt applies.
    private int tauntStep(int e) {
        foreach (s; 0 .. structureCount) {
            if (!sAlive[s] || !sIsHero[s] || sTauntUntil[s] <= stepIndex)
                continue;
            immutable d = tileDistance(eTile[e], sTile[s]);
            if (d > sTauntRadius[s])
                continue;
            if (d <= 1) {
                eAttack[e] = s;
                eProgress[e] = 0;
                return -2;
            }
            int best = -1, bestDistance = d;
            immutable q0 = eTile[e] % width, r0 = eTile[e] / width;
            foreach (step; neighbourOffsets) {
                immutable idx = regionIndex(width, height, q0 + step[0], r0 + step[1]);
                if (idx < 0 || wall[idx] || !revealed[idx] || structureAt[idx] != 0)
                    continue;
                immutable nd = tileDistance(idx, sTile[s]);
                if (nd < bestDistance) {
                    bestDistance = nd;
                    best = idx;
                }
            }
            return best;
        }
        return -1;
    }

    /// Living enemies inside a hex disc of `radius` around region tile `centre`, in bucket order.
    /// The slice points into `within` and is valid until the next call.
    private const(int)[] enemiesWithin(int centre, int radius) {
        int count = 0;
        immutable q0 = centre % width, r0 = centre / width;
        foreach (dq; -radius .. radius + 1)
            foreach (dr; -radius .. radius + 1) {
                if (!inDisc(dq, dr, radius))
                    continue;
                immutable idx = regionIndex(width, height, q0 + dq, r0 + dr);
                if (idx < 0 || bucketStamp[idx] != generation)
                    continue;
                for (int e = bucketHead[idx]; e >= 0; e = bucketNext[e])
                    if (eHp[e] > 0)
                        within[count++] = e;
            }
        return within[0 .. count];
    }

    private int nearestEnemy(int from, int range) {
        int best = -1, bestDistance = int.max;
        immutable q0 = from % width, r0 = from / width;
        foreach (dq; -range .. range + 1)
            foreach (dr; -range .. range + 1) {
                if (!inDisc(dq, dr, range))
                    continue;
                immutable idx = regionIndex(width, height, q0 + dq, r0 + dr);
                if (idx < 0 || bucketStamp[idx] != generation)
                    continue;
                for (int e = bucketHead[idx]; e >= 0; e = bucketNext[e]) {
                    if (eHp[e] <= 0)
                        continue;
                    immutable d = enemyDistance(e);
                    if (best < 0 || d < bestDistance || (d == bestDistance && eId[e] < eId[best])) {
                        best = e;
                        bestDistance = d;
                    }
                }
            }
        return best;
    }

    /// Chain: the first target, then up to `jumps` nearest living enemies not yet hit, each within
    /// `radius` of the previous one (ties to the lowest id).
    private void chainFrom(int tower, int first, TowerKind kind, int damage) {
        int[maxChain] hits;
        int count = 0;
        hits[count++] = first;
        hit(tower, first, damage);
        while (count < kind.jumps + 1) {
            immutable last = hits[count - 1];
            int best = -1, bestDistance = int.max;
            foreach (other; enemiesWithin(eTile[last], kind.radius)) {
                if (eHp[other] <= 0 || alreadyHit(hits[0 .. count], other))
                    continue;
                immutable d = tileDistance(eTile[last], eTile[other]);
                if (best < 0 || d < bestDistance || (d == bestDistance && eId[other] < eId[best])) {
                    best = other;
                    bestDistance = d;
                }
            }
            if (best < 0)
                break;
            hits[count++] = best;
            hit(tower, best, damage);
        }
    }

    private static bool alreadyHit(const(int)[] hits, int e) {
        foreach (h; hits)
            if (h == e)
                return true;
        return false;
    }

    private void hit(int tower, int e, int damage) {
        immutable armour = setup.enemies[eKind[e]].armour;
        int taken = damage - armour > 0 ? damage - armour : 1;
        if (eShield[e] > 0) {
            immutable absorbed = eShield[e] < taken ? eShield[e] : taken;
            eShield[e] -= absorbed;
            taken -= absorbed;
        }
        eHp[e] -= taken;
        cue(CueKind.hit, tower, eId[e]);
    }

    private void attackStructures() {
        if (setup.attackEvery > 1 && stepIndex % setup.attackEvery != 0)
            return;
        foreach (e; 0 .. enemyCount) {
            if (eHp[e] <= 0 || eAttack[e] < 0)
                continue;
            immutable s = eAttack[e];
            if (!sAlive[s]) {
                eAttack[e] = -1;
                continue;
            }
            harm(s, setup.enemies[eKind[e]].structureDamage);
        }
    }

    private void down(int s) {
        sAlive[s] = false;
        sDowned[s] = true;
        structureAt[sTile[s]] = 0;
        fieldsDirty = true;
        cue(CueKind.down, sId[s], sKind[s]);
    }

    private void ruin(int s) {
        sAlive[s] = false;
        structureAt[sTile[s]] = 0;
        fieldsDirty = true;
        cue(CueKind.ruin, sId[s], sKind[s]);
    }

    private void removeDead() {
        int write = 0;
        foreach (read; 0 .. enemyCount) {
            if (eHp[read] > 0) {
                if (write != read)
                    moveEnemy(read, write);
                ++write;
            } else if (eLeaked[read]) {
                ++leaks;
                ++leaksPerSink[eSink[read]];
                cue(CueKind.leak, eSink[read], eId[read]);
            } else {
                ++kills;
                credits += setup.enemies[eKind[read]].bounty * (100 + globalBounty) / 100;
                cue(CueKind.death, eKind[read], eId[read]);
            }
        }
        enemyCount = write;
    }

    private void moveEnemy(int from, int to) {
        eId[to] = eId[from];
        eKind[to] = eKind[from];
        eTile[to] = eTile[from];
        eProgress[to] = eProgress[from];
        eHp[to] = eHp[from];
        eSink[to] = eSink[from];
        eSlow[to] = eSlow[from];
        eAttack[to] = eAttack[from];
        eLeaked[to] = eLeaked[from];
        eShield[to] = eShield[from];
        eBurn[to] = eBurn[from];
        eBurnPower[to] = eBurnPower[from];
        eSummonCd[to] = eSummonCd[from];
        eSummoned[to] = eSummoned[from];
        eBurnCd[to] = eBurnCd[from];
        eTaunt[to] = eTaunt[from];
    }

    private bool allWavesSpawned() const {
        foreach (w, wave; setup.waves)
            if (waveSpawned[w] < wave.count)
                return false;
        return true;
    }

    private StepResult evaluateMoments() {
        firedMoment = -1;
        immutable ended = outcome != Outcome.running;
        foreach (i, m; setup.moments) {
            if (momentFired[i])
                continue;
            immutable closing = m.trigger == Trigger.battleWon || m.trigger == Trigger.battleLost;
            if (!closing && (ended || momentsFired >= setup.momentCap))
                continue;
            if (!momentTriggered(m))
                continue;
            momentFired[i] = true;
            if (!closing)
                ++momentsFired;
            firedMoment = cast(int) i;
            return StepResult.moment;
        }
        if (outcome == Outcome.won)
            return StepResult.won;
        if (outcome == Outcome.lost)
            return StepResult.lost;
        if (outcome == Outcome.withdrawn)
            return StepResult.withdrawn;
        return StepResult.running;
    }

    private bool momentTriggered(const MomentSpec m) const {
        final switch (m.trigger) {
        case Trigger.step:
            return stepIndex >= m.arg;
        case Trigger.waveStart:
            return waveStarted[m.arg - 1];
        case Trigger.structureDestroyed:
            immutable slot = slotOf(m.arg);
            return slot >= 0 && !sAlive[slot];
        case Trigger.leakCount:
            return leaks >= m.arg;
        case Trigger.heroDowned:
            foreach (s; 0 .. structureCount)
                if (sIsHero[s] && sDowned[s] && (m.arg == 0 || sId[s] == m.arg))
                    return true;
            return false;
        case Trigger.heroHpBelow:
            immutable hero = slotOf(m.arg);
            return hero >= 0 && sIsHero[hero] && sAlive[hero] && sHp[hero] * 100 < m.arg2 * sMaxHp[hero];
        case Trigger.heroesNear: {
                immutable a = slotOf(m.arg), b = slotOf(m.arg2);
                return a >= 0 && b >= 0 && sAlive[a] && sAlive[b] && tileDistance(sTile[a], sTile[b]) <= m.arg3;
            }
        case Trigger.enemyKindSeen:
            return kindSeen[m.arg];
        case Trigger.battleWon:
            return outcome == Outcome.won;
        case Trigger.battleLost:
            return outcome == Outcome.lost;
        }
    }

    private int slotOf(int id) const {
        foreach (s; 0 .. structureCount)
            if (sId[s] == id)
                return s;
        return -1;
    }

    private void cue(CueKind kind, int a, int b) {
        if (cueCount < cues.length) {
            cues[cueCount++] = Cue(kind, a, b);
        } else {
            ++cueDropped;
        }
    }

    private bool place(Command c, out string refusal) {
        if (c.towerKind < 0 || c.towerKind >= setup.towers.length) {
            refusal = "no such tower";
            return false;
        }
        if (!map.inside(c.q, c.r)) {
            refusal = "outside the map";
            return false;
        }
        immutable t = regionIndex(width, height, c.q, c.r);
        if (!revealed[t]) {
            refusal = "not revealed yet";
            return false;
        }
        if (wall[t]) {
            refusal = "the ground is impassable here";
            return false;
        }
        if (structureAt[t] != 0) {
            refusal = "occupied";
            return false;
        }
        foreach (src; sourceTile)
            if (src == t) {
                refusal = "cannot build on a source";
                return false;
            }
        foreach (sink; sinkTile)
            if (sink == t) {
                refusal = "cannot build on a sink";
                return false;
            }
        foreach (e; 0 .. enemyCount)
            if (eTile[e] == t && eHp[e] > 0) {
                refusal = "an enemy is standing there";
                return false;
            }
        immutable kind = setup.towers[c.towerKind];
        if (!kind.buildable) {
            refusal = "that cannot be built";
            return false;
        }
        if (kind.cost > credits) {
            refusal = "not enough credits";
            return false;
        }
        if (structureCount >= sId.length) {
            refusal = "no room for more structures";
            return false;
        }
        immutable slot = structureCount;
        addUnit(nextStructureId, c.towerKind, c.q, c.r, kind.hp, false);
        credits -= kind.cost;
        fieldsDirty = true;
        cue(CueKind.build, sId[slot], c.towerKind);
        return true;
    }

    private bool sell(Command c, out string refusal) {
        immutable slot = slotOf(c.target);
        if (slot < 0 || !sAlive[slot]) {
            refusal = "no such structure";
            return false;
        }
        if (sIsHero[slot]) {
            refusal = "a hero cannot be sold";
            return false;
        }
        immutable kind = setup.towers[sKind[slot]];
        credits += kind.cost * sLevel[slot] / 2;
        sAlive[slot] = false;
        sSold[slot] = true;
        structureAt[sTile[slot]] = 0;
        fieldsDirty = true;
        cue(CueKind.sell, c.target, sKind[slot]);
        return true;
    }

    private bool upgrade(Command c, out string refusal) {
        immutable slot = slotOf(c.target);
        if (slot < 0 || !sAlive[slot]) {
            refusal = "no such structure";
            return false;
        }
        if (sIsHero[slot]) {
            refusal = "a hero cannot be upgraded";
            return false;
        }
        if (sLevel[slot] >= maxLevel) {
            refusal = "already at the top level";
            return false;
        }
        immutable cost = setup.towers[sKind[slot]].cost * sLevel[slot];
        if (cost > credits) {
            refusal = "not enough credits";
            return false;
        }
        credits -= cost;
        ++sLevel[slot];
        cue(CueKind.upgrade, c.target, sLevel[slot]);
        return true;
    }

    private bool heroSlot(int id, out int slot, out string refusal) {
        slot = slotOf(id);
        if (slot < 0 || !sIsHero[slot]) {
            refusal = "no such hero";
            return false;
        }
        if (!sAlive[slot]) {
            refusal = "the hero is down";
            return false;
        }
        return true;
    }

    private int drawPercent() {
        rngState += 0x9E3779B97F4A7C15UL;
        ulong z = rngState;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
        z ^= z >> 31;
        ++rngDraws;
        return cast(int)((z >> 33) % 100);
    }

    private bool walkable(int q, int r, out string refusal) const {
        if (!map.inside(q, r)) {
            refusal = "outside the map";
            return false;
        }
        immutable t = regionIndex(width, height, q, r);
        if (!revealed[t]) {
            refusal = "not revealed yet";
            return false;
        }
        if (wall[t]) {
            refusal = "the ground is impassable here";
            return false;
        }
        return true;
    }

    private bool moveHero(Command c, out string refusal) {
        int slot;
        if (!heroSlot(c.target, slot, refusal))
            return false;
        if (!walkable(c.q, c.r, refusal))
            return false;
        immutable t = regionIndex(width, height, c.q, c.r);
        if (structureAt[t] != 0 && structureAt[t] - 1 != slot) {
            refusal = "occupied";
            return false;
        }
        int obedience = sObedience[slot] + sModObedience[slot];
        if (obedience > 100)
            obedience = 100;
        if (obedience < 100 && drawPercent() >= obedience) {
            cue(CueKind.disobey, sId[slot], 0);
            return true;
        }
        sFollow[slot] = 0;
        sMoveTarget[slot] = t == sTile[slot] ? -1 : t;
        return true;
    }

    private bool orderHero(Command c, out string refusal) {
        int slot;
        if (!heroSlot(c.target, slot, refusal))
            return false;
        switch (c.a) {
        case 0:
            sMoveTarget[slot] = -1;
            sFollow[slot] = 0;
            return true;
        case 1: {
                if (!walkable(c.q, c.r, refusal))
                    return false;
                immutable t = regionIndex(width, height, c.q, c.r);
                sFollow[slot] = 0;
                sMoveTarget[slot] = t == sTile[slot] ? -1 : t;
                return true;
            }
        case 2: {
                int other;
                if (!heroSlot(c.b, other, refusal))
                    return false;
                sFollow[slot] = c.b;
                sMoveTarget[slot] = -1;
                return true;
            }
        default:
            refusal = "unknown order";
            return false;
        }
    }

    private bool useAbility(Command c, out string refusal) {
        int slot;
        if (!heroSlot(c.target, slot, refusal))
            return false;
        immutable ak = sAbilityKind[slot];
        if (ak < 0) {
            refusal = "this hero has no ability";
            return false;
        }
        if (sAbilityCd[slot] > 0) {
            refusal = "the ability is not ready";
            return false;
        }
        immutable kind = setup.towers[ak];
        immutable radius = kind.radius + sModRadius[slot];
        immutable rate = 100 + sModRate[slot];
        final switch (kind.primitive) {
        case Primitive.repair: {
                int helped = 0;
                foreach (t; 0 .. structureCount) {
                    if (!sAlive[t] || sHp[t] >= sMaxHp[t] || tileDistance(sTile[slot], sTile[t]) > radius)
                        continue;
                    immutable before = sHp[t];
                    sHp[t] += kind.power * rate / 100;
                    if (sHp[t] > sMaxHp[t])
                        sHp[t] = sMaxHp[t];
                    cue(CueKind.repaired, sId[t], sHp[t] - before);
                    ++helped;
                }
                if (helped == 0) {
                    refusal = "nothing nearby needs repair";
                    return false;
                }
                break;
            }
        case Primitive.taunt:
            sTauntUntil[slot] = stepIndex + kind.duration;
            sTauntRadius[slot] = radius;
            cue(CueKind.taunted, sId[slot], 0);
            break;
        case Primitive.burn: {
                int tq = c.q, tr = c.r;
                if (tq < 0 && tr < 0) {
                    tq = sTile[slot] % width;
                    tr = sTile[slot] / width;
                }
                if (!map.inside(tq, tr)) {
                    refusal = "outside the map";
                    return false;
                }
                immutable centre = regionIndex(width, height, tq, tr);
                if (kind.range > 0 && tileDistance(sTile[slot], centre) > kind.range) {
                    refusal = "out of range";
                    return false;
                }
                // targets are found by tile, not by the firing buckets (which are per step)
                int burned = 0;
                foreach (e; 0 .. enemyCount) {
                    if (eHp[e] > 0 && tileDistance(eTile[e], centre) <= radius) {
                        ignite(e, kind.power, kind.duration);
                        ++burned;
                    }
                }
                if (burned > 0)
                    cue(CueKind.burned, burned, sId[slot]);
                if (kind.reveal > 0) {
                    immutable sector = fog.sectorOf(tq, tr);
                    if (sector >= 0 && fog.reveal(sector)) {
                        fieldsDirty = true;
                        cue(CueKind.flare, sector, 0);
                    }
                }
                break;
            }
        case Primitive.shield:
            if (!supportAct(slot, kind, radius)) {
                refusal = "nothing nearby needs a shield";
                return false;
            }
            break;
        case Primitive.singleTarget:
        case Primitive.splash:
        case Primitive.slow:
        case Primitive.chain:
        case Primitive.aura:
        case Primitive.summon:
            refusal = "this ability cannot be used";
            return false;
        }
        sAbilityCd[slot] = kind.cooldown;
        return true;
    }

    private bool repairStructure(Command c, out string refusal) {
        immutable slot = slotOf(c.target);
        if (slot < 0 || !sAlive[slot]) {
            refusal = "no such structure";
            return false;
        }
        immutable missing = sMaxHp[slot] - sHp[slot];
        if (missing <= 0) {
            refusal = "it is not damaged";
            return false;
        }
        immutable cost = (missing + 1) / 2;
        if (cost > credits) {
            refusal = "not enough credits";
            return false;
        }
        credits -= cost;
        sHp[slot] = sMaxHp[slot];
        cue(CueKind.repaired, sId[slot], missing);
        return true;
    }

    private bool modHero(Command c, out string refusal) {
        immutable slot = slotOf(c.target);
        if (slot < 0 || !sIsHero[slot]) {
            refusal = "no such hero";
            return false;
        }
        sModRadius[slot] += c.a;
        sModDamage[slot] += c.b;
        sModObedience[slot] += c.c;
        sModRate[slot] += c.d;
        return true;
    }

    private bool addBond(Command c, out string refusal) {
        if (bondCount >= bondA.length) {
            refusal = "too many bonds";
            return false;
        }
        immutable a = slotOf(c.target), b = slotOf(c.a);
        if (a < 0 || b < 0 || !sIsHero[a] || !sIsHero[b]) {
            refusal = "a bond joins two heroes";
            return false;
        }
        bondA[bondCount] = c.target;
        bondB[bondCount] = c.a;
        bondWithin[bondCount] = c.b;
        bondPct[bondCount] = c.c;
        ++bondCount;
        return true;
    }

    private bool reinforce(Command c, out string refusal) {
        if (c.towerKind < 0 || c.towerKind >= setup.towers.length) {
            refusal = "no such tower";
            return false;
        }
        if (structureCount >= sId.length) {
            refusal = "no room for more structures";
            return false;
        }
        foreach (radius; 0 .. 3)
            foreach (dr; -radius .. radius + 1)
                foreach (dq; -radius .. radius + 1) {
                    if (!inDisc(dq, dr, radius) || hexDistance(0, 0, dq, dr) != radius)
                        continue;
                    immutable idx = regionIndex(width, height, c.q + dq, c.r + dr);
                    if (idx < 0 || wall[idx] || !revealed[idx] || structureAt[idx] != 0)
                        continue;
                    bool special = false;
                    foreach (t; sourceTile)
                        special = special || t == idx;
                    foreach (t; sinkTile)
                        special = special || t == idx;
                    foreach (e; 0 .. enemyCount)
                        special = special || (eHp[e] > 0 && eTile[e] == idx);
                    if (special)
                        continue;
                    immutable slot = structureCount;
                    addUnit(nextStructureId, c.towerKind, c.q + dq, c.r + dr, setup.towers[c.towerKind].hp, false);
                    fieldsDirty = true;
                    cue(CueKind.reinforced, sId[slot], c.towerKind);
                    return true;
                }
        refusal = "no free tile near there";
        return false;
    }

    private bool heal(Command c, out string refusal) {
        switch (c.a) {
        case 0:
            leaks = leaks > c.c ? leaks - c.c : 0;
            cue(CueKind.healed, 0, c.c);
            return true;
        case 1: {
                immutable slot = slotOf(c.target);
                if (slot < 0) {
                    refusal = "no such unit";
                    return false;
                }
                healUnit(slot, c.c);
                return true;
            }
        case 2: {
                immutable slot = slotOf(c.target);
                if (slot < 0) {
                    refusal = "no such hero";
                    return false;
                }
                foreach (t; 0 .. structureCount)
                    if (sAlive[t] && !sIsHero[t] && tileDistance(sTile[slot], sTile[t]) <= c.b)
                        healUnit(t, c.c);
                return true;
            }
        case 3: {
                immutable slot = slotOf(c.target);
                if (slot < 0 || !sAlive[slot]) {
                    refusal = "no such structure";
                    return false;
                }
                healUnit(slot, c.c);
                return true;
            }
        default:
            refusal = "unknown heal";
            return false;
        }
    }

    /// Heals a unit; a downed hero stands again if its tile is free.
    private void healUnit(int slot, int amount) {
        if (!sAlive[slot]) {
            if (!sIsHero[slot] || !sDowned[slot] || structureAt[sTile[slot]] != 0)
                return;
            sAlive[slot] = true;
            sDowned[slot] = false;
            sHp[slot] = 0;
            structureAt[sTile[slot]] = slot + 1;
            fieldsDirty = true;
        }
        immutable before = sHp[slot];
        sHp[slot] += amount;
        if (sHp[slot] > sMaxHp[slot])
            sHp[slot] = sMaxHp[slot];
        cue(CueKind.healed, sId[slot], sHp[slot] - before);
    }

    private bool setHp(Command c, out string refusal) {
        immutable slot = slotOf(c.target);
        if (slot < 0 || !sAlive[slot] || c.a < 1) {
            refusal = "no such structure, or a hit point count below 1";
            return false;
        }
        sHp[slot] = c.a < sMaxHp[slot] ? c.a : sMaxHp[slot];
        return true;
    }

    private bool damageHero(Command c, out string refusal) {
        int slot;
        if (!heroSlot(c.target, slot, refusal))
            return false;
        harm(slot, c.a);
        return true;
    }

    private static ulong hashAdd(ulong h, long value) {
        immutable ulong bits = cast(ulong) value;
        foreach (shift; 0 .. 8) {
            h ^= (bits >> (shift * 8)) & 0xFF;
            h *= 1_099_511_628_211UL;
        }
        return h;
    }
}

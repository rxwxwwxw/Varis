/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/*
** varis - Unit tests for the tower-defense battle (TOWER_DEFENSE_PLAN.md TD1-TD2): hex maths,
** terrain, fog, flow fields, setup validation, the step, commands, moments, cues and replay.
*/

module tests.unit.test_battle;

import varis.game.battle;
import varis.game.fog;
import varis.game.hex;
import varis.game.kinds;
import varis.game.route;
import varis.game.terrain;
import varis.game.types;

import varis.lib.battle;
import varis.services.manifest : loadManifest;
import varis.state : LuaState;
import varis.types : LuaValue;

import tests.unit.unit_runner : UnitMain;
import std.stdio : writeln;
import core.memory : GC;
import std.datetime.stopwatch : StopWatch, AutoStart;

// ---- fixtures -----------------------------------------------------------------------------------

/// A one-row map: the only route from source (0, 0) to sink (15, 0) is the corridor itself.
BattleSetup corridorSetup(TowerKind[] towers, StructureSpec[] structures,
        WaveSpec[] waves, MomentSpec[] moments) {
    TileEdit[] edits;
    foreach (q; 0 .. 16)
        edits ~= TileEdit(q, 0, false);
    BattleSetup s;
    s.seed = 42;
    s.width = 16;
    s.height = 1;
    s.mapSeed = 3;
    s.edits = edits;
    s.revealedSectors = [0];
    s.sinks = [[15, 0]];
    s.sources = [SourceSpec(0, 0, 0)];
    s.structures = structures;
    s.waves = waves;
    s.moments = moments;
    s.towers = towers;
    s.enemies = [
        EnemyKind("dimling", 12, 128, 0, 2, 1),
        EnemyKind("husk", 40, 96, 2, 4, 3),
    ];
    s.credits = 100;
    s.maxLeaks = 3;
    s.momentCap = 3;
    s.structureRoom = 4;
    return s;
}

TowerKind boltKind() {
    return TowerKind("bolt", 10, 2, 5, 2, 30, Primitive.singleTarget, 0, 0, 0);
}

/// A blocker: no range, so it never fires; it only stands in the way.
TowerKind blockerKind() {
    return TowerKind("blocker", 1, 0, 1, 1, 6, Primitive.singleTarget, 0, 0, 0);
}

/// Runs the battle to its end, counting moments. Returns the final result.
StepResult runToEnd(ref Battle b, out int moments, int limit = 5000) {
    moments = 0;
    foreach (_; 0 .. limit) {
        immutable result = b.step();
        if (result == StepResult.moment) {
            ++moments;
            continue;
        }
        if (result != StepResult.running)
            return result;
    }
    assert(false, "battle did not end");
}

// ---- hex, terrain, fog, route -------------------------------------------------------------------

@("testHexIdentities") unittest {
    assert(tileQ(tileId(-7, 12)) == -7);
    assert(tileR(tileId(-7, 12)) == 12);
    assert(tileId(0, 0) != tileId(0, 1));
    assert(hexDistance(0, 0, 1, 0) == 1);
    assert(hexDistance(0, 0, 1, -1) == 1);
    assert(hexDistance(0, 0, 2, -1) == 2);
    assert(hexDistance(-3, 2, 3, -2) == 6);
    foreach (dir; 0 .. 6) {
        int nq, nr;
        neighbour(5, 5, dir, nq, nr);
        assert(hexDistance(5, 5, nq, nr) == 1);
    }
    assert(discSize(0) == 1 && discSize(1) == 7 && discSize(3) == 37);
    int inside = 0;
    foreach (dq; -3 .. 4)
        foreach (dr; -3 .. 4)
            if (inDisc(dq, dr, 3))
                ++inside;
    assert(inside == discSize(3));
    assert(regionIndex(4, 3, 3, 2) == 11 && regionIndex(4, 3, 4, 0) == -1);
    writeln("  [PASS] testHexIdentities");
}

@("testTerrainIsPureAndEditable") unittest {
    MapRegion map;
    map.width = 48;
    map.height = 27;
    map.seed = 7;
    assert(map.isWall(-1, 0) && map.isWall(48, 0));
    int walls = 0;
    foreach (q; 0 .. map.width)
        foreach (r; 0 .. map.height) {
            assert(map.isWall(q, r) == map.isWall(q, r));
            assert(map.heightAt(q, r) >= 0 && map.heightAt(q, r) <= 7);
            if (map.isWall(q, r))
                ++walls;
        }
    assert(walls > 60 && walls < 260);
    MapRegion other = map;
    other.seed = 8;
    int differ = 0;
    foreach (q; 0 .. map.width)
        foreach (r; 0 .. map.height)
            if (map.isWall(q, r) != other.isWall(q, r))
                ++differ;
    assert(differ > 0);
    immutable TileEdit[2] edits = [TileEdit(3, 3, true), TileEdit(4, 4, false)];
    map.edits = edits[];
    assert(map.isWall(3, 3));
    assert(!map.isWall(4, 4));
    writeln("  [PASS] testTerrainIsPureAndEditable");
}

@("testFogSectors") unittest {
    auto storage = new ubyte[64];
    Fog fog;
    fog.setup(48, 27, storage);
    assert(fog.sectorsWide == 3 && fog.sectorsHigh == 3 && fog.sectorCount() == 9);
    assert(fog.sectorOf(0, 0) == 0 && fog.sectorOf(16, 0) == 1 && fog.sectorOf(0, 9) == 3);
    assert(fog.sectorOf(47, 26) == 8 && fog.sectorOf(48, 0) == -1);
    assert(!fog.isRevealed(5, 5));
    assert(fog.reveal(0));
    assert(!fog.reveal(0));
    assert(fog.isRevealed(15, 8) && !fog.isRevealed(16, 0));
    // the growth of the plan: 48 x 27 -> 64 x 36 -> 80 x 45 -> 96 x 54 tiles
    fog.setup(96, 54, storage);
    assert(fog.sectorCount() == 36);
    fog.setup(80, 45, storage);
    assert(fog.sectorsWide == 5 && fog.sectorsHigh == 5);
    writeln("  [PASS] testFogSectors");
}

@("testFlowFieldProperties") unittest {
    enum width = 5, height = 5;
    bool[width * height] blocked;
    blocked[2 + 0 * width] = true;
    blocked[2 + 1 * width] = true;
    blocked[2 + 2 * width] = true;
    int[width * height] parent, distance, queue;
    immutable reached = buildField(blocked[], width, height, 0, parent[], distance[], queue[]);
    assert(reached == width * height - 3);
    assert(distance[0] == 0 && parent[0] == -1);
    assert(distance[1] == 1 && parent[1] == 0);
    assert(distance[4] > 4);
    assert(distance[2] == unreachable);
    foreach (start; 0 .. width * height) {
        if (distance[start] == unreachable)
            continue;
        int t = start, steps = 0;
        while (t != 0) {
            t = parent[t];
            ++steps;
        }
        assert(steps == distance[start]);
    }
    writeln("  [PASS] testFlowFieldProperties");
}

@("testFlowFieldOnPseudoRandomMap") unittest {
    enum width = 7, height = 6;
    bool[width * height] blocked;
    uint state = 99;
    foreach (i; 0 .. width * height) {
        state = state * 1664525 + 1013904223;
        blocked[i] = (state >> 24) < 40;
    }
    immutable sink = 5 * width + 6;
    blocked[sink] = false;
    int[width * height] parent, distance, queue;
    buildField(blocked[], width, height, sink, parent[], distance[], queue[]);
    // every reached tile's parent is one step closer, and no open neighbour is more than one
    // step farther than a reached tile
    foreach (t; 0 .. width * height) {
        if ((blocked[t] && t != sink) || distance[t] == unreachable || t == sink)
            continue;
        immutable p = parent[t];
        assert(p >= 0 && distance[p] + 1 == distance[t]);
        foreach (step; neighbourOffsetsForTest) {
            immutable q = t % width + step[0], r = t / width + step[1];
            if (q < 0 || r < 0 || q >= width || r >= height)
                continue;
            immutable n = r * width + q;
            if (blocked[n] || distance[n] == unreachable)
                continue;
            assert(distance[t] <= distance[n] + 1);
        }
    }
    writeln("  [PASS] testFlowFieldOnPseudoRandomMap");
}

immutable int[2][6] neighbourOffsetsForTest = [
    [1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]
];

// ---- setup validation ---------------------------------------------------------------------------

@("testValidationAcceptsCorridor") unittest {
    auto s = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 3, 4, 0)], []);
    assert(Battle.validate(s).ok());
    writeln("  [PASS] testValidationAcceptsCorridor");
}

@("testValidationNamesTheField") unittest {
    auto base = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 3, 4, 0)], []);

    auto unknownKind = base;
    unknownKind.waves = [WaveSpec(0, 7, 1, 1, 0)];
    auto p = Battle.validate(unknownKind);
    assert(p.field == "waves.kind" && p.index == 0);

    auto offMap = base;
    offMap.structures = [StructureSpec(1, 0, 40, 0)];
    p = Battle.validate(offMap);
    assert(p.field == "structures" && p.index == 0);

    auto noSink = base;
    noSink.sinks = [];
    p = Battle.validate(noSink);
    assert(p.field == "sinks");

    auto burning = base;
    burning.towers = [TowerKind("torch", 10, 2, 5, 2, 30, Primitive.burn, 0, 0, 0)];
    p = Battle.validate(burning);
    assert(p.field == "towers.power" && p.index == 0);
    burning.towers = [TowerKind("torch", 10, 2, 5, 2, 30, Primitive.burn, 0, 3, 0, 2)];
    assert(Battle.validate(burning).ok());
    burning.towers = [TowerKind("hive", 10, 2, 5, 2, 30, Primitive.summon)];
    p = Battle.validate(burning);
    assert(p.field == "towers.ability" && p.index == 0);

    // a wall in the only corridor: the source cannot reach the sink
    TileEdit[] edits;
    foreach (q; 0 .. 16)
        edits ~= TileEdit(q, 0, q == 8);
    auto cut = base;
    cut.edits = edits;
    p = Battle.validate(cut);
    assert(p.field == "sources");

    auto unknownStructure = base;
    unknownStructure.moments = [MomentSpec(1, Trigger.structureDestroyed, 99, "scene")];
    p = Battle.validate(unknownStructure);
    assert(p.field == "moments.arg");

    auto duplicate = base;
    duplicate.moments = [MomentSpec(1, Trigger.step, 2, "a"), MomentSpec(1, Trigger.step, 3, "b")];
    p = Battle.validate(duplicate);
    assert(p.field == "moments.id" && p.index == 1);

    auto sceneless = base;
    sceneless.moments = [MomentSpec(1, Trigger.step, 2, "")];
    p = Battle.validate(sceneless);
    assert(p.field == "moments.scene");

    writeln("  [PASS] testValidationNamesTheField");
}

@("testRefusedSetupLeavesBattleUnstarted") unittest {
    auto bad = corridorSetup([boltKind()], [], [WaveSpec(0, 7, 1, 1, 0)], []);
    Battle b;
    immutable p = b.begin(bad);
    assert(!p.ok() && p.field == "waves.kind");
    assert(b.enemyCount == 0 && b.stepIndex == 0);
    writeln("  [PASS] testRefusedSetupLeavesBattleUnstarted");
}

// ---- the step ----------------------------------------------------------------------------------

@("testScriptedBattleIsWonAndDeterministic") unittest {
    auto moments = [MomentSpec(1, Trigger.step, 10, "early")];
    auto setup = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 6, 5, 0)], moments);

    Battle first;
    assert(first.begin(setup).ok());
    string refusal;
    assert(first.command(Command(CommandKind.place, 0, 0, 10, 0, 0), refusal), refusal);
    int pauses;
    immutable result = runToEnd(first, pauses);
    assert(result == StepResult.won);
    assert(pauses == 1);
    assert(first.kills == 6 && first.leaks == 0);
    assert(first.firedMoment == -1);
    assert(first.log.length == 1 && first.log[0].stamp == 0);

    // a second run from the same setup and command log gives the same digest
    Battle second;
    assert(second.begin(setup).ok());
    assert(second.command(Command(CommandKind.place, 0, 0, 10, 0, 0), refusal));
    int pausesAgain;
    assert(runToEnd(second, pausesAgain) == StepResult.won);
    assert(second.digest() == first.digest());
    assert(second.stepIndex == first.stepIndex);
    writeln("  [PASS] testScriptedBattleIsWonAndDeterministic");
}

@("testReplayFromLogAndRerunToStep") unittest {
    auto setup = corridorSetup([boltKind(), blockerKind()], [], [WaveSpec(0, 0, 4, 6, 0)], []);
    string refusal;

    // the original run: a place at step 0 and a sell at step 30
    Battle original;
    assert(original.begin(setup).ok());
    assert(original.command(Command(CommandKind.place, 0, 0, 10, 0, 0), refusal));
    ulong digestAt40 = 0;
    foreach (_; 0 .. 1000) {
        if (original.stepIndex == 30) {
            // a refused command is not logged, so replay must not need it; the outcome is the
            // same whether or not it applied
            string ignored;
            original.command(Command(CommandKind.place, 0, 1, 3, 0, 0), ignored);
        }
        immutable r = original.step();
        if (original.stepIndex == 40 && digestAt40 == 0)
            digestAt40 = original.digest();
        if (r == StepResult.won || r == StepResult.lost)
            break;
    }
    assert(digestAt40 != 0);

    // a rerun to step 40 equals the run through step 40
    Battle rerun;
    assert(rerun.begin(setup).ok());
    assert(rerun.command(Command(CommandKind.place, 0, 0, 10, 0, 0), refusal));
    while (rerun.stepIndex < 40)
        rerun.step();
    assert(rerun.digest() == digestAt40);

    // replaying the logged commands at their stamps reproduces the outcome exactly
    Battle replay;
    assert(replay.begin(setup).ok());
    size_t next = 0;
    StepResult last = StepResult.running;
    foreach (_; 0 .. 1000) {
        while (next < original.log.length && original.log[next].stamp == replay.stepIndex) {
            assert(replay.command(original.log[next], refusal), refusal);
            ++next;
        }
        last = replay.step();
        if (last == StepResult.won || last == StepResult.lost)
            break;
    }
    assert(replay.digest() == original.digest());
    writeln("  [PASS] testReplayFromLogAndRerunToStep");
}

@("testBlockerIsAttackedAndRuined") unittest {
    // the blocker stands in the only corridor; with no range it never fires, so the husk must
    // attack it; three per step against 6 hit points ruins it in two steps
    auto structures = [StructureSpec(5, 1, 8, 0)];
    auto moments = [
        MomentSpec(1, Trigger.structureDestroyed, 5, "ruin_scene"),
        MomentSpec(2, Trigger.battleLost, 0, "lost_scene"),
    ];
    auto setup = corridorSetup([boltKind(), blockerKind()], structures,
            [WaveSpec(0, 1, 1, 1, 0)], moments);
    setup.maxLeaks = 1;

    Battle b;
    assert(b.begin(setup).ok());
    int pauses;
    immutable result = runToEnd(b, pauses);
    assert(result == StepResult.lost);
    assert(pauses == 2);
    assert(b.leaks == 1);
    assert(b.structureCount == 1 && !b.sAlive[0]);
    assert(b.structureAt[8] == 0);

    // the ruin cue is recorded in the step it happened
    Battle observed;
    assert(observed.begin(setup).ok());
    bool sawRuin = false;
    foreach (_; 0 .. 5000) {
        immutable r = observed.step();
        foreach (cue; observed.lastCues())
            if (cue.kind == CueKind.ruin && cue.a == 5)
                sawRuin = true;
        if (r == StepResult.won || r == StepResult.lost)
            break;
    }
    assert(sawRuin);
    writeln("  [PASS] testBlockerIsAttackedAndRuined");
}

@("testMomentCapLimitsInterruptions") unittest {
    auto moments = [
        MomentSpec(1, Trigger.step, 1, "a"),
        MomentSpec(2, Trigger.step, 2, "b"),
        MomentSpec(3, Trigger.step, 3, "c"),
    ];
    auto setup = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 1, 1, 0)], moments);
    setup.momentCap = 1;
    Battle b;
    assert(b.begin(setup).ok());
    int pauses;
    assert(runToEnd(b, pauses) == StepResult.won);
    assert(pauses == 1);
    writeln("  [PASS] testMomentCapLimitsInterruptions");
}

@("testCommandRefusals") unittest {
    auto setup = corridorSetup([boltKind(), blockerKind()], [], [], []);
    setup.credits = 10;
    Battle b;
    assert(b.begin(setup).ok());
    string refusal;
    assert(b.command(Command(CommandKind.place, 0, 0, 3, 0, 0), refusal));
    assert(b.credits == 0);
    assert(!b.command(Command(CommandKind.place, 0, 0, 4, 0, 0), refusal) && refusal == "not enough credits");
    assert(!b.command(Command(CommandKind.place, 0, 0, 3, 0, 0), refusal) && refusal == "occupied");
    assert(!b.command(Command(CommandKind.place, 0, 0, 0, 0, 0), refusal) && refusal == "cannot build on a source");
    assert(!b.command(Command(CommandKind.place, 0, 0, 15, 0, 0), refusal) && refusal == "cannot build on a sink");
    assert(!b.command(Command(CommandKind.place, 0, 0, 40, 0, 0), refusal) && refusal == "outside the map");
    // the setup reveals sector 0, the only one of this map
    assert(!b.command(Command(CommandKind.reveal, 0, 0, 0, 0, 0), refusal) && refusal == "that sector is already revealed");
    // a sale refunds half the cost and frees the tile; the first placed structure has id 0
    assert(b.command(Command(CommandKind.sell, 0, 0, 0, 0, 0), refusal));
    assert(b.credits == 5);
    assert(b.structureAt[3] == 0);
    assert(b.log.length == 2);
    writeln("  [PASS] testCommandRefusals");
}

@("testUpgradeRaisesDamageAndCostsCredits") unittest {
    auto setup = corridorSetup([boltKind()], [StructureSpec(1, 0, 2, 0)], [], []);
    setup.credits = 30;
    Battle b;
    assert(b.begin(setup).ok());
    string refusal;
    assert(b.command(Command(CommandKind.upgrade, 0, 0, 0, 0, 1), refusal));
    assert(b.sLevel[0] == 2 && b.credits == 20);
    assert(b.command(Command(CommandKind.upgrade, 0, 0, 0, 0, 1), refusal));
    assert(b.sLevel[0] == 3 && b.credits == 0);
    assert(!b.command(Command(CommandKind.upgrade, 0, 0, 0, 0, 1), refusal) && refusal == "already at the top level");
    writeln("  [PASS] testUpgradeRaisesDamageAndCostsCredits");
}

// ---- heroes ------------------------------------------------------------------------------------

@("testHeroIsDownedNotRuined") unittest {
    // a hero blocks the only corridor like a structure; the husk attacks it and it is downed
    auto moments = [MomentSpec(1, Trigger.heroDowned, 0, "down_scene")];
    auto setup = corridorSetup([boltKind(), blockerKind()], [], [WaveSpec(0, 1, 1, 1, 0)], moments);
    setup.heroes = [HeroSpec(9, 1, 8, 0, 6)];
    setup.maxLeaks = 1;
    Battle b;
    assert(b.begin(setup).ok());
    bool sawDown = false, sawRuin = false;
    int pauses;
    immutable result = runToEnd(b, pauses);
    assert(result == StepResult.lost);
    assert(pauses == 1);
    assert(b.sIsHero[0] && b.sDowned[0] && !b.sAlive[0]);
    assert(b.structureAt[8] == 0);
    // the cue for a downed hero is `down`, never `ruin`
    Battle observed;
    assert(observed.begin(setup).ok());
    foreach (_; 0 .. 5000) {
        immutable r = observed.step();
        foreach (cue; observed.lastCues()) {
            sawDown = sawDown || cue.kind == CueKind.down;
            sawRuin = sawRuin || cue.kind == CueKind.ruin;
        }
        if (r == StepResult.won || r == StepResult.lost)
            break;
    }
    assert(sawDown && !sawRuin);
    writeln("  [PASS] testHeroIsDownedNotRuined");
}

@("testHeroHpBelowTriggersAtThreshold") unittest {
    // hero hit points 10, threshold 50 percent: the husk's first two hits leave 4 (below 5 of 10)
    auto moments = [MomentSpec(1, Trigger.heroHpBelow, 9, "wren_scene", true, 50)];
    auto setup = corridorSetup([boltKind(), blockerKind()], [], [WaveSpec(0, 1, 1, 1, 0)], moments);
    setup.heroes = [HeroSpec(9, 1, 8, 0, 10)];
    setup.maxLeaks = 1;
    Battle b;
    assert(b.begin(setup).ok());
    // step until the moment: the hero is still alive and at 4 hit points
    StepResult result = StepResult.running;
    foreach (_; 0 .. 5000) {
        result = b.step();
        if (result != StepResult.running)
            break;
    }
    assert(result == StepResult.moment);
    assert(b.firedMoment == 0 && b.sHp[0] == 4 && b.sAlive[0]);
    writeln("  [PASS] testHeroHpBelowTriggersAtThreshold");
}

@("testHeroesCannotBeSoldAndMustNotOverlap") unittest {
    auto setup = corridorSetup([boltKind(), blockerKind()], [], [], []);
    setup.heroes = [HeroSpec(9, 1, 8, 0, 6)];
    Battle b;
    assert(b.begin(setup).ok());
    string refusal;
    assert(!b.command(Command(CommandKind.sell, 0, 0, 0, 0, 9), refusal) && refusal == "a hero cannot be sold");
    assert(!b.command(Command(CommandKind.upgrade, 0, 0, 0, 0, 9), refusal) && refusal == "a hero cannot be upgraded");
    // a hero may not share a tile with a structure
    auto clash = setup;
    clash.structures = [StructureSpec(1, 0, 8, 0)];
    assert(Battle.validate(clash).field == "heroes");
    // hero hit points must be positive
    auto empty = setup;
    empty.heroes = [HeroSpec(9, 1, 8, 0, 0)];
    assert(Battle.validate(empty).field == "heroes.hp");
    writeln("  [PASS] testHeroesCannotBeSoldAndMustNotOverlap");
}

// ---- the bridge (Lua tables in, outcome table out) -----------------------------------------------

/// A one-row battle written as a project hook returns it: 1-based indices, string triggers.
private enum corridorLua = q"LUA
local edits = {}
for q = 0, 15 do edits[#edits + 1] = {q = q, r = 0, wall = false} end
return {
    seed = 1, map_seed = 3, width = 16, height = 1, credits = 100, max_leaks = 3, moment_cap = 2,
    structure_room = 4,
    edits = edits,
    revealed = {1},
    sinks = {{q = 15, r = 0}},
    sources = {{q = 0, r = 0, sink = 1}},
    towers = {{name = "bolt", cost = 10, range = 2, damage = 5, cooldown = 2, hp = 30, ability = "single"}},
    enemies = {{name = "dimling", hp = 12, speed = 128, bounty = 2, structure_damage = 1}},
    waves = {{source = 1, kind = 1, count = 3, every = 4}},
    moments = {{id = 1, trigger = "step", arg = 5, scene = "scene_a"}},
}
LUA";

@("testBridgeRunsLuaSetupToItsEnd") unittest {
    auto state = new LuaState();
    auto values = state.doString(corridorLua);
    assert(values.length == 1);
    auto host = new BattleHost();
    auto problem = host.start(values[0]);
    assert(problem.ok(), problem.message);
    string refusal;
    assert(host.battle.command(Command(CommandKind.place, 0, 0, 10, 0, 0), refusal), refusal);
    // the first pump stops at the step(5) moment, which names its scene
    assert(host.pump(5000) == StepResult.moment);
    assert(host.momentScene() == "scene_a");
    assert(host.pump(5000) == StepResult.won);
    assert(!host.active);
    // the outcome table is what battle_result receives
    auto outcome = outcomeTable(host.battle).asTable();
    assert(outcome.rawget(LuaValue("result")).asString() == "won");
    assert(outcome.rawget(LuaValue("kills")).asInteger() == 3);
    assert(outcome.rawget(LuaValue("leaks")).asInteger() == 0);
    writeln("  [PASS] testBridgeRunsLuaSetupToItsEnd");
}

@("testBridgeRefusesNamingTheField") unittest {
    auto state = new LuaState();
    auto values = state.doString(`return {seed = 1, map_seed = 3, width = 16, height = 1, credits = 100,
        max_leaks = 3, edits = {}, revealed = {1}, sinks = {{q = 15, r = 0}},
        sources = {{q = 0, r = 0, sink = 1}},
        towers = {{name = "torch", cost = 10, range = 2, damage = 5, cooldown = 2, hp = 30, ability = "burn"}},
        enemies = {{name = "dimling", hp = 12, speed = 128}}, waves = {}, moments = {}}`);
    auto host = new BattleHost();
    // a burn tower needs power and duration: validation refuses it by field
    auto problem = host.start(values[0]);
    assert(problem.field == "towers.power" && problem.index == 0, problem.field);
    assert(!host.active);
    // a non-table setup and a missing field are refused by name too
    assert(host.start(LuaValue(1L)).field == "setup");
    auto missing = state.doString("return {width = 1, height = 1}")[0];
    assert(host.start(missing).field == "setup.credits");
    writeln("  [PASS] testBridgeRefusesNamingTheField");
}

@("testManifestNamesTheBattleHooks") unittest {
    // unit tests run from the repository root, so the sample's manifest is at sample-td/
    auto manifest = loadManifest("sample-td");
    assert(manifest.present);
    assert(manifest.battleRequest == "game.battle_request");
    assert(manifest.battleSetup == "game.battle_setup");
    assert(manifest.battleSync == "game.battle_sync");
    assert(manifest.battleResult == "game.battle_result");
    writeln("  [PASS] testManifestNamesTheBattleHooks");
}

// ---- support, heroes and modifiers (TD7 slice) -------------------------------------------------

/// A kind for `primitive` with `power`, `radius` and `duration`; cooldown 4, hp 20.
TowerKind supportKind(Primitive primitive, int power, int radius, int duration = 0) {
    return TowerKind("support", 10, 3, 1, 4, 20, primitive, radius, duration, 0, power);
}

/// A command by name: the hero or structure `target`, tile `q`, `r`, and the modifier numbers.
Command cmd(CommandKind action, int target = 0, int q = 0, int r = 0, int a = 0, int b = 0,
        int c = 0, int d = 0, int towerKind = 0) {
    Command result;
    result.action = action;
    result.target = target;
    result.q = q;
    result.r = r;
    result.a = a;
    result.b = b;
    result.c = c;
    result.d = d;
    result.towerKind = towerKind;
    return result;
}

int slotOfId(const ref Battle b, int id) {
    foreach (s; 0 .. b.structureCount)
        if (b.sId[s] == id)
            return s;
    return -1;
}

@("testEnemyShieldAbsorbsDamage") unittest {
    auto plain = corridorSetup([boltKind()], [StructureSpec(1, 0, 6, 0)], [WaveSpec(0, 0, 1, 1, 0)], [
    ]);
    auto shielded = plain;
    shielded.enemies = [EnemyKind("dimling", 12, 128, 0, 2, 1, 20)];
    Battle a, b;
    assert(a.begin(plain).ok() && b.begin(shielded).ok());
    int moments;
    runToEnd(a, moments);
    runToEnd(b, moments);
    // 20 more points of damage at 5 per two steps: the shield costs the defence eight steps
    assert(b.stepIndex >= a.stepIndex + 6, "the shield did not delay the kill");
    assert(a.kills == 1 && b.kills == 1);
    writeln("  [PASS] testEnemyShieldAbsorbsDamage");
}

@("testBurnTowerSetsEnemiesAlight") unittest {
    // damage 1 against armour 0, plus 3 per step for 4 steps: the burn does most of the work
    auto setup = corridorSetup([TowerKind("torch", 10, 3, 1, 8, 30, Primitive.burn, 0, 4, 0, 3)],
            [StructureSpec(1, 0, 4, 0)], [WaveSpec(0, 0, 1, 1, 0)], []);
    Battle b;
    assert(b.begin(setup).ok());
    int moments;
    assert(runToEnd(b, moments) == StepResult.won);
    assert(b.kills == 1 && b.leaks == 0);
    writeln("  [PASS] testBurnTowerSetsEnemiesAlight");
}

@("testAuraRaisesDamageOfNeighbours") unittest {
    auto towers = [boltKind(), supportKind(Primitive.aura, 100, 3)];
    towers[1].buildable = true;
    auto plain = corridorSetup(towers, [StructureSpec(1, 0, 6, 0)], [WaveSpec(0, 0, 4, 3, 0)], []);
    auto boosted = plain;
    boosted.structures = [StructureSpec(1, 0, 6, 0), StructureSpec(2, 1, 7, 0)];
    Battle a, b;
    assert(a.begin(plain).ok() && b.begin(boosted).ok());
    int moments;
    runToEnd(a, moments);
    runToEnd(b, moments);
    // the aura doubled the bolt's damage, so the battle ends sooner and the aura is on the bolt
    assert(b.sAura[0] == 100 && a.sAura[0] == 0);
    assert(b.stepIndex < a.stepIndex);
    writeln("  [PASS] testAuraRaisesDamageOfNeighbours");
}

@("testSummonerCallsItsKind") unittest {
    auto setup = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 1, 1, 0)], []);
    setup.enemies = [
        EnemyKind("wraith", 60, 64, 0, 5, 1, 0, 1, 6, 3),
        EnemyKind("dimling", 12, 128, 0, 2, 1),
    ];
    Battle b;
    assert(b.begin(setup).ok());
    foreach (_; 0 .. 40)
        b.step();
    // one wraith and its three dimlings, none killed (there are no towers)
    assert(b.enemiesAlive() + b.leaks == 4, "the summoner did not call three");
    assert(b.nextEnemyId == 4);
    writeln("  [PASS] testSummonerCallsItsKind");
}

@("testHeroObedienceIsDeterministicAndHonoured") unittest {
    auto towers = [boltKind()];
    // a wave far in the future keeps the battle running while the heroes walk
    auto setup = corridorSetup(towers, [], [WaveSpec(0, 0, 1, 1, 5000)], []);
    setup.heroes = [
        HeroSpec(100, 0, 2, 0, 20, -1, -1, 0), HeroSpec(101, 0, 5, 0, 20, -1, -1, 100)
    ];
    Battle b;
    assert(b.begin(setup).ok());
    string why;
    // the first hero obeys never; the second always
    assert(b.command(cmd(CommandKind.moveHero, 100, 3, 0), why));
    assert(b.command(cmd(CommandKind.moveHero, 101, 7, 0), why));
    foreach (_; 0 .. 40)
        b.step();
    assert(b.sTile[slotOfId(b, 100)] == 2, "an order was obeyed at obedience 0");
    assert(b.sTile[slotOfId(b, 101)] == 7, "the hero did not walk to its tile");
    assert(b.rngDraws == 1, "only the unsure hero draws");
    // the same commands again give the same battle
    Battle again;
    assert(again.begin(setup).ok());
    foreach (c; b.log)
        assert(again.command(c, why));
    foreach (_; 0 .. 40)
        again.step();
    assert(again.digest() == b.digest());
    writeln("  [PASS] testHeroObedienceIsDeterministicAndHonoured");
}

@("testTauntHoldsEnemiesAndRepairHeals") unittest {
    auto towers = [
        boltKind(), supportKind(Primitive.taunt, 0, 4, 30), supportKind(Primitive.repair, 6, 3)
    ];
    towers[1].radius = 7;
    auto setup = corridorSetup(towers, [StructureSpec(1, 0, 13, 0)], [WaveSpec(0, 1, 2, 2, 0)], []);
    setup.heroes = [
        HeroSpec(100, 0, 7, 0, 40, 1, -1, 100), HeroSpec(101, 0, 10, 0, 40, 2, -1, 100)
    ];
    Battle b;
    assert(b.begin(setup).ok());
    string why;
    assert(b.command(cmd(CommandKind.useAbility, 100, -1, -1), why), why);
    assert(!b.command(cmd(CommandKind.useAbility, 100, -1, -1), why));
    assert(why == "the ability is not ready");
    // nothing needs repair yet
    assert(!b.command(cmd(CommandKind.useAbility, 101, -1, -1), why));
    assert(why == "nothing nearby needs repair");
    foreach (_; 0 .. 150)
        b.step();
    // the husks that came within the taunt were held by the hero, who is hurt
    immutable hero = slotOfId(b, 100);
    assert(b.sHp[hero] < 40 || !b.sAlive[hero]);
    writeln("  [PASS] testTauntHoldsEnemiesAndRepairHeals");
}

@("testModifierCommandsAndWithdrawal") unittest {
    auto setup = corridorSetup([boltKind()], [StructureSpec(1, 0, 6, 0)], [WaveSpec(0, 0, 8, 3, 0)], [
    ]);
    setup.heroes = [HeroSpec(100, 0, 9, 0, 30), HeroSpec(101, 0, 11, 0, 30)];
    Battle b;
    assert(b.begin(setup).ok());
    string why;
    assert(b.command(cmd(CommandKind.global, 0, 0, 0, 25, 50), why));
    assert(b.command(cmd(CommandKind.heroMod, 100, 0, 0, 1, 10, 5, 0), why));
    assert(b.command(cmd(CommandKind.bondAdd, 100, 0, 0, 101, 3, 20), why));
    assert(!b.command(cmd(CommandKind.bondAdd, 100, 0, 0, 999, 3, 20), why));
    assert(b.bondCount == 1 && b.globalDamage == 25 && b.globalBounty == 50);
    assert(b.sModDamage[slotOfId(b, 100)] == 10);
    // an ally appears next to a tile; the Lantern heals; a hero takes damage and may go down
    assert(b.command(cmd(CommandKind.reinforce, 0, 5, 0), why), why);
    assert(b.structureCount == 4);
    foreach (_; 0 .. 30)
        b.step();
    immutable beforeLeaks = b.leaks;
    assert(b.command(cmd(CommandKind.heal, 0, 0, 0, 0, 0, 1), why));
    assert(b.leaks == (beforeLeaks > 0 ? beforeLeaks - 1 : 0));
    assert(b.command(cmd(CommandKind.damage, 101, 0, 0, 99), why));
    assert(b.sDowned[slotOfId(b, 101)] && !b.sAlive[slotOfId(b, 101)]);
    // healing a downed hero stands it up again
    assert(b.command(cmd(CommandKind.heal, 101, 0, 0, 1, 0, 12), why));
    assert(b.sAlive[slotOfId(b, 101)] && b.sHp[slotOfId(b, 101)] == 12);
    assert(b.command(cmd(CommandKind.end), why));
    assert(b.step() == StepResult.withdrawn);
    assert(b.outcome == Outcome.withdrawn);
    assert(!b.command(cmd(CommandKind.global), why));
    writeln("  [PASS] testModifierCommandsAndWithdrawal");
}

@("testHeroesNearAndEnemyKindSeenTriggers") unittest {
    MomentSpec[] moments = [
        MomentSpec(1, Trigger.heroesNear, 100, "together", true, 101, 3),
        MomentSpec(2, Trigger.enemyKindSeen, 1, "husks"),
    ];
    auto setup = corridorSetup([boltKind()], [], [WaveSpec(0, 0, 1, 1, 0), WaveSpec(0, 1, 1, 1, 20)], moments);
    setup.heroes = [HeroSpec(100, 0, 2, 0, 30), HeroSpec(101, 0, 12, 0, 30)];
    Battle b;
    assert(b.begin(setup).ok());
    // heroes ten tiles apart: no moment yet
    foreach (_; 0 .. 3)
        assert(b.step() != StepResult.moment);
    string why;
    assert(b.command(cmd(CommandKind.order, 101, 2, 0, 1), why));
    bool together = false, husks = false;
    foreach (_; 0 .. 200) {
        immutable r = b.step();
        if (r == StepResult.moment) {
            if (setup.moments[b.firedMoment].scene == "together")
                together = true;
            if (setup.moments[b.firedMoment].scene == "husks")
                husks = true;
        } else if (r != StepResult.running) {
            break;
        }
    }
    assert(together && husks);
    // hero_downed asks for known heroes; enemy_kind_seen needs a known kind
    setup.moments = [MomentSpec(1, Trigger.enemyKindSeen, 5, "nowhere")];
    Battle c;
    assert(c.begin(setup).field == "moments.arg");
    writeln("  [PASS] testHeroesNearAndEnemyKindSeenTriggers");
}

@("testRepairCommandCostsCredits") unittest {
    auto setup = corridorSetup([boltKind()], [StructureSpec(1, 0, 3, 0)], [], []);
    Battle b;
    assert(b.begin(setup).ok());
    string why;
    assert(!b.command(cmd(CommandKind.repair, 1), why));
    assert(why == "it is not damaged");
    b.sHp[0] = 10;
    immutable credits = b.credits;
    assert(b.command(cmd(CommandKind.repair, 1), why));
    assert(b.sHp[0] == 30 && b.credits == credits - 10);
    writeln("  [PASS] testRepairCommandCostsCredits");
}

// ---- allocation and time (TD2 exit test; plan §9 budgets) ---------------------------------------

/// A big busy battle on a 64 x 9 field: towers off the central lane, thousands of enemies.
BattleSetup busySetup(int towerCount, int enemies) {
    auto towers = [
        boltKind(), supportKind(Primitive.aura, 25, 3), supportKind(Primitive.shield, 10, 3),
        TowerKind("torch", 10, 3, 1, 8, 30, Primitive.burn, 0, 4, 0, 3)
    ];
    StructureSpec[] structures;
    foreach (i; 0 .. towerCount) {
        immutable row = i % 8 < 4 ? i % 4 : 5 + i % 4; // rows 0-3 and 5-8, never the lane
        structures ~= StructureSpec(i + 1, i % 4, 2 + (i / 8) * 3, row);
    }
    TileEdit[] edits;
    foreach (q; 0 .. 64)
        foreach (r; 0 .. 9)
            edits ~= TileEdit(q, r, false);
    BattleSetup setup;
    setup.seed = 7;
    setup.width = 64;
    setup.height = 9;
    setup.mapSeed = 1;
    setup.edits = edits;
    setup.wallThreshold = 0;
    setup.revealedSectors = [0, 1, 2, 3];
    setup.sinks = [[63, 4]];
    setup.sources = [SourceSpec(0, 4, 0)];
    setup.structures = structures;
    setup.towers = towers;
    setup.enemies = [
        EnemyKind("dimling", 400, 512, 0, 2, 1),
        EnemyKind("wraith", 600, 256, 0, 6, 1, 50, 0, 20, 2, 5, 5, 10),
    ];
    setup.waves = [WaveSpec(0, 0, enemies, 1, 0), WaveSpec(0, 1, enemies / 4, 3, 5)];
    setup.credits = 0;
    setup.maxLeaks = 100_000;
    setup.momentCap = 0;
    setup.structureRoom = 0;
    return setup;
}

@("testStepAllocatesNothing") unittest {
    auto setup = busySetup(30, 600);
    Battle b;
    assert(b.begin(setup).ok());
    foreach (_; 0 .. 50)
        b.step(); // warm up: first cues, buckets
    immutable before = GC.stats().usedSize;
    immutable allocated = GC.stats().allocatedInCurrentThread;
    foreach (_; 0 .. 400)
        b.step();
    immutable after = GC.stats().allocatedInCurrentThread;
    assert(after == allocated, "the step allocated memory");
    assert(b.enemiesAlive() > 0 || b.kills > 0);
    writeln("  [PASS] testStepAllocatesNothing");
}

@("testStepTimeIsBoundedAtScale") unittest {
    // the sample's scale: a few hundred enemies; and the stress scale: thousands
    foreach (counts; [[40, 300], [60, 4000]]) {
        auto setup = busySetup(counts[0], counts[1]);
        Battle b;
        assert(b.begin(setup).ok());
        auto watch = StopWatch(AutoStart.yes);
        long worst = 0;
        foreach (_; 0 .. 300) {
            auto one = StopWatch(AutoStart.yes);
            b.step();
            immutable usecs = one.peek().total!"usecs";
            if (usecs > worst)
                worst = usecs;
        }
        // a debug build with bounds checks: generous, but a regression to O(n^2) would show
        assert(worst < 50_000, "a step took too long");
    }
    writeln("  [PASS] testStepTimeIsBoundedAtScale");
}

// ---- the game host's battle bridge (TD3) -----------------------------------------------------

@("testGameHostRunsANightFromTheHub") unittest {
    import varis.services.gamehost : GameHost, BattlePhase;

    auto host = new GameHost;
    assert(host.loadProject("sample-td", ""), host.error);
    assert(host.newGame(1), host.error);
    // the prologue, then the hub
    foreach (_; 0 .. 100) {
        if (!host.view.inScene)
            break;
        assert(host.advance(), host.error);
    }
    assert(!host.view.inScene && host.battlePhase == BattlePhase.none);
    // "Go up to the terraces" asks for the battle: the host builds its setup and waits for builds
    size_t story, choice;
    bool found;
    foreach (i, st; host.view.stories)
        if (st.id == "go_up") {
            story = i;
            choice = 0;
            found = true;
        }
    assert(found);
    string beforeBytes;
    assert(host.save(beforeBytes));
    assert(host.choose(story, choice), host.error);
    assert(host.battlePhase == BattlePhase.build);
    assert(host.battle !is null && host.battle.battle.stepIndex == 0);
    // a save is refused while the battle is on, and the autosave is the world at its start
    string bytes;
    assert(!host.save(bytes));
    assert(host.autosaveBytes(bytes) && bytes.length > 0);
    // build: a refused command says why
    Command c;
    c.action = CommandKind.place;
    c.towerKind = 0;
    c.q = 40;
    c.r = 20;
    string reason;
    assert(host.battleCommand(c, reason), reason);
    c.q = 16;
    c.r = 13; // a cliff
    assert(!host.battleCommand(c, reason) && reason.length > 0);
    // night: moments play their scene through the same session; the player acknowledges them
    assert(host.battleBegin(), host.error);
    int moments;
    StepResult last;
    foreach (_; 0 .. 5000) {
        last = host.battleAdvance(25);
        if (last == StepResult.moment) {
            ++moments;
            // acknowledge the scene until the story is idle again, taking the first menu answer
            foreach (_2; 0 .. 100) {
                if (!host.view.inScene)
                    break;
                if (host.view.beat.kind == "menu")
                    assert(host.advance(host.view.beat.choices[0].id), host.error);
                else
                    assert(host.advance(), host.error);
            }
            assert(!host.view.inScene && host.battlePhase == BattlePhase.night);
        }
        if (host.battlePhase == BattlePhase.ended)
            break;
    }
    assert(host.battlePhase == BattlePhase.ended && moments >= 1);
    assert(last == StepResult.won);
    assert(host.battleAccept(), host.error);
    assert(host.battlePhase == BattlePhase.none);
    // the dawn report is in the hub now
    bool dawn;
    foreach (st; host.view.stories)
        dawn = dawn || st.id == "report";
    assert(dawn, "the dawn report is shown");
    // an abandoned battle returns to the hub exactly as it was before the choice
    assert(host.restore(beforeBytes), host.error);
    foreach (i, st; host.view.stories)
        if (st.id == "go_up")
            story = i;
    assert(host.choose(story, 0) && host.battlePhase == BattlePhase.build);
    assert(host.battleAbandon(), host.error);
    // presenting again records a presentation in the replay log, so the bytes are not compared
    // here (the Lua tests compare an abandoned snapshot byte for byte); the hub is back
    assert(host.battlePhase == BattlePhase.none && !host.view.inScene);
    bool goUp;
    foreach (st; host.view.stories)
        goUp = goUp || st.id == "go_up";
    assert(goUp, "an abandoned battle returns to the hub before the choice");
    writeln("  [PASS] testGameHostRunsANightFromTheHub");
}

@("testStressScaleBoundedStep") unittest {
    // the largest map (880 x 495 tiles, 435,600) and 10,000 enemies: the plan's stress setup
    enum width = 880, height = 495;
    BattleSetup setup;
    setup.seed = 3;
    setup.width = width;
    setup.height = height;
    setup.mapSeed = 5;
    setup.wallThreshold = 20;
    int[] sectors;
    foreach (i; 0 .. fogSectorCount(width, height))
        sectors ~= i;
    setup.revealedSectors = sectors;
    setup.sinks = [[width - 2, height - 2]];
    setup.sources = [SourceSpec(1, 1, 0)];
    TileEdit[] corridor;
    foreach (i; 0 .. 4)
        corridor ~= TileEdit(1 + i, 1, false);
    corridor ~= TileEdit(width - 2, height - 2, false);
    // open the source and sink tiles and a clear lane along the first row and the last column
    foreach (q; 0 .. width)
        corridor ~= TileEdit(q, 1, false);
    foreach (r; 1 .. height - 1)
        corridor ~= TileEdit(width - 2, r, false);
    foreach (q; 0 .. 620)
        corridor ~= TileEdit(q, 2, false);
    setup.edits = corridor;
    setup.towers = [boltKind()];
    StructureSpec[] towers;
    foreach (i; 0 .. 600)
        towers ~= StructureSpec(i + 1, 0, 2 + i, 2);
    setup.structures = towers;
    setup.enemies = [EnemyKind("dimling", 20, 512, 0, 1, 1)];
    setup.waves = [WaveSpec(0, 0, 10_000, 1, 0)];
    setup.credits = 0;
    setup.maxLeaks = 100_000;
    setup.structureRoom = 0;
    Battle b;
    immutable problem = b.begin(setup);
    assert(problem.ok(), problem.message);
    auto watch = StopWatch(AutoStart.yes);
    long worst;
    foreach (_; 0 .. 120) {
        auto one = StopWatch(AutoStart.yes);
        b.step();
        immutable usecs = one.peek().total!"usecs";
        if (usecs > worst)
            worst = usecs;
    }
    assert(b.nextEnemyId >= 100 && b.kills > 0);
    assert(worst < 200_000, "a stress step took too long");
    writeln("  [PASS] testStressScaleBoundedStep");
}

mixin UnitMain;

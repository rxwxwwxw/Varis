/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The battle bridge and the `battle` library (TOWER_DEFENSE_PLAN.md §5, TD3): converts the Lua tables that project hooks
/// return into the simulation's structs, validates them with field-named problems, runs the
/// battle to its next boundary and turns the outcome back into a table for `battle_result`.
///
/// Lua indices are 1-based, as in every Lua array; the simulation is 0-based. The converter
/// does the one conversion, so a content author writes `kind = 1` for the first tower kind.
module varis.lib.battle;

import varis.state;
import varis.table;
import varis.types;
import varis.game.battle;
import varis.game.kinds;
import varis.game.terrain : TileEdit;
import varis.game.types;

private LuaValue member(LuaValue table, string key) {
    return table.isTable() ? table.asTable().rawget(LuaValue(key)) : LuaValue.init;
}

/// The elements `1 .. n` of a Lua array; empty for a non-table or a missing array.
private LuaValue[] elements(LuaValue table) {
    LuaValue[] items;
    if (!table.isTable())
        return items;
    auto t = table.asTable();
    for (long i = 1;; ++i) {
        immutable v = t.rawgetInt(i);
        if (v.isNil())
            break;
        items ~= v;
    }
    return items;
}

private bool integer(LuaValue table, string key, ref int value) {
    immutable v = member(table, key);
    if (!v.isInteger())
        return false;
    value = cast(int) v.asInteger();
    return true;
}

/// Reads an optional integer; keeps `value` when the field is absent.
private bool optionalInteger(LuaValue table, string key, ref int value) {
    immutable v = member(table, key);
    if (v.isNil())
        return true;
    return integer(table, key, value);
}

/// Text of a Lua string or symbol; empty for anything else.
private string text(LuaValue v) {
    if (v.isString())
        return v.asString();
    if (v.isSymbol())
        return v.asSymbol().name;
    return "";
}

private Problem bad(string field, int index, string message) {
    return Problem(field, index, message);
}

private bool parsePrimitive(string name, out Primitive primitive) {
    switch (name) {
    case "single":
        primitive = Primitive.singleTarget;
        return true;
    case "splash":
        primitive = Primitive.splash;
        return true;
    case "slow":
        primitive = Primitive.slow;
        return true;
    case "chain":
        primitive = Primitive.chain;
        return true;
    case "burn":
        primitive = Primitive.burn;
        return true;
    case "aura":
        primitive = Primitive.aura;
        return true;
    case "shield":
        primitive = Primitive.shield;
        return true;
    case "summon":
        primitive = Primitive.summon;
        return true;
    case "repair":
        primitive = Primitive.repair;
        return true;
    case "taunt":
        primitive = Primitive.taunt;
        return true;
    default:
        return false;
    }
}

private bool parseTrigger(string name, out Trigger trigger) {
    switch (name) {
    case "step":
        trigger = Trigger.step;
        return true;
    case "wave_start":
        trigger = Trigger.waveStart;
        return true;
    case "structure_destroyed":
        trigger = Trigger.structureDestroyed;
        return true;
    case "leak_count":
        trigger = Trigger.leakCount;
        return true;
    case "battle_won":
        trigger = Trigger.battleWon;
        return true;
    case "hero_downed":
        trigger = Trigger.heroDowned;
        return true;
    case "hero_hp_below":
        trigger = Trigger.heroHpBelow;
        return true;
    case "battle_lost":
        trigger = Trigger.battleLost;
        return true;
    case "heroes_near":
        trigger = Trigger.heroesNear;
        return true;
    case "enemy_kind_seen":
        trigger = Trigger.enemyKindSeen;
        return true;
    default:
        return false;
    }
}

/// Reads a Lua battle setup. Returns the first problem found, naming the field; the setup is then
/// not usable. Checks that need the map (walls, reachability) are left to `Battle.validate`.
Problem readSetup(LuaValue value, out BattleSetup s) {
    if (!value.isTable())
        return bad("setup", -1, "the battle setup must be a table");
    long seed = 0;
    immutable seedValue = member(value, "seed");
    if (seedValue.isInteger())
        seed = seedValue.asInteger();
    s.seed = cast(ulong) seed;
    long mapSeed = 0;
    immutable mapSeedValue = member(value, "map_seed");
    if (mapSeedValue.isInteger())
        mapSeed = mapSeedValue.asInteger();
    s.mapSeed = cast(ulong) mapSeed;
    if (!integer(value, "width", s.width) || !integer(value, "height", s.height))
        return bad("setup.width, setup.height", -1, "width and height are required integers");
    if (!integer(value, "credits", s.credits))
        return bad("setup.credits", -1, "credits is required");
    if (!integer(value, "max_leaks", s.maxLeaks))
        return bad("setup.max_leaks", -1, "max_leaks is required");
    if (!optionalInteger(value, "moment_cap", s.momentCap) || !optionalInteger(value, "structure_room", s.structureRoom))
        return bad("setup.moment_cap, setup.structure_room", -1, "must be integers");
    int density = -1;
    if (!optionalInteger(value, "wall_density", density) || density > 100)
        return bad("setup.wall_density", -1, "wall_density is a percentage from 0 to 100");
    if (density >= 0)
        s.wallThreshold = density * 256 / 100;
    if (!optionalInteger(value, "terrace_rows", s.terraceRows) || s.terraceRows < 0)
        return bad("setup.terrace_rows", -1, "terrace_rows is a count of rows, 0 or more");
    if (!optionalInteger(value, "attack_every", s.attackEvery))
        return bad("setup.attack_every", -1, "attack_every must be an integer");
    if (!optionalInteger(value, "first_structure_id", s.firstStructureId))
        return bad("setup.first_structure_id", -1, "first_structure_id must be an integer");

    TileEdit[] edits;
    foreach (i, e; elements(member(value, "edits"))) {
        TileEdit edit;
        if (!integer(e, "q", edit.q) || !integer(e, "r", edit.r))
            return bad("setup.edits", cast(int) i, "an edit needs integer q and r");
        immutable wall = member(e, "wall");
        edit.wall = wall.isBoolean() && wall.asBool();
        edits ~= edit;
    }
    s.edits = edits;

    int[] sectors;
    foreach (i, v; elements(member(value, "revealed"))) {
        if (!v.isInteger())
            return bad("setup.revealed", cast(int) i, "a revealed sector is an integer, counted from 1");
        sectors ~= cast(int) v.asInteger() - 1;
    }
    s.revealedSectors = sectors;

    int[2][] sinks;
    foreach (i, sink; elements(member(value, "sinks"))) {
        int q, r;
        if (!integer(sink, "q", q) || !integer(sink, "r", r))
            return bad("setup.sinks", cast(int) i, "a sink needs integer q and r");
        sinks ~= [q, r];
    }
    s.sinks = sinks;

    SourceSpec[] sources;
    foreach (i, src; elements(member(value, "sources"))) {
        SourceSpec spec;
        int sink;
        if (!integer(src, "q", spec.q) || !integer(src, "r", spec.r) || !integer(src, "sink", sink))
            return bad("setup.sources", cast(int) i, "a source needs integer q, r and sink");
        spec.sink = sink - 1;
        sources ~= spec;
    }
    s.sources = sources;

    StructureSpec[] structures;
    foreach (i, st; elements(member(value, "structures"))) {
        StructureSpec spec;
        int kind;
        if (!integer(st, "id", spec.id) || !integer(st, "kind", kind) || !integer(st, "q", spec.q) || !integer(st, "r", spec
                .r))
            return bad("setup.structures", cast(int) i, "a structure needs integer id, kind, q and r");
        spec.kind = kind - 1;
        if (!optionalInteger(st, "level", spec.level) || !optionalInteger(st, "hp", spec.hp))
            return bad("setup.structures", cast(int) i, "level and hp must be integers");
        structures ~= spec;
    }
    s.structures = structures;

    HeroSpec[] heroes;
    foreach (i, h; elements(member(value, "heroes"))) {
        HeroSpec spec;
        int kind;
        if (!integer(h, "id", spec.id) || !integer(h, "kind", kind) || !integer(h, "q", spec.q)
                || !integer(h, "r", spec.r) || !integer(h, "hp", spec.hp))
            return bad("setup.heroes", cast(int) i, "a hero needs integer id, kind, q, r and hp");
        spec.kind = kind - 1;
        int ability, passive;
        if (!optionalInteger(h, "ability", ability) || !optionalInteger(h, "passive", passive)
                || !optionalInteger(h, "obedience", spec.obedience))
            return bad("setup.heroes", cast(int) i, "ability, passive and obedience must be integers");
        spec.ability = ability - 1;
        spec.passive = passive - 1;
        heroes ~= spec;
    }
    s.heroes = heroes;

    WaveSpec[] waves;
    foreach (i, w; elements(member(value, "waves"))) {
        WaveSpec spec;
        int source, kind;
        spec.every = 1;
        if (!integer(w, "source", source) || !integer(w, "kind", kind) || !integer(w, "count", spec.count))
            return bad("setup.waves", cast(int) i, "a wave needs integer source, kind and count");
        if (!optionalInteger(w, "every", spec.every) || !optionalInteger(w, "start", spec.start))
            return bad("setup.waves", cast(int) i, "every and start must be integers");
        spec.source = source - 1;
        spec.kind = kind - 1;
        waves ~= spec;
    }
    s.waves = waves;

    MomentSpec[] moments;
    foreach (i, m; elements(member(value, "moments"))) {
        MomentSpec spec;
        if (!integer(m, "id", spec.id))
            return bad("setup.moments", cast(int) i, "a moment needs an integer id");
        if (!parseTrigger(text(member(m, "trigger")), spec.trigger))
            return bad("setup.moments.trigger", cast(int) i, "unknown trigger");
        if (!optionalInteger(m, "arg", spec.arg) || !optionalInteger(m, "arg2", spec.arg2)
                || !optionalInteger(m, "arg3", spec.arg3))
            return bad("setup.moments.arg", cast(int) i, "arg, arg2 and arg3 must be integers");
        // enemy kinds are 1-based in Lua, as everywhere else
        if (spec.trigger == Trigger.enemyKindSeen)
            --spec.arg;
        spec.scene = text(member(m, "scene"));
        moments ~= spec;
    }
    s.moments = moments;

    TowerKind[] towers;
    foreach (i, t; elements(member(value, "towers"))) {
        TowerKind kind;
        kind.name = text(member(t, "name"));
        if (!integer(t, "cost", kind.cost) || !integer(t, "range", kind.range) || !integer(t, "damage", kind.damage)
                || !integer(t, "cooldown", kind.cooldown) || !integer(t, "hp", kind.hp))
            return bad("setup.towers", cast(int) i, "a tower needs integer cost, range, damage, cooldown and hp");
        if (!parsePrimitive(text(member(t, "ability")), kind.primitive))
            return bad("setup.towers.ability", cast(int) i, "unknown ability");
        if (!optionalInteger(t, "radius", kind.radius) || !optionalInteger(t, "duration", kind.duration)
                || !optionalInteger(t, "jumps", kind.jumps) || !optionalInteger(t, "power", kind.power)
                || !optionalInteger(t, "reveal", kind.reveal))
            return bad("setup.towers", cast(int) i, "radius, duration, jumps, power and reveal must be integers");
        immutable buildable = member(t, "buildable");
        if (buildable.isBoolean())
            kind.buildable = buildable.asBool();
        towers ~= kind;
    }
    s.towers = towers;

    EnemyKind[] enemies;
    foreach (i, e; elements(member(value, "enemies"))) {
        EnemyKind kind;
        kind.name = text(member(e, "name"));
        if (!integer(e, "hp", kind.hp) || !integer(e, "speed", kind.speed))
            return bad("setup.enemies", cast(int) i, "an enemy needs integer hp and speed");
        if (!optionalInteger(e, "armour", kind.armour) || !optionalInteger(e, "bounty", kind.bounty)
                || !optionalInteger(e, "structure_damage", kind.structureDamage)
                || !optionalInteger(e, "shield", kind.shield) || !optionalInteger(e, "summon_every", kind.summonEvery)
                || !optionalInteger(e, "summon_cap", kind.summonCap) || !optionalInteger(e, "burn_radius", kind.burnRadius)
                || !optionalInteger(e, "burn_power", kind.burnPower) || !optionalInteger(e, "burn_every", kind
                    .burnEvery))
            return bad("setup.enemies", cast(int) i, "armour, bounty, structure_damage, shield, summon_* and burn_* must be integers");
        int summon = 0;
        if (!optionalInteger(e, "summon", summon))
            return bad("setup.enemies.summon", cast(int) i, "summon names an enemy kind by number");
        kind.summonKind = summon - 1;
        enemies ~= kind;
    }
    s.enemies = enemies;
    return Problem.init;
}

/// The outcome of a battle as the table `battle_result` receives (plan §5.2).
LuaValue outcomeTable(const Battle b) {
    auto result = new LuaTable();
    final switch (b.outcome) {
    case Outcome.running:
        result.rawset(LuaValue("result"), LuaValue("running"));
        break;
    case Outcome.won:
        result.rawset(LuaValue("result"), LuaValue("won"));
        break;
    case Outcome.lost:
        result.rawset(LuaValue("result"), LuaValue("lost"));
        break;
    case Outcome.withdrawn:
        result.rawset(LuaValue("result"), LuaValue("withdrawn"));
        break;
    }
    result.rawset(LuaValue("steps"), LuaValue(cast(long) b.stepIndex));
    result.rawset(LuaValue("kills"), LuaValue(cast(long) b.kills));
    result.rawset(LuaValue("leaks"), LuaValue(cast(long) b.leaks));
    result.rawset(LuaValue("credits"), LuaValue(cast(long) b.credits));
    result.rawset(LuaValue("digest"), LuaValue(cast(long) b.digest()));
    auto structures = new LuaTable();
    foreach (s; 0 .. b.structureCount) {
        if (b.sIsHero[s])
            continue;
        auto row = new LuaTable();
        row.rawset(LuaValue("id"), LuaValue(cast(long) b.sId[s]));
        row.rawset(LuaValue("kind"), LuaValue(cast(long)(b.sKind[s] + 1)));
        row.rawset(LuaValue("q"), LuaValue(cast(long)(b.sTile[s] % b.width)));
        row.rawset(LuaValue("r"), LuaValue(cast(long)(b.sTile[s] / b.width)));
        row.rawset(LuaValue("hp"), LuaValue(cast(long) b.sHp[s]));
        row.rawset(LuaValue("level"), LuaValue(cast(long) b.sLevel[s]));
        row.rawset(LuaValue("sold"), LuaValue(b.sSold[s]));
        row.rawset(LuaValue("destroyed"), LuaValue(!b.sAlive[s] && !b.sSold[s]));
        structures.rawset(LuaValue(cast(long)(s + 1)), LuaValue(row));
    }
    result.rawset(LuaValue("structures"), LuaValue(structures));
    auto sinkLeaks = new LuaTable();
    foreach (i, n; b.leaksPerSink)
        sinkLeaks.rawset(LuaValue(cast(long)(i + 1)), LuaValue(cast(long) n));
    result.rawset(LuaValue("sink_leaks"), LuaValue(sinkLeaks));
    auto seen = new LuaTable();
    long seenCount = 0;
    foreach (i, was; b.kindSeen)
        if (was)
            seen.rawset(LuaValue(++seenCount), LuaValue(cast(long)(i + 1)));
    result.rawset(LuaValue("seen"), LuaValue(seen));
    auto opened = new LuaTable();
    foreach (i; 0 .. b.fog.sectorCount())
        opened.rawset(LuaValue(cast(long)(i + 1)), LuaValue(b.fog.revealed[i] != 0));
    result.rawset(LuaValue("revealed"), LuaValue(opened));
    auto heroes = new LuaTable();
    long heroRow = 0;
    foreach (s; 0 .. b.structureCount) {
        if (!b.sIsHero[s])
            continue;
        auto row = new LuaTable();
        row.rawset(LuaValue("id"), LuaValue(cast(long) b.sId[s]));
        row.rawset(LuaValue("hp"), LuaValue(cast(long) b.sHp[s]));
        row.rawset(LuaValue("downed"), LuaValue(b.sDowned[s]));
        heroes.rawset(LuaValue(++heroRow), LuaValue(row));
    }
    result.rawset(LuaValue("heroes"), LuaValue(heroes));
    return LuaValue(result);
}

/// Runs one battle at a time. The host calls `start`, then `pump` until it returns a moment (play
/// the scene named by `momentScene`, then pump again) or an ending.
class BattleHost {
    Battle battle;
    bool active;
    /// Host state that never enters the simulation: the view's speed multiplier and pause.
    int speed = 1;
    bool paused;

    /// Reads and starts a battle from a Lua setup table. A refused setup starts nothing.
    Problem start(LuaValue table) {
        BattleSetup s;
        auto problem = readSetup(table, s);
        if (!problem.ok())
            return problem;
        problem = battle.begin(s);
        active = problem.ok();
        return problem;
    }

    /// Steps until a moment fires, the battle ends, or `limit` steps have run.
    StepResult pump(int limit) {
        foreach (_; 0 .. limit) {
            immutable result = battle.step();
            if (result != StepResult.running) {
                if (result == StepResult.won || result == StepResult.lost || result == StepResult.withdrawn)
                    active = false;
                return result;
            }
        }
        return StepResult.running;
    }

    /// The scene of the moment that paused the battle; empty when none did.
    string momentScene() const {
        if (battle.firedMoment < 0)
            return "";
        return battle.setup.moments[battle.firedMoment].scene;
    }
}

private LuaValue argument(LuaValue[] args, size_t index) {
    return index < args.length ? args[index] : LuaValue.init;
}

private LuaValue stepName(StepResult result) {
    final switch (result) {
    case StepResult.running:
        return LuaValue("running");
    case StepResult.moment:
        return LuaValue("moment");
    case StepResult.won:
        return LuaValue("won");
    case StepResult.lost:
        return LuaValue("lost");
    case StepResult.withdrawn:
        return LuaValue("withdrawn");
    }
}

/// The handle `battle.new` returns: a table of methods over one BattleHost. Methods take the
/// handle as `self`, as in `h:pump(50)`; tower kinds and sectors are 1-based, as in readSetup.
private LuaValue handleFor(BattleHost host) {
    auto handle = new LuaTable();
    void method(string name, LuaValue[]delegate(LuaValue[] args) call) {
        handle.rawset(LuaValue(name), LuaValue(new LuaNativeFunction((void* ignored, LuaValue[] args) {
                    return call(args);
                }, name)));
    }

    method("pump", (LuaValue[] args) {
        immutable limit = argument(args, 1);
        if (host.paused)
            return [LuaValue("paused")];
        return [stepName(host.pump(limit.isInteger() ? cast(int) limit.asInteger() : 1000))];
    });
    method("moment", (LuaValue[] args) {
        if (host.battle.firedMoment < 0)
            return [LuaValue.init];
        immutable m = host.battle.setup.moments[host.battle.firedMoment];
        auto t = new LuaTable();
        t.rawset(LuaValue("id"), LuaValue(cast(long) m.id));
        t.rawset(LuaValue("scene"), LuaValue(m.scene));
        t.rawset(LuaValue("trigger"), LuaValue(triggerName(m.trigger)));
        return [LuaValue(t)];
    });
    method("set_speed", (LuaValue[] args) {
        immutable n = argument(args, 1);
        if (!n.isInteger() || n.asInteger() < 1 || n.asInteger() > 8)
            return [LuaValue(false), LuaValue("speed is 1 to 8")];
        host.speed = cast(int) n.asInteger();
        return [LuaValue(true)];
    });
    method("speed", (LuaValue[] args) { return [LuaValue(cast(long) host.speed)]; });
    method("pause", (LuaValue[] args) {
        immutable on = argument(args, 1);
        host.paused = on.isNil() ? !host.paused : on.isTruthy();
        return [LuaValue(host.paused)];
    });
    method("paused", (LuaValue[] args) { return [LuaValue(host.paused)]; });
    method("move_hero", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.moveHero;
        immutable id = argument(args, 1), q = argument(args, 2), r = argument(args, 3);
        if (!id.isInteger() || !q.isInteger() || !r.isInteger())
            return [LuaValue(false), LuaValue("move_hero(id, q, r) needs integers")];
        c.target = cast(int) id.asInteger();
        c.q = cast(int) q.asInteger();
        c.r = cast(int) r.asInteger();
        return commandResult(host, c);
    });
    method("use_ability", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.useAbility;
        immutable id = argument(args, 1), q = argument(args, 2), r = argument(args, 3);
        if (!id.isInteger())
            return [LuaValue(false), LuaValue("use_ability(id [, q, r]) needs an integer id")];
        c.target = cast(int) id.asInteger();
        c.q = q.isInteger() ? cast(int) q.asInteger() : -1;
        c.r = r.isInteger() ? cast(int) r.asInteger() : -1;
        return commandResult(host, c);
    });
    method("repair", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.repair;
        immutable id = argument(args, 1);
        if (!id.isInteger())
            return [LuaValue(false), LuaValue("repair(id) needs an integer")];
        c.target = cast(int) id.asInteger();
        return commandResult(host, c);
    });
    method("sync", (LuaValue[] args) { return syncMods(host, argument(args, 1)); });
    method("set_hp", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.setHp;
        immutable id = argument(args, 1), hp = argument(args, 2);
        if (!id.isInteger() || !hp.isInteger())
            return [LuaValue(false), LuaValue("set_hp(id, hp) needs integers")];
        c.target = cast(int) id.asInteger();
        c.a = cast(int) hp.asInteger();
        return commandResult(host, c);
    });
    method("fork", (LuaValue[] args) {
        // A copy of the battle as it stands before it starts, for the silent judge. Options:
        // `moments = false` drops the moments; `scale = n` makes each wave n percent as large.
        if (host.battle.stepIndex != 0)
            return [LuaValue.init, LuaValue("fork: only before the first step")];
        auto copy = new BattleHost();
        BattleSetup s = host.battle.setup;
        immutable options = argument(args, 1);
        immutable moments = member(options, "moments");
        if (moments.isBoolean() && !moments.asBool())
            s.moments = [];
        int scale = 100;
        optionalInteger(options, "scale", scale);
        if (scale != 100) {
            s.waves = s.waves.dup;
            foreach (ref w; s.waves) {
                w.count = w.count * scale / 100;
                if (w.count < 1)
                    w.count = 1;
            }
        }
        immutable problem = copy.battle.begin(s);
        if (!problem.ok())
            return [LuaValue.init, LuaValue(problem.field ~ ": " ~ problem.message)];
        copy.active = true;
        foreach (c; host.battle.log) {
            string why;
            if (!copy.battle.command(c, why))
                return [LuaValue.init, LuaValue("fork: a logged command was refused: " ~ why)];
        }
        return [handleFor(copy)];
    });
    method("snapshot", (LuaValue[] args) { return [snapshotTable(host.battle)]; });
    method("tile", (LuaValue[] args) {
        immutable q = argument(args, 1), r = argument(args, 2);
        if (!q.isInteger() || !r.isInteger())
            return [LuaValue.init];
        immutable tq = cast(int) q.asInteger(), tr = cast(int) r.asInteger();
        if (!host.battle.map.inside(tq, tr))
            return [LuaValue.init];
        auto t = new LuaTable();
        t.rawset(LuaValue("wall"), LuaValue(host.battle.map.isWall(tq, tr)));
        t.rawset(LuaValue("height"), LuaValue(cast(long) host.battle.map.heightAt(tq, tr)));
        t.rawset(LuaValue("revealed"), LuaValue(host.battle.fog.isRevealed(tq, tr)));
        immutable idx = tr * host.battle.width + tq;
        immutable at = host.battle.structureAt[idx];
        t.rawset(LuaValue("unit"), at != 0 ? LuaValue(cast(long) host.battle.sId[at - 1]) : LuaValue.init);
        return [LuaValue(t)];
    });
    method("route", (LuaValue[] args) {
        // The tiles an enemy of source `n` walks to its sink, now: {{q, r}, ...}.
        immutable n = argument(args, 1);
        if (!n.isInteger() || n.asInteger() < 1 || n.asInteger() > host.battle.setup.sources.length)
            return [LuaValue.init];
        if (host.battle.fieldsDirty)
            host.battle.refreshFields();
        immutable src = cast(int) n.asInteger() - 1;
        immutable sink = host.battle.setup.sources[src].sink;
        immutable base = sink * host.battle.tiles;
        auto list = new LuaTable();
        int tile = host.battle.sourceTile[src];
        long count = 0;
        foreach (_; 0 .. host.battle.tiles) {
            auto row = new LuaTable();
            row.rawset(LuaValue("q"), LuaValue(cast(long)(tile % host.battle.width)));
            row.rawset(LuaValue("r"), LuaValue(cast(long)(tile / host.battle.width)));
            list.rawset(LuaValue(++count), LuaValue(row));
            if (tile == host.battle.sinkTile[sink])
                break;
            immutable open = host.battle.openParent[base + tile];
            immutable next = host.battle.openDistance[base + tile] != int.max ? open
                : host.battle.throughParent[base + tile];
            if (next < 0)
                break;
            tile = next;
        }
        return [LuaValue(list)];
    });
    method("log", (LuaValue[] args) { return [logTable(host.battle)]; });
    method("cues", (LuaValue[] args) { return [cuesTable(host.battle)]; });
    method("scene", (LuaValue[] args) {
        immutable scene = host.momentScene();
        return [scene.length ? LuaValue(scene) : LuaValue.init];
    });
    method("outcome", (LuaValue[] args) { return [outcomeTable(host.battle)]; });
    method("digest", (LuaValue[] args) { return [LuaValue(cast(long) host.battle.digest())]; });
    method("steps", (LuaValue[] args) { return [LuaValue(cast(long) host.battle.stepIndex)]; });
    method("place", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.place;
        immutable kind = argument(args, 1), q = argument(args, 2), r = argument(args, 3);
        if (!kind.isInteger() || !q.isInteger() || !r.isInteger())
            return [LuaValue(false), LuaValue("place(kind, q, r) needs integers")];
        c.towerKind = cast(int) kind.asInteger() - 1;
        c.q = cast(int) q.asInteger();
        c.r = cast(int) r.asInteger();
        return commandResult(host, c);
    });
    method("sell", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.sell;
        immutable id = argument(args, 1);
        if (!id.isInteger())
            return [LuaValue(false), LuaValue("sell(id) needs an integer")];
        c.target = cast(int) id.asInteger();
        return commandResult(host, c);
    });
    method("upgrade", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.upgrade;
        immutable id = argument(args, 1);
        if (!id.isInteger())
            return [LuaValue(false), LuaValue("upgrade(id) needs an integer")];
        c.target = cast(int) id.asInteger();
        return commandResult(host, c);
    });
    method("reveal", (LuaValue[] args) {
        Command c;
        c.action = CommandKind.reveal;
        immutable sector = argument(args, 1);
        if (!sector.isInteger())
            return [LuaValue(false), LuaValue("reveal(sector) needs an integer")];
        c.target = cast(int) sector.asInteger() - 1;
        return commandResult(host, c);
    });
    return LuaValue(handle);
}

private string triggerName(Trigger t) {
    final switch (t) {
    case Trigger.step:
        return "step";
    case Trigger.waveStart:
        return "wave_start";
    case Trigger.structureDestroyed:
        return "structure_destroyed";
    case Trigger.leakCount:
        return "leak_count";
    case Trigger.battleWon:
        return "battle_won";
    case Trigger.battleLost:
        return "battle_lost";
    case Trigger.heroDowned:
        return "hero_downed";
    case Trigger.heroHpBelow:
        return "hero_hp_below";
    case Trigger.heroesNear:
        return "heroes_near";
    case Trigger.enemyKindSeen:
        return "enemy_kind_seen";
    }
}

private string cueName(CueKind k) {
    final switch (k) {
    case CueKind.hit:
        return "hit";
    case CueKind.death:
        return "death";
    case CueKind.leak:
        return "leak";
    case CueKind.build:
        return "build";
    case CueKind.ruin:
        return "ruin";
    case CueKind.sell:
        return "sell";
    case CueKind.upgrade:
        return "upgrade";
    case CueKind.down:
        return "down";
    case CueKind.disobey:
        return "disobey";
    case CueKind.repaired:
        return "repaired";
    case CueKind.shielded:
        return "shielded";
    case CueKind.burned:
        return "burned";
    case CueKind.summoned:
        return "summoned";
    case CueKind.taunted:
        return "taunted";
    case CueKind.reinforced:
        return "reinforced";
    case CueKind.flare:
        return "flare";
    case CueKind.healed:
        return "healed";
    }
}

private LuaValue cuesTable(const Battle b) {
    auto t = new LuaTable();
    foreach (i, c; b.lastCues()) {
        auto row = new LuaTable();
        row.rawset(LuaValue("kind"), LuaValue(cueName(c.kind)));
        row.rawset(LuaValue("a"), LuaValue(cast(long) c.a));
        row.rawset(LuaValue("b"), LuaValue(cast(long) c.b));
        t.rawset(LuaValue(cast(long)(i + 1)), LuaValue(row));
    }
    return LuaValue(t);
}

/// The view's picture of a battle at one moment: every unit and enemy with its tile and health,
/// and which fog sectors are revealed. Read-only; looking never changes the battle.
private LuaValue snapshotTable(const Battle b) {
    auto t = new LuaTable();
    void put(LuaTable table, string key, long value) {
        table.rawset(LuaValue(key), LuaValue(value));
    }

    put(t, "step", b.stepIndex);
    put(t, "credits", b.credits);
    put(t, "leaks", b.leaks);
    put(t, "max_leaks", b.setup.maxLeaks);
    put(t, "kills", b.kills);
    put(t, "width", b.width);
    put(t, "height", b.height);
    auto units = new LuaTable();
    foreach (s; 0 .. b.structureCount) {
        auto row = new LuaTable();
        put(row, "id", b.sId[s]);
        put(row, "kind", b.sKind[s] + 1);
        put(row, "q", b.sTile[s] % b.width);
        put(row, "r", b.sTile[s] / b.width);
        put(row, "hp", b.sHp[s]);
        put(row, "max", b.sMaxHp[s]);
        put(row, "level", b.sLevel[s]);
        put(row, "shield", b.sShield[s]);
        row.rawset(LuaValue("hero"), LuaValue(b.sIsHero[s]));
        row.rawset(LuaValue("alive"), LuaValue(b.sAlive[s]));
        row.rawset(LuaValue("downed"), LuaValue(b.sDowned[s]));
        put(row, "ability_cd", b.sAbilityCd[s]);
        units.rawset(LuaValue(cast(long)(s + 1)), LuaValue(row));
    }
    t.rawset(LuaValue("units"), LuaValue(units));
    auto enemies = new LuaTable();
    foreach (e; 0 .. b.enemyCount) {
        auto row = new LuaTable();
        put(row, "id", b.eId[e]);
        put(row, "kind", b.eKind[e] + 1);
        put(row, "q", b.eTile[e] % b.width);
        put(row, "r", b.eTile[e] / b.width);
        put(row, "hp", b.eHp[e]);
        put(row, "shield", b.eShield[e]);
        put(row, "progress", b.eProgress[e]);
        row.rawset(LuaValue("burning"), LuaValue(b.eBurn[e] > 0));
        row.rawset(LuaValue("slowed"), LuaValue(b.eSlow[e] > 0));
        enemies.rawset(LuaValue(cast(long)(e + 1)), LuaValue(row));
    }
    t.rawset(LuaValue("enemies"), LuaValue(enemies));
    auto sectors = new LuaTable();
    foreach (i; 0 .. b.fog.sectorCount())
        sectors.rawset(LuaValue(cast(long)(i + 1)), LuaValue(b.fog.revealed[i] != 0));
    t.rawset(LuaValue("revealed"), LuaValue(sectors));
    return LuaValue(t);
}

/// The accepted commands, each as `{stamp, action, kind, q, r, target, a, b, c, d}` numbers, so a
/// battle can be replayed with `battle.replay`.
private LuaValue logTable(const Battle b) {
    auto t = new LuaTable();
    foreach (i, c; b.log) {
        auto row = new LuaTable();
        immutable long[10] fields = [
            c.stamp, c.action, c.towerKind, c.q, c.r, c.target, c.a, c.b, c.c, c.d
        ];
        foreach (j, v; fields)
            row.rawset(LuaValue(cast(long)(j + 1)), LuaValue(v));
        t.rawset(LuaValue(cast(long)(i + 1)), LuaValue(row));
    }
    return LuaValue(t);
}

/// Applies the table `battle_sync` returned: modifiers for heroes, bonds, the whole battle, orders,
/// allies, healing, damage, revealed sectors and an early end. Returns the number applied and a
/// list of the refusals (`"entry: reason"`), so a content author sees what did not take.
LuaValue[] syncMods(BattleHost host, LuaValue mods) {
    long applied = 0;
    auto refused = new LuaTable();
    long refusedCount = 0;
    void run(Command c, string label) {
        string why;
        if (host.battle.command(c, why)) {
            ++applied;
        } else {
            refused.rawset(LuaValue(++refusedCount), LuaValue(label ~ ": " ~ why));
        }
    }

    if (!mods.isTable())
        return [LuaValue(0L), LuaValue(refused)];
    int geti(LuaValue row, string key, int fallback = 0) {
        int v = fallback;
        optionalInteger(row, key, v);
        return v;
    }

    // bonds replace the list: an explicit empty list clears it
    immutable bonds = member(mods, "bonds");
    if (bonds.isTable()) {
        Command clear;
        clear.action = CommandKind.bondsClear;
        run(clear, "bonds");
        foreach (row; elements(bonds)) {
            Command c;
            c.action = CommandKind.bondAdd;
            c.target = geti(row, "a");
            c.a = geti(row, "b");
            c.b = geti(row, "within", 3);
            c.c = geti(row, "damage");
            run(c, "bonds");
        }
    }
    foreach (row; elements(member(mods, "hero_mods"))) {
        Command c;
        c.action = CommandKind.heroMod;
        c.target = geti(row, "hero");
        c.a = geti(row, "radius");
        c.b = geti(row, "damage");
        c.c = geti(row, "obedience");
        c.d = geti(row, "rate");
        run(c, "hero_mods");
    }
    immutable global = member(mods, "global");
    if (global.isTable()) {
        Command c;
        c.action = CommandKind.global;
        c.a = geti(global, "damage");
        c.b = geti(global, "bounty");
        run(c, "global");
    }
    foreach (row; elements(member(mods, "orders"))) {
        Command c;
        c.action = CommandKind.order;
        c.target = geti(row, "hero");
        immutable order = text(member(row, "order"));
        if (order == "hold") {
            c.a = 0;
        } else if (order == "move") {
            c.a = 1;
            c.q = geti(row, "q");
            c.r = geti(row, "r");
        } else if (order == "follow") {
            c.a = 2;
            c.b = geti(row, "target");
        } else {
            refused.rawset(LuaValue(++refusedCount), LuaValue("orders: unknown order"));
            continue;
        }
        run(c, "orders");
    }
    foreach (row; elements(member(mods, "reinforce"))) {
        Command c;
        c.action = CommandKind.reinforce;
        c.towerKind = geti(row, "kind") - 1;
        c.q = geti(row, "q");
        c.r = geti(row, "r");
        run(c, "reinforce");
    }
    foreach (row; elements(member(mods, "heal"))) {
        Command c;
        c.action = CommandKind.heal;
        if (!member(row, "lantern").isNil()) {
            c.a = 0;
            c.c = geti(row, "lantern");
        } else if (!member(row, "hero").isNil()) {
            c.a = 1;
            c.target = geti(row, "hero");
            c.c = geti(row, "amount");
        } else if (!member(row, "near_hero").isNil()) {
            c.a = 2;
            c.target = geti(row, "near_hero");
            c.b = geti(row, "radius", 3);
            c.c = geti(row, "amount");
        } else if (!member(row, "structure").isNil()) {
            c.a = 3;
            c.target = geti(row, "structure");
            c.c = geti(row, "amount");
        } else {
            refused.rawset(LuaValue(++refusedCount), LuaValue("heal: name lantern, hero, near_hero or structure"));
            continue;
        }
        run(c, "heal");
    }
    foreach (row; elements(member(mods, "damage"))) {
        Command c;
        c.action = CommandKind.damage;
        c.target = geti(row, "hero");
        c.a = geti(row, "amount");
        run(c, "damage");
    }
    foreach (v; elements(member(mods, "reveal"))) {
        Command c;
        c.action = CommandKind.reveal;
        c.target = v.isInteger() ? cast(int) v.asInteger() - 1 : -1;
        run(c, "reveal");
    }
    if (text(member(mods, "end_with")) == "withdrawn") {
        Command c;
        c.action = CommandKind.end;
        run(c, "end_with");
    }
    return [LuaValue(applied), LuaValue(refused)];
}

private LuaValue[] commandResult(BattleHost host, Command c) {
    string refusal;
    if (host.battle.command(c, refusal))
        return [LuaValue(true)];
    return [LuaValue(false), LuaValue(refusal)];
}

/// Installs the `battle` library: `battle.new(setup)` returns a handle, or nil, the field and the
/// message of the first problem in the setup. Hosts install it with the other libraries.
void openBattleLib(LuaState state) {
    auto lib = new LuaTable();
    lib.rawset(LuaValue("new"), LuaValue(new LuaNativeFunction((void* ignored, LuaValue[] args) {
                auto host = new BattleHost();
                immutable problem = host.start(argument(args, 0));
                if (!problem.ok())
                    return [LuaValue.init, LuaValue(problem.field ~ ": " ~ problem.message)];
                return [handleFor(host)];
            }, "battle.new")));
    // battle.replay(setup, log): the outcome of the same battle from its command log; moments
    // pass without a scene (the log holds what the scenes did)
    lib.rawset(LuaValue("replay"), LuaValue(new LuaNativeFunction((void* ignored, LuaValue[] args) {
                auto host = new BattleHost();
                immutable problem = host.start(argument(args, 0));
                if (!problem.ok())
                    return [LuaValue.init, LuaValue(problem.field ~ ": " ~ problem.message)];
                LuaValue[] rows = elements(argument(args, 1));
                size_t next = 0;
                foreach (_; 0 .. 2_000_000) {
                    while (next < rows.length) {
                        immutable row = rows[next];
                        auto cell = (long j) => row.asTable().rawgetInt(j).asInteger();
                        if (cell(1) != host.battle.stepIndex)
                            break;
                        Command c;
                        c.action = cast(CommandKind) cell(2);
                        c.towerKind = cast(int) cell(3);
                        c.q = cast(int) cell(4);
                        c.r = cast(int) cell(5);
                        c.target = cast(int) cell(6);
                        c.a = cast(int) cell(7);
                        c.b = cast(int) cell(8);
                        c.c = cast(int) cell(9);
                        c.d = cast(int) cell(10);
                        string why;
                        if (!host.battle.command(c, why))
                            return [
                            LuaValue.init, LuaValue("replay: a logged command was refused: " ~ why)
                        ];
                        ++next;
                    }
                    immutable r = host.battle.step();
                    if (r == StepResult.won || r == StepResult.lost || r == StepResult.withdrawn)
                        break;
                }
                return [outcomeTable(host.battle)];
            }, "battle.replay")));
    state.setGlobal("battle", LuaValue(lib));
}

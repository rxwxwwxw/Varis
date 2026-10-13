/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Native tower-defense step spike (TOWER_DEFENSE_PLAN.md section 1). Not part of any gate; it is
/// the reproducible source of the native column there. Standalone: it imports nothing from Varis.
///
///   ldc2 -O3 -release benchmarks/experiments/td_native.d -of=build/td_native
///   build/td_native [WIDTH HEIGHT ENEMIES TOWERS RANGE]      (defaults 100 60 1000 120 3)
///
/// The scenario is the one of `td_tick.lua`: pointy-top axial hex tiles in a WIDTH x HEIGHT
/// parallelogram with about 12 % blocked tiles; a breadth-first flow field to one sink; towers with
/// hex-disc footprints; each tower picks the enemy nearest the sink in range (ties to the lowest
/// id); damage is summed per enemy and applied; every enemy then moves one hex along the flow
/// field. Structure-of-arrays state, integer arithmetic, no allocation inside the step. It is a
/// toy: one damage kind, no projectiles, statuses or removal bookkeeping, so a real step costs
/// several times more per enemy.
module benchmarks.experiments.td_native;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import std.conv : to;

private immutable int[2][6] directions = [[1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]];

private double millisecondsSince(MonoTime start) {
    return (MonoTime.currTime - start).total!"nsecs" / 1.0e6;
}

private struct Map {
    int width, height;
    int[] flow, distance;
    bool[] blocked;

    int index(int q, int r) const {
        return r * width + q;
    }

    bool inside(int q, int r) const {
        return q >= 0 && q < width && r >= 0 && r < height;
    }
}

/// Breadth-first flow field towards `sink`; returns the number of tiles reached.
private int buildFlow(ref Map map, int sink, int[] queue) {
    map.flow[] = -1;
    map.distance[] = int.max;
    int head = 0, tail = 0;
    queue[tail++] = sink;
    map.distance[sink] = 0;
    while (head < tail) {
        immutable current = queue[head++];
        immutable q = current % map.width, r = current / map.width;
        foreach (step; directions) {
            immutable nq = q + step[0], nr = r + step[1];
            if (!map.inside(nq, nr))
                continue;
            immutable next = map.index(nq, nr);
            if (map.blocked[next] || map.distance[next] != int.max)
                continue;
            map.distance[next] = map.distance[current] + 1;
            map.flow[next] = current;
            queue[tail++] = next;
        }
    }
    return tail;
}

private uint nextRandom(ref uint state) {
    state = state * 1664525 + 1013904223;
    return state;
}

int main(string[] args) {
    immutable width = args.length > 1 ? to!int(args[1]) : 100;
    immutable height = args.length > 2 ? to!int(args[2]) : 60;
    immutable enemies = args.length > 3 ? to!int(args[3]) : 1000;
    immutable towers = args.length > 4 ? to!int(args[4]) : 120;
    immutable radius = args.length > 5 ? to!int(args[5]) : 3;
    immutable tiles = width * height;

    Map map;
    map.width = width;
    map.height = height;
    map.flow = new int[tiles];
    map.distance = new int[tiles];
    map.blocked = new bool[tiles];
    uint random = 12345;
    foreach (i; 0 .. tiles)
        map.blocked[i] = (nextRandom(random) >> 24) < 30;
    immutable sink = map.index(width - 1, height - 1);
    map.blocked[sink] = false;
    auto queue = new int[tiles];
    auto start = MonoTime.currTime;
    immutable reached = buildFlow(map, sink, queue);
    printf("map %dx%d = %d tiles: flow field %.2f ms, %d reached\n", width, height, tiles,
            millisecondsSince(start), reached);

    // footprint offsets of a hex disc of the given radius
    int[2][] offsets;
    foreach (dq; -radius .. radius + 1) {
        immutable lo = -radius > -dq - radius ? -radius : -dq - radius;
        immutable hi = radius < -dq + radius ? radius : -dq + radius;
        foreach (dr; lo .. hi + 1)
            offsets ~= [dq, dr];
    }

    auto enemyTile = new int[enemies], enemyHp = new int[enemies], damage = new int[enemies];
    auto bucketNext = new int[enemies];
    auto towerTile = new int[towers];
    auto bucketHead = new int[tiles];
    auto bucketStamp = new uint[tiles];
    uint generation = 0;

    int randomWalkable() {
        int t;
        do
            t = (nextRandom(random) >> 8) % tiles;
        while (map.blocked[t] || map.flow[t] < 0);
        return t;
    }

    foreach (i; 0 .. enemies) {
        enemyTile[i] = randomWalkable();
        enemyHp[i] = 1_000_000;
    }
    foreach (j; 0 .. towers) {
        int t;
        do
            t = (nextRandom(random) >> 8) % tiles;
        while (map.blocked[t]);
        towerTile[j] = t;
    }

    enum steps = 200;
    long checksum = 0;
    start = MonoTime.currTime;
    foreach (step; 0 .. steps) {
        // bucket the enemies by tile; stamps avoid clearing the whole map each step
        ++generation;
        foreach (i; 0 .. enemies) {
            immutable t = enemyTile[i];
            if (bucketStamp[t] != generation) {
                bucketStamp[t] = generation;
                bucketHead[t] = -1;
            }
            bucketNext[i] = bucketHead[t];
            bucketHead[t] = i;
        }
        damage[] = 0;
        foreach (j; 0 .. towers) {
            immutable tq = towerTile[j] % width, tr = towerTile[j] / width;
            int best = -1, bestDistance = int.max;
            foreach (offset; offsets) {
                immutable q = tq + offset[0], r = tr + offset[1];
                if (!map.inside(q, r))
                    continue;
                immutable t = r * width + q;
                if (bucketStamp[t] != generation)
                    continue;
                for (int e = bucketHead[t]; e >= 0; e = bucketNext[e]) {
                    immutable d = map.distance[t];
                    if (d < bestDistance || (d == bestDistance && e < best)) {
                        bestDistance = d;
                        best = e;
                    }
                }
            }
            if (best >= 0)
                damage[best] += 3;
        }
        foreach (i; 0 .. enemies) {
            enemyHp[i] -= damage[i];
            immutable next = map.flow[enemyTile[i]];
            if (next < 0) { // at the sink: respawn on a random walkable tile
                enemyTile[i] = randomWalkable();
                enemyHp[i] = 1_000_000;
            } else
                enemyTile[i] = next;
            checksum += enemyTile[i];
        }
    }
    immutable perStep = millisecondsSince(start) / steps;
    printf("enemies=%d towers=%d range=%d: %.3f ms/step (%.0f ns per enemy-step), checksum %lld\n",
            enemies, towers, radius, perStep, perStep * 1.0e6 / enemies, checksum);
    return 0;
}

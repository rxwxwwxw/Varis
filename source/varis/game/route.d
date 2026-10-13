/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Flow fields toward a sink (TOWER_DEFENSE_PLAN.md §6.2 phase 3, TD1). A field is a breadth-first
/// search from the sink over unblocked tiles: `distance[t]` is the number of steps to the sink and
/// `parent[t]` is the next tile on the way, so a unit on `t` moves to `parent[t]`. Unreachable
/// tiles have distance `unreachable` and parent -1. Costs are uniform in this version; Dijkstra
/// costs are a later decision. Leaf module (plan B9).
module varis.game.route;

import varis.game.hex : neighbourOffsets;

@nogc nothrow:

enum int unreachable = int.max;

/// Fills `parent`, `distance` and uses `queue` as scratch. The arrays are `width * height` long
/// and `queue` must be at least as long too. `blocked[sink]` is ignored: the search starts there.
/// Returns the number of tiles reached, the sink included.
int buildField(const(bool)[] blocked, int width, int height, int sink,
        int[] parent, int[] distance, int[] queue) {
    immutable tiles = width * height;
    parent[0 .. tiles] = -1;
    distance[0 .. tiles] = unreachable;
    int head = 0, tail = 0;
    queue[tail++] = sink;
    distance[sink] = 0;
    while (head < tail) {
        immutable current = queue[head++];
        immutable q = current % width, r = current / width;
        foreach (step; neighbourOffsets) {
            immutable nq = q + step[0], nr = r + step[1];
            if (nq < 0 || nr < 0 || nq >= width || nr >= height)
                continue;
            immutable next = nr * width + nq;
            if (blocked[next] || distance[next] != unreachable)
                continue;
            distance[next] = distance[current] + 1;
            parent[next] = current;
            queue[tail++] = next;
        }
    }
    return tail;
}

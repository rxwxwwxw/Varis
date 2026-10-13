/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Pointy-top axial hex maths on integers (TOWER_DEFENSE_PLAN.md TD1). Leaf module: it imports
/// nothing from Varis (plan B9). Tile ids are stable 64-bit keys; region-local indices are
/// `r * width + q` and are what the arrays use.
module varis.game.hex;

@nogc nothrow:

/// Axial neighbour offsets in order E, NE, NW, W, SW, SE.
immutable int[2][6] neighbourOffsets = [[1, 0], [1, -1], [0, -1], [-1, 0], [-1, 1], [0, 1]];

/// Stable key of an axial tile: `(q + 1024) * 4096 + (r + 1024)`, valid for |q|, |r| < 1024.
long tileId(int q, int r) {
    return cast(long)(q + 1024) * 4096 + (r + 1024);
}

int tileQ(long id) {
    return cast(int)(id / 4096) - 1024;
}

int tileR(long id) {
    return cast(int)(id % 4096) - 1024;
}

int absInt(int value) {
    return value < 0 ? -value : value;
}

/// Hex distance between two axial tiles (number of steps on the hex grid).
int hexDistance(int q1, int r1, int q2, int r2) {
    immutable dq = q2 - q1, dr = r2 - r1, ds = -dq - dr;
    return (absInt(dq) + absInt(dr) + absInt(ds)) / 2;
}

/// The neighbour of `(q, r)` in direction `dir` (0..5).
void neighbour(int q, int r, int dir, out int nq, out int nr) {
    nq = q + neighbourOffsets[dir][0];
    nr = r + neighbourOffsets[dir][1];
}

/// True when the offset `(dq, dr)` lies in the hex disc of `radius` around the origin.
bool inDisc(int dq, int dr, int radius) {
    return hexDistance(0, 0, dq, dr) <= radius;
}

/// Number of tiles in a hex disc of `radius`: 3r(r+1) + 1.
int discSize(int radius) {
    return 3 * radius * (radius + 1) + 1;
}

/// Index of a region-local tile, or -1 when `(q, r)` is outside a `width` x `height` region.
int regionIndex(int width, int height, int q, int r) {
    if (q < 0 || r < 0 || q >= width || r >= height)
        return -1;
    return r * width + q;
}

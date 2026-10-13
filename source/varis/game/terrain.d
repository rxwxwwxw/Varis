/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Terrain of a battle map (TOWER_DEFENSE_PLAN.md B7, TD1): a pure function of `(seed, q, r)` by
/// integer hashing, plus a short list of edits that story and play make (a collapsed bridge, a
/// cleared scree path). No floats, no libm, no clock. Leaf module (plan B9).
module varis.game.terrain;

@nogc nothrow:

/// Edit made to the generated terrain. Edits persist in the world as facts (plan B4).
struct TileEdit {
    int q, r;
    /// true: the tile is made impassable (a collapsed bridge); false: passable (cleared scree).
    bool wall;
}

/// Terrain of one region: `width` x `height` axial tiles with `q` in `[0, width)` and `r` in
/// `[0, height)`. The generated part is a pure function of the seed, so two machines agree.
struct MapRegion {
    int width, height;
    ulong seed;
    /// Edits, looked up linearly; a map has tens of them, not thousands.
    const(TileEdit)[] edits;
    /// Generated walls: a tile is a wall when its hash byte is below this (30 of 256 is about
    /// 12 %). A designed map sets 0 and draws its walls as edits.
    int wallThreshold = 30;
    /// When positive, heights are terraces: `3 - r / terraceRows`, at least 0, so the top rows
    /// are the highest ground. Zero keeps the generated heights.
    int terraceRows;

    bool inside(int q, int r) const {
        return q >= 0 && r >= 0 && q < width && r < height;
    }

    /// Height 0..7 of a tile (0 when outside the region). Generated; edits do not change it.
    int heightAt(int q, int r) const {
        if (!inside(q, r))
            return 0;
        if (terraceRows > 0) {
            immutable level = 3 - r / terraceRows;
            return level > 0 ? level : 0;
        }
        return cast(int)(tileHash(seed, q, r) >> 61);
    }

    /// True when the tile is impassable: an edit decides it, otherwise about 12 % of tiles are
    /// generated as walls. Tiles outside the region are walls.
    bool isWall(int q, int r) const {
        if (!inside(q, r))
            return true;
        foreach (edit; edits)
            if (edit.q == q && edit.r == r)
                return edit.wall;
        return cast(int)((tileHash(seed, q, r) >> 20) & 0xFF) < wallThreshold;
    }
}

/// SplitMix64 finaliser.
ulong mix64(ulong value) {
    value += 0x9E3779B97F4A7C15UL;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9UL;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBUL;
    return value ^ (value >> 31);
}

/// Hash of a tile; the same `(seed, q, r)` gives the same value on every platform.
ulong tileHash(ulong seed, int q, int r) {
    immutable ulong column = cast(ulong) cast(uint) q;
    immutable ulong row = cast(ulong) cast(uint) r;
    return mix64(seed ^ mix64(column * 0x2545F4914F6CDD1DUL + row));
}

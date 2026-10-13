/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Fog of a battle map (TOWER_DEFENSE_PLAN.md §7.4, TD1): the region is cut into sectors of 16 x 9
/// tiles, and each sector is either revealed or not. Revealed sectors are the only tiles enemies
/// may walk on and towers may be placed on. Leaf module (plan B9).
module varis.game.fog;

@nogc nothrow:

enum int sectorWidth = 16;
enum int sectorHeight = 9;

/// Number of sectors covering a `width` x `height` region.
int fogSectorCount(int width, int height) {
    return ((width + sectorWidth - 1) / sectorWidth) * ((height + sectorHeight - 1) / sectorHeight);
}

struct Fog {
    int width, height;
    int sectorsWide, sectorsHigh;
    /// One byte per sector: 1 revealed, 0 hidden.
    ubyte[] revealed;

    /// Sizes the grid for a region. Every sector starts hidden; the caller owns `storage`.
    void setup(int regionWidth, int regionHeight, ubyte[] storage) {
        width = regionWidth;
        height = regionHeight;
        sectorsWide = (width + sectorWidth - 1) / sectorWidth;
        sectorsHigh = (height + sectorHeight - 1) / sectorHeight;
        revealed = storage[0 .. sectorsWide * sectorsHigh];
        revealed[] = 0;
    }

    int sectorCount() const {
        return sectorsWide * sectorsHigh;
    }

    /// Sector index of a tile, or -1 outside the region.
    int sectorOf(int q, int r) const {
        if (q < 0 || r < 0 || q >= width || r >= height)
            return -1;
        return (r / sectorHeight) * sectorsWide + (q / sectorWidth);
    }

    bool isRevealed(int q, int r) const {
        immutable sector = sectorOf(q, r);
        return sector >= 0 && revealed[sector] != 0;
    }

    /// Reveals one sector; returns true when it was hidden before.
    bool reveal(int sector) {
        if (sector < 0 || sector >= sectorCount() || revealed[sector])
            return false;
        revealed[sector] = 1;
        return true;
    }
}

/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Which code points a TrueType/OpenType font maps (localization plan T5): the data behind
/// `varis l10n fonts`, which checks a translation's character set against the font a game
/// configures for that language. Reads the `cmap` table only (formats 4 and 12, Unicode
/// platform subtables); it does not shape or render.
///
/// Tools layer: nothing in the runtime imports this module.
module varis.services.fontcheck;

private uint u16(const(ubyte)[] data, size_t at) {
    return at + 2 <= data.length ? (cast(uint) data[at] << 8) | data[at + 1] : 0;
}

private uint u32(const(ubyte)[] data, size_t at) {
    return at + 4 <= data.length ? (u16(data, at) << 16) | u16(data, at + 2) : 0;
}

/// Fills `covered` with every code point the font maps to a glyph other than `.notdef`.
/// Returns false with a reason in `error` when the data is not a font or has no Unicode cmap.
bool fontCodePoints(const(ubyte)[] data, out bool[uint] covered, out string error) {
    size_t font;
    if (data.length >= 16 && u32(data, 0) == 0x74746366) // 'ttcf': the first font of a collection
        font = u32(data, 12);
    if (font + 12 > data.length) {
        error = "not a TrueType or OpenType font";
        return false;
    }
    uint magic = u32(data, font);
    if (magic != 0x00010000 && magic != 0x4F54544F && magic != 0x74727565) { // 1.0, 'OTTO', 'true'
        error = "not a TrueType or OpenType font";
        return false;
    }
    uint tables = u16(data, font + 4);
    size_t cmap, cmapLength;
    foreach (i; 0 .. tables) {
        size_t record = font + 12 + 16 * i;
        if (record + 16 > data.length)
            break;
        if (u32(data, record) == 0x636D6170) { // 'cmap'
            cmap = u32(data, record + 8);
            cmapLength = u32(data, record + 12);
        }
    }
    if (cmap == 0 || cmap + 4 > data.length) {
        error = "the font has no cmap table";
        return false;
    }
    bool found;
    uint subtables = u16(data, cmap + 2);
    foreach (i; 0 .. subtables) {
        size_t record = cmap + 4 + 8 * i;
        uint platform = u16(data, record), encoding = u16(data, record + 2);
        bool unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
        if (!unicode)
            continue;
        size_t table = cmap + u32(data, record + 4);
        uint format = u16(data, table);
        if (format == 4) {
            uint segments = u16(data, table + 6) / 2;
            size_t ends = table + 14, starts = ends + 2 * segments + 2, deltas = starts + 2 * segments,
            offsets = deltas + 2 * segments;
            foreach (s; 0 .. segments) {
                uint end = u16(data, ends + 2 * s), start = u16(data, starts + 2 * s);
                uint delta = u16(data, deltas + 2 * s), range = u16(data, offsets + 2 * s);
                foreach (c; start .. end + 1) {
                    if (c == 0xFFFF)
                        break;
                    uint glyph;
                    if (range == 0)
                        glyph = (c + delta) & 0xFFFF;
                    else {
                        glyph = u16(data, offsets + 2 * s + range + 2 * (c - start));
                        if (glyph)
                            glyph = (glyph + delta) & 0xFFFF;
                    }
                    if (glyph)
                        covered[c] = true;
                }
            }
            found = true;
        } else if (format == 12) {
            uint groups = u32(data, table + 12);
            foreach (g; 0 .. groups) {
                size_t at = table + 16 + 12 * g;
                uint start = u32(data, at), end = u32(data, at + 4), glyph = u32(data, at + 8);
                if (glyph == 0 || end < start || end - start > 0x10FFFF)
                    continue;
                foreach (c; start .. end + 1)
                    covered[c] = true;
            }
            found = true;
        }
    }
    if (!found) {
        error = "the font has no Unicode cmap of format 4 or 12";
        return false;
    }
    return true;
}

/// Whether a code point needs a glyph: controls, the byte order mark, zero-width and variation
/// selectors are never drawn.
bool needsGlyph(uint code) {
    if (code < 0x20 || (code >= 0x7F && code < 0xA0))
        return false;
    if (code == 0xFEFF || (code >= 0x200B && code <= 0x200F) || (code >= 0xFE00 && code <= 0xFE0F))
        return false;
    return true;
}

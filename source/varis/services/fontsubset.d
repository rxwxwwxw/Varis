/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Publisher font subsetting (NARRATIVE_LOCALIZATION_PLAN §4, §5, §6.4, §9 stage T5):
/// subsets a TrueType font (.ttf) or TrueType Collection (.ttc) to only the glyphs needed
/// for a given set of Unicode code points. Produces a valid, compact TrueType font.
module varis.services.fontsubset;

import varis.services.fontcheck : needsGlyph;
import std.algorithm : sort;

private uint u16(const(ubyte)[] data, size_t at) nothrow @nogc {
    return at + 2 <= data.length ? (cast(uint) data[at] << 8) | data[at + 1] : 0;
}

private uint u32(const(ubyte)[] data, size_t at) nothrow @nogc {
    return at + 4 <= data.length ? (u16(data, at) << 16) | u16(data, at + 2) : 0;
}

private void putU16(ref ubyte[] buf, uint v) {
    buf ~= cast(ubyte)(v >> 8);
    buf ~= cast(ubyte)(v & 0xFF);
}

private void putU32(ref ubyte[] buf, uint v) {
    buf ~= cast(ubyte)(v >> 24);
    buf ~= cast(ubyte)((v >> 16) & 0xFF);
    buf ~= cast(ubyte)((v >> 8) & 0xFF);
    buf ~= cast(ubyte)(v & 0xFF);
}

private void writeU16At(ubyte[] buf, size_t at, uint v) nothrow @nogc {
    if (at + 2 <= buf.length) {
        buf[at] = cast(ubyte)(v >> 8);
        buf[at + 1] = cast(ubyte)(v & 0xFF);
    }
}

private void writeU32At(ubyte[] buf, size_t at, uint v) nothrow @nogc {
    if (at + 4 <= buf.length) {
        buf[at] = cast(ubyte)(v >> 24);
        buf[at + 1] = cast(ubyte)((v >> 16) & 0xFF);
        buf[at + 2] = cast(ubyte)((v >> 8) & 0xFF);
        buf[at + 3] = cast(ubyte)(v & 0xFF);
    }
}

private uint calcTableChecksum(const(ubyte)[] table) nothrow @nogc {
    uint sum = 0;
    size_t n = table.length / 4;
    for (size_t i = 0; i < n; ++i)
        sum += u32(table, i * 4);
    size_t rem = table.length % 4;
    if (rem > 0) {
        uint last = 0;
        for (size_t i = 0; i < rem; ++i)
            last |= (cast(uint) table[n * 4 + i]) << (24 - 8 * i);
        sum += last;
    }
    return sum;
}

private struct TableEntry {
    uint tag;
    ubyte[] data;
}

/// Subsets `fontData` to contain only the glyphs required for `neededCodePoints`.
/// Returns true on success with the new TrueType font bytes in `subsettedData`.
bool subsetFont(const(ubyte)[] fontData, const(bool[uint]) neededCodePoints,
        out ubyte[] subsettedData, out string error) {
    size_t fontOffset = 0;
    if (fontData.length >= 16 && u32(fontData, 0) == 0x74746366) // 'ttcf'
        fontOffset = u32(fontData, 12);
    if (fontOffset + 12 > fontData.length) {
        error = "not a TrueType or OpenType font";
        return false;
    }
    uint magic = u32(fontData, fontOffset);
    if (magic != 0x00010000 && magic != 0x74727565) {
        error = "font does not contain TrueType outlines";
        return false;
    }

    uint numTables = u16(fontData, fontOffset + 4);
    size_t[uint] tableOffsets;
    size_t[uint] tableLengths;

    foreach (i; 0 .. numTables) {
        size_t rec = fontOffset + 12 + 16 * i;
        if (rec + 16 > fontData.length)
            break;
        uint tag = u32(fontData, rec);
        tableOffsets[tag] = u32(fontData, rec + 8);
        tableLengths[tag] = u32(fontData, rec + 12);
    }

    uint tag(string s) {
        return (cast(uint) s[0] << 24) | (cast(uint) s[1] << 16) | (cast(uint) s[2] << 8) | cast(uint) s[3];
    }

    enum TAG_head = 0x68656164; // 'head'
    enum TAG_hhea = 0x68686561; // 'hhea'
    enum TAG_maxp = 0x6D617870; // 'maxp'
    enum TAG_hmtx = 0x686D7478; // 'hmtx'
    enum TAG_loca = 0x6C6F6361; // 'loca'
    enum TAG_glyf = 0x676C7966; // 'glyf'
    enum TAG_cmap = 0x636D6170; // 'cmap'
    enum TAG_name = 0x6E616D65; // 'name'
    enum TAG_post = 0x706F7374; // 'post'
    enum TAG_OS2 = 0x4F532F32; // 'OS/2'

    foreach (needed; [TAG_head, TAG_hhea, TAG_maxp, TAG_hmtx, TAG_loca, TAG_glyf, TAG_cmap]) {
        if (needed !in tableOffsets) {
            error = "missing required TrueType table";
            return false;
        }
    }

    const(ubyte)[] getTable(uint t) {
        auto pOff = t in tableOffsets;
        auto pLen = t in tableLengths;
        if (!pOff || !pLen || *pOff + *pLen > fontData.length)
            return null;
        return fontData[*pOff .. *pOff + *pLen];
    }

    auto headTable = getTable(TAG_head);
    auto hheaTable = getTable(TAG_hhea);
    auto maxpTable = getTable(TAG_maxp);
    auto hmtxTable = getTable(TAG_hmtx);
    auto locaTable = getTable(TAG_loca);
    auto glyfTable = getTable(TAG_glyf);
    auto cmapTable = getTable(TAG_cmap);

    if (headTable.length < 54 || hheaTable.length < 36 || maxpTable.length < 32) {
        error = "truncated font table headers";
        return false;
    }

    uint indexToLocFormat = u16(headTable, 50);
    uint origNumGlyphs = u16(maxpTable, 4);
    uint origHMetrics = u16(hheaTable, 34);

    // Read original loca
    uint[] origLoca = new uint[origNumGlyphs + 1];
    if (indexToLocFormat == 0) {
        if (locaTable.length < (origNumGlyphs + 1) * 2) {
            error = "corrupt loca table";
            return false;
        }
        foreach (i; 0 .. origNumGlyphs + 1)
            origLoca[i] = u16(locaTable, i * 2) * 2;
    } else {
        if (locaTable.length < (origNumGlyphs + 1) * 4) {
            error = "corrupt loca table";
            return false;
        }
        foreach (i; 0 .. origNumGlyphs + 1)
            origLoca[i] = u32(locaTable, i * 4);
    }

    // Map Unicode code point to original glyph id from cmap
    uint[uint] unicodeToGlyph;
    uint subtables = u16(cmapTable, 2);
    foreach (i; 0 .. subtables) {
        size_t record = 4 + 8 * i;
        if (record + 8 > cmapTable.length)
            break;
        uint platform = u16(cmapTable, record);
        uint encoding = u16(cmapTable, record + 2);
        bool isUnicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
        if (!isUnicode)
            continue;

        size_t subOff = u32(cmapTable, record + 4);
        if (subOff + 4 > cmapTable.length)
            continue;
        uint format = u16(cmapTable, subOff);
        if (format == 4) {
            if (subOff + 14 > cmapTable.length)
                continue;
            uint segs = u16(cmapTable, subOff + 6) / 2;
            size_t ends = subOff + 14, starts = ends + 2 * segs + 2;
            size_t deltas = starts + 2 * segs, offsets = deltas + 2 * segs;
            if (offsets + 2 * segs > cmapTable.length)
                continue;
            foreach (s; 0 .. segs) {
                uint end = u16(cmapTable, ends + 2 * s);
                uint start = u16(cmapTable, starts + 2 * s);
                uint delta = u16(cmapTable, deltas + 2 * s);
                uint range = u16(cmapTable, offsets + 2 * s);
                foreach (c; start .. end + 1) {
                    if (c == 0xFFFF)
                        break;
                    uint g = 0;
                    if (range == 0)
                        g = (c + delta) & 0xFFFF;
                    else {
                        size_t at = offsets + 2 * s + range + 2 * (c - start);
                        if (at + 2 <= cmapTable.length) {
                            g = u16(cmapTable, at);
                            if (g)
                                g = (g + delta) & 0xFFFF;
                        }
                    }
                    if (g && (c !in unicodeToGlyph))
                        unicodeToGlyph[c] = g;
                }
            }
        } else if (format == 12) {
            if (subOff + 16 > cmapTable.length)
                continue;
            uint groups = u32(cmapTable, subOff + 12);
            foreach (g; 0 .. groups) {
                size_t at = subOff + 16 + 12 * g;
                if (at + 12 > cmapTable.length)
                    break;
                uint start = u32(cmapTable, at);
                uint end = u32(cmapTable, at + 4);
                uint startGlyph = u32(cmapTable, at + 8);
                foreach (c; start .. end + 1) {
                    uint glyph = startGlyph + (c - start);
                    if (glyph && (c !in unicodeToGlyph))
                        unicodeToGlyph[c] = glyph;
                }
            }
        }
    }

    // Determine required glyphs
    bool[uint] requiredGlyphs;
    requiredGlyphs[0] = true; // Glyph 0 (.notdef) is always included
    uint[] queue = [0];

    foreach (c, _; neededCodePoints) {
        if (!needsGlyph(c))
            continue;
        if (auto pG = c in unicodeToGlyph) {
            uint g = *pG;
            if (g < origNumGlyphs && (g !in requiredGlyphs)) {
                requiredGlyphs[g] = true;
                queue ~= g;
            }
        }
    }

    // Process composite glyph dependencies
    while (queue.length > 0) {
        uint g = queue[$ - 1];
        queue.length--;

        uint start = origLoca[g];
        uint end = origLoca[g + 1];
        if (end <= start || end > glyfTable.length)
            continue;
        const(ubyte)[] glyphData = glyfTable[start .. end];
        if (glyphData.length < 10)
            continue;

        short numContours = cast(short) u16(glyphData, 0);
        if (numContours < 0) { // Composite glyph
            size_t p = 10;
            while (p + 4 <= glyphData.length) {
                uint flags = u16(glyphData, p);
                uint compGlyph = u16(glyphData, p + 2);
                p += 4;
                if (compGlyph < origNumGlyphs && (compGlyph !in requiredGlyphs)) {
                    requiredGlyphs[compGlyph] = true;
                    queue ~= compGlyph;
                }
                if (flags & 0x0001)
                    p += 4; // ARG_1_AND_2_ARE_WORDS
                else
                    p += 2;
                if (flags & 0x0008)
                    p += 2; // WE_HAVE_A_SCALE
                else if (flags & 0x0040)
                    p += 4; // WE_HAVE_AN_X_AND_Y_SCALE
                else if (flags & 0x0080)
                    p += 8; // WE_HAVE_A_TWO_BY_TWO
                if (!(flags & 0x0020))
                    break; // MORE_COMPONENTS
            }
        }
    }

    // Sort required glyphs to form new glyph IDs
    uint[] sortedGlyphs = requiredGlyphs.keys;
    sortedGlyphs.sort();
    uint[uint] origToNew;
    foreach (i, g; sortedGlyphs)
        origToNew[g] = cast(uint) i;

    uint newNumGlyphs = cast(uint) sortedGlyphs.length;

    // Build new glyf and loca tables (using 32-bit offsets, indexToLocFormat = 1)
    ubyte[] newGlyf;
    uint[] newLoca = new uint[newNumGlyphs + 1];

    foreach (newId, origId; sortedGlyphs) {
        newLoca[newId] = cast(uint) newGlyf.length;
        uint start = origLoca[origId];
        uint end = origLoca[origId + 1];
        if (end <= start || end > glyfTable.length)
            continue;

        const(ubyte)[] slice = glyfTable[start .. end];
        if (slice.length < 10)
            continue;

        short numContours = cast(short) u16(slice, 0);
        if (numContours >= 0) {
            newGlyf ~= slice;
        } else {
            // Rewrite composite glyph component glyph IDs
            ubyte[] comp = slice.dup;
            size_t p = 10;
            while (p + 4 <= comp.length) {
                uint flags = u16(comp, p);
                uint oldCompId = u16(comp, p + 2);
                uint newCompId = oldCompId in origToNew ? origToNew[oldCompId] : 0;
                writeU16At(comp, p + 2, newCompId);
                p += 4;
                if (flags & 0x0001)
                    p += 4;
                else
                    p += 2;
                if (flags & 0x0008)
                    p += 2;
                else if (flags & 0x0040)
                    p += 4;
                else if (flags & 0x0080)
                    p += 8;
                if (!(flags & 0x0020))
                    break;
            }
            newGlyf ~= comp;
        }
        // Pad glyph data to 2-byte boundary
        if (newGlyf.length % 2 != 0)
            newGlyf ~= 0;
    }
    newLoca[newNumGlyphs] = cast(uint) newGlyf.length;

    // Pad glyf to 4-byte boundary
    while (newGlyf.length % 4 != 0)
        newGlyf ~= 0;

    // Build new loca table
    ubyte[] newLocaTable = new ubyte[(newNumGlyphs + 1) * 4];
    foreach (i, off; newLoca)
        writeU32At(newLocaTable, i * 4, off);

    // Build new maxp table
    ubyte[] newMaxp = maxpTable[0 .. 32].dup;
    writeU16At(newMaxp, 4, newNumGlyphs);

    // Build new hhea table
    ubyte[] newHhea = hheaTable[0 .. 36].dup;
    writeU16At(newHhea, 34, newNumGlyphs); // all metrics are explicit

    // Build new hmtx table
    ubyte[] newHmtx = new ubyte[newNumGlyphs * 4];
    foreach (newId, origId; sortedGlyphs) {
        uint adv;
        uint lsb;
        if (origId < origHMetrics) {
            adv = u16(hmtxTable, origId * 4);
            lsb = u16(hmtxTable, origId * 4 + 2);
        } else {
            adv = u16(hmtxTable, (origHMetrics - 1) * 4);
            size_t lsbOff = origHMetrics * 4 + (origId - origHMetrics) * 2;
            lsb = lsbOff + 2 <= hmtxTable.length ? u16(hmtxTable, lsbOff) : 0;
        }
        writeU16At(newHmtx, newId * 4, adv);
        writeU16At(newHmtx, newId * 4 + 2, lsb);
    }

    // Build new cmap table: Format 12 subtable
    struct CmapGroup {
        uint startCharCode, endCharCode, startGlyphID;
    }

    uint[] mappedCodes;
    foreach (c, _; neededCodePoints) {
        if (!needsGlyph(c))
            continue;
        if (auto pG = c in unicodeToGlyph)
            if (*pG in origToNew)
                mappedCodes ~= c;
    }
    mappedCodes.sort();

    CmapGroup[] groups;
    foreach (c; mappedCodes) {
        uint g = origToNew[unicodeToGlyph[c]];
        if (groups.length && groups[$ - 1].endCharCode + 1 == c && groups[$ - 1].startGlyphID + (
                c - groups[$ - 1].startCharCode) == g) {
            groups[$ - 1].endCharCode = c;
        } else {
            groups ~= CmapGroup(c, c, g);
        }
    }

    ubyte[] format12;
    putU16(format12, 12); // format
    putU16(format12, 0); // reserved
    putU32(format12, cast(uint)(16 + groups.length * 12)); // length
    putU32(format12, 0); // language
    putU32(format12, cast(uint) groups.length);
    foreach (grp; groups) {
        putU32(format12, grp.startCharCode);
        putU32(format12, grp.endCharCode);
        putU32(format12, grp.startGlyphID);
    }

    ubyte[] newCmap;
    putU16(newCmap, 0); // version
    putU16(newCmap, 2); // 2 subtables: Unicode full (0, 4) and Windows full (3, 10)
    // Subtable 1: Platform 0, Encoding 4
    putU16(newCmap, 0);
    putU16(newCmap, 4);
    putU32(newCmap, 20); // offset after 4 + 8*2 = 20
    // Subtable 2: Platform 3, Encoding 10
    putU16(newCmap, 3);
    putU16(newCmap, 10);
    putU32(newCmap, 20);
    newCmap ~= format12;
    while (newCmap.length % 4 != 0)
        newCmap ~= 0;

    // Build new head table
    ubyte[] newHead = headTable[0 .. 54].dup;
    writeU32At(newHead, 8, 0); // checkSumAdjustment = 0
    writeU16At(newHead, 50, 1); // indexToLocFormat = 1 (32-bit loca)

    // Assemble table list
    TableEntry[] tables;
    tables ~= TableEntry(TAG_head, newHead);
    tables ~= TableEntry(TAG_hhea, newHhea);
    tables ~= TableEntry(TAG_maxp, newMaxp);
    tables ~= TableEntry(TAG_OS2, getTable(TAG_OS2).dup);
    tables ~= TableEntry(TAG_hmtx, newHmtx);
    tables ~= TableEntry(TAG_cmap, newCmap);
    tables ~= TableEntry(TAG_loca, newLocaTable);
    tables ~= TableEntry(TAG_glyf, newGlyf);

    auto nameTable = getTable(TAG_name);
    if (nameTable.length)
        tables ~= TableEntry(TAG_name, nameTable.dup);

    auto postTable = getTable(TAG_post);
    if (postTable.length >= 32) {
        // Output clean post format 3.0 (header only, no glyph names)
        ubyte[] newPost = postTable[0 .. 32].dup;
        writeU32At(newPost, 0, 0x00030000); // format 3.0
        tables ~= TableEntry(TAG_post, newPost);
    }

    // Sort tables by tag ascending
    tables.sort!((a, b) => a.tag < b.tag);

    // Build font file
    uint outNumTables = cast(uint) tables.length;
    uint maxPower2 = 1;
    uint entrySelector = 0;
    while (maxPower2 * 2 <= outNumTables) {
        maxPower2 *= 2;
        entrySelector++;
    }
    uint searchRange = maxPower2 * 16;
    uint rangeShift = outNumTables * 16 - searchRange;

    ubyte[] outFont;
    putU32(outFont, 0x00010000); // sfntVersion
    putU16(outFont, outNumTables);
    putU16(outFont, searchRange);
    putU16(outFont, entrySelector);
    putU16(outFont, rangeShift);

    // Reserve directory
    size_t dirOffset = outFont.length;
    outFont.length += outNumTables * 16;

    size_t headTableOffset = 0;

    foreach (i, ref entry; tables) {
        while (outFont.length % 4 != 0)
            outFont ~= 0;
        size_t offset = outFont.length;
        if (entry.tag == TAG_head)
            headTableOffset = offset;
        uint checksum = calcTableChecksum(entry.data);
        size_t rec = dirOffset + 16 * i;
        writeU32At(outFont, rec, entry.tag);
        writeU32At(outFont, rec + 4, checksum);
        writeU32At(outFont, rec + 8, cast(uint) offset);
        writeU32At(outFont, rec + 12, cast(uint) entry.data.length);
        outFont ~= entry.data;
    }

    // Compute font-wide checkSumAdjustment and patch into head table
    uint fontChecksum = calcTableChecksum(outFont);
    uint checkSumAdjustment = 0xB1B0AFBA - fontChecksum;
    if (headTableOffset > 0 && headTableOffset + 12 <= outFont.length)
        writeU32At(outFont, headTableOffset + 8, checkSumAdjustment);

    subsettedData = outFont;
    return true;
}

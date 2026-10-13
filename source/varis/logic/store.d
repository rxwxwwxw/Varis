/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Fact storage for inference: an append-only table of tuples with lazily built hash indexes.
///
/// A frozen table is immutable and is shared between a relation, its snapshots and every query
/// that reads them (benchmarks/PERFORMANCE_PLAN.md, stage W1). An open table is what the
/// evaluator derives into. Probing is `@nogc nothrow`; rows and indexes grow only in `insert`,
/// `append` and `index`, which are the allocation points.
module varis.logic.store;

import varis.types;
import varis.logic.model : RelTuple;

/// Counts of the work the world model did, for tests and benchmarks (performance plan, stage S0
/// item 4). They only ever grow; a reader takes the difference between two readings. One
/// process-wide set: a state is single-threaded and the counts are diagnostics, not behaviour.
struct EngineCounters {
    ulong queries; /// query evaluations (one per iterator first advanced, storylet check, ...)
    ulong ruleFirings; /// runs of one rule's plan (full or delta) inside a fixed point
    ulong tuplesDerived; /// tuples added to derived relations
    ulong factsCopied; /// base facts copied (a shared fact set written to, a head with base facts)
    ulong tableRows; /// rows frozen into a new immutable table after a write
    ulong derivedCacheHits; /// query evaluations that reused cached derived relations
}

__gshared EngineCounters engineCounters;

/// Positions `1 << column` that take part in an index key. Columns past 31 are never indexed;
/// the caller always re-checks every bound column, so that only costs speed.
alias ColumnMask = uint;

pragma(inline, true)
private size_t mixHash(size_t h) @nogc nothrow pure @safe {
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdUL;
    h ^= h >> 33;
    return h;
}

/// Hash chains over the rows of one table for one set of key columns.
final class MaskIndex {
    ColumnMask mask;
    int[] heads; // bucket -> row + 1, or 0
    int[] next; // row -> next row + 1 in the same bucket, or 0
    size_t indexed; // rows [0 .. indexed) are in the chains

    this(ColumnMask mask) {
        this.mask = mask;
    }

    pragma(inline, true)
    static size_t hashRow(const(LuaValue)[] values, ColumnMask mask) nothrow @trusted {
        size_t h = 0x9e3779b97f4a7c15UL;
        size_t limit = values.length < 32 ? values.length : 32;
        foreach (column; 0 .. limit)
            if (mask & (1u << column))
                h = (h * 31) ^ values[column].toHash();
        return mixHash(h);
    }

    /// Brings the chains up to date with `rows` (allocation point).
    void sync(const(RelTuple)[] rows) {
        if (indexed == rows.length)
            return;
        if (rows.length * 2 > heads.length) {
            size_t capacity = heads.length < 16 ? 16 : heads.length;
            while (capacity < rows.length * 2)
                capacity *= 2;
            heads = new int[capacity];
            indexed = 0;
        }
        if (next.length < rows.length) {
            auto grown = new int[rows.length < 16 ? 16 : rows.length + rows.length / 2];
            grown[0 .. indexed] = next[0 .. indexed];
            next = grown;
        }
        size_t bucketMask = heads.length - 1;
        foreach (row; indexed .. rows.length) {
            size_t bucket = hashRow(rows[row].values, mask) & bucketMask;
            next[row] = heads[bucket];
            heads[bucket] = cast(int) row + 1;
        }
        indexed = rows.length;
    }

    /// First candidate row + 1 for a key hash (0 when none). Candidates share a bucket, not
    /// necessarily the key: the caller compares the key columns.
    pragma(inline, true)
    int first(size_t keyHash) const @nogc nothrow @safe {
        return heads.length ? heads[keyHash & (heads.length - 1)] : 0;
    }
}

final class FactTable {
    int arity;
    RelTuple[] rows;
    bool frozen;
    private MaskIndex[] indexes;
    private MaskIndex full; // all columns: membership and de-duplication

    this(int arity) {
        this.arity = arity;
    }

    static ColumnMask fullMask(int arity) @nogc nothrow pure @safe {
        return arity >= 32 ? uint.max : (1u << arity) - 1;
    }

    /// A frozen table over existing tuples (they are shared, not copied).
    static FactTable frozenFrom(RelTuple[] tuples, int arity) {
        auto table = new FactTable(arity);
        table.rows = tuples;
        table.frozen = true;
        return table;
    }

    /// The index for `mask`, built or extended on demand (allocation point).
    MaskIndex index(ColumnMask mask) {
        foreach (existing; indexes)
            if (existing.mask == mask) {
                existing.sync(rows);
                return existing;
            }
        auto created = new MaskIndex(mask);
        created.sync(rows);
        indexes ~= created;
        return created;
    }

    private MaskIndex fullIndex() {
        if (full is null)
            full = index(fullMask(arity));
        else
            full.sync(rows);
        return full;
    }

    pragma(inline, true)
    private static bool sameValues(const(LuaValue)[] a, const(LuaValue)[] b) @trusted {
        if (a.length != b.length)
            return false;
        foreach (i; 0 .. a.length)
            if (!luaRawEqual(cast(LuaValue) a[i], cast(LuaValue) b[i]))
                return false;
        return true;
    }

    /// Whether a tuple with exactly these values is present. A wrong-length key is never present.
    bool contains(const(LuaValue)[] values) {
        if (values.length != cast(size_t) arity || rows.length == 0)
            return false;
        auto idx = fullIndex();
        for (int at = idx.first(MaskIndex.hashRow(values, idx.mask)); at != 0; at = idx.next[at - 1])
            if (sameValues(rows[at - 1].values, values))
                return true;
        return false;
    }

    /// Adds a tuple unless an equal one is present; returns whether it was added. The tuple's
    /// value array is retained, so the caller must not reuse it.
    bool insert(RelTuple tuple) {
        assert(!frozen);
        if (contains(tuple.values))
            return false;
        rows ~= tuple;
        return true;
    }
}

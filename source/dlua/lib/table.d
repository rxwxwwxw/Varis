/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

/// Table manipulation library: a port of ltablib.c.
module dlua.lib.table;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.vm;
import dlua.exception : LuaException;
import dlua.lib.auxlib;
import std.array : appender;

private enum TAB_R = 1, TAB_W = 2, TAB_L = 4, TAB_RW = TAB_R | TAB_W;

private void checkTab(LuaState L, LuaValue[] a, int arg, int what) {
    if (arg <= a.length && isTable(a[arg - 1])) return;
    if (arg <= a.length) {
        auto mt = L.getMetatable(a[arg - 1]);
        if (mt !is null &&
            (!(what & TAB_R) || !isNil(mt.rawget(LuaValue("__index")))) &&
            (!(what & TAB_W) || !isNil(mt.rawget(LuaValue("__newindex")))) &&
            (!(what & TAB_L) || !isNil(mt.rawget(LuaValue("__len"))))) return;
    }
    typeError(L, a, arg, "table");
}

private LuaValue geti(LuaState L, LuaValue t, long i) {
    if (isTable(t)) {
        auto table = t.match!((LuaTable x) => x, _ => null);
        auto raw = table.rawgetInt(i);
        if (!isNil(raw) || table.metatable is null) return raw;
    }
    return VM.getTable(L, t, LuaValue(i));
}

private void seti(LuaState L, LuaValue t, long i, LuaValue v) {
    if (isTable(t)) {
        auto table = t.match!((LuaTable x) => x, _ => null);
        if (table.metatable is null) {
            // A plain table needs no metamethod lookup: store directly.
            ulong slot = cast(ulong)i - 1;
            if (slot < table.arrayPart.length) table.arrayPart[cast(size_t)slot] = v;
            else table.rawset(LuaValue(i), v);
            return;
        }
    }
    VM.setTable(L, t, LuaValue(i), v);
}

/// `table.insert(t, pos, v)` on a plain sequence stored in the array part: one block move instead
/// of element-wise reads and writes. Returns false (nothing changed) when the generic path must run.
private bool shiftInsert(LuaValue t, long e, long pos, LuaValue v) {
    if (!isTable(t)) return false;
    auto table = t.match!((LuaTable x) => x, _ => null);
    if (table.metatable !is null || pos < 1 || pos > e || e < 1) return false;
    size_t n = cast(size_t)(e - 1);
    if (n > table.arrayPart.length) return false;
    if (pos == e) { table.rawset(LuaValue(e), v); return true; }
    table.rawset(LuaValue(e), table.arrayPart[n - 1]);
    auto arr = table.arrayPart;
    if (arr.length < cast(size_t)e) return false;
    import core.stdc.string : memmove;
    memmove(cast(void*)&arr[cast(size_t)pos], cast(const(void)*)&arr[cast(size_t)pos - 1], (n - cast(size_t)pos) * LuaValue.sizeof);
    arr[cast(size_t)pos - 1] = v;
    return true;
}

/// `table.remove(t, pos)` for 1 <= pos <= size on a plain sequence in the array part.
private bool shiftRemove(LuaValue t, long size, long pos, out LuaValue removed) {
    if (!isTable(t)) return false;
    auto table = t.match!((LuaTable x) => x, _ => null);
    if (table.metatable !is null || pos < 1 || pos > size) return false;
    size_t n = cast(size_t)size;
    if (n > table.arrayPart.length) return false;
    auto arr = table.arrayPart;
    removed = arr[cast(size_t)pos - 1];
    import core.stdc.string : memmove;
    memmove(cast(void*)&arr[cast(size_t)pos - 1], cast(const(void)*)&arr[cast(size_t)pos], (n - cast(size_t)pos) * LuaValue.sizeof);
    arr[n - 1] = luaNil();
    return true;
}

/// luaL_len: length honoring __len, which must produce an integer.
private long lenOf(LuaState L, LuaValue t) {
    auto n = VM.opLen(L, t);
    long result;
    if (!isInteger(n) && !(isFloat(n) && floatToInteger(n.match!((double d) => d, _ => 0.0), result)))
        throw new LuaException("object length is not an integer");
    return isInteger(n) ? n.match!((long i) => i, _ => 0L) : result;
}

private long auxGetN(LuaState L, LuaValue[] a, int arg, int what) {
    checkTab(L, a, arg, what | TAB_L);
    return lenOf(L, a[arg - 1]);
}

// --- sort -------------------------------------------------------------------

private struct Sorter {
    LuaState L;
    LuaValue table;
    LuaValue comparator;
    bool hasComparator;

    bool less(LuaValue x, LuaValue y) {
        if (!hasComparator) return VM.opLt(L, x, y);
        // The callee copies its arguments on entry, so a stack buffer is enough.
        LuaValue[2] arguments = [x, y];
        auto r = VM.callValue(L, comparator, arguments[]);
        return r.length && isTruthy(r[0]);
    }

    LuaValue get(uint i) { return geti(L, table, i); }
    void set(uint i, LuaValue v) { seti(L, table, i, v); }

    uint partition(uint lo, uint up, LuaValue P) {
        uint i = lo;
        uint j = up - 1;
        for (;;) {
            LuaValue ai, aj;
            while (true) {
                ai = get(++i);
                if (!less(ai, P)) break;
                if (i == up - 1) throw new LuaException("invalid order function for sorting");
            }
            while (true) {
                aj = get(--j);
                if (!less(P, aj)) break;
                if (j < i) throw new LuaException("invalid order function for sorting");
            }
            if (j < i) {
                set(up - 1, ai);
                set(i, P);
                return i;
            }
            set(i, aj);
            set(j, ai);
        }
    }

    static uint choosePivot(uint lo, uint up, uint rnd) {
        uint r4 = (up - lo) / 4;
        return rnd % (r4 * 2) + (lo + r4);
    }

    void auxsort(uint lo, uint up, uint rnd) {
        while (lo < up) {
            uint p, n;
            auto vlo = get(lo);
            auto vup = get(up);
            if (less(vup, vlo)) { set(lo, vup); set(up, vlo); }
            if (up - lo == 1) return;
            if (up - lo < 100u || rnd == 0) p = (lo + up) / 2;
            else p = choosePivot(lo, up, rnd);
            auto vp = get(p);
            vlo = get(lo);
            if (less(vp, vlo)) { set(p, vlo); set(lo, vp); }
            else {
                vup = get(up);
                if (less(vup, vp)) { set(p, vup); set(up, vp); }
            }
            if (up - lo == 2) return;
            auto P = get(p);
            auto vup1 = get(up - 1);
            set(p, vup1);
            set(up - 1, P);
            p = partition(lo, up, P);
            if (p - lo < up - p) {
                auxsort(lo, p - 1, rnd);
                n = p - lo;
                lo = p + 1;
            } else {
                auxsort(p + 1, up, rnd);
                n = up - p;
                up = p - 1;
            }
            if ((up - lo) / 128 > n) {
                import core.stdc.time : clock, time;
                rnd = cast(uint)(clock() + time(null));
            }
        }
    }
}

void openTableLib(LuaState state) {
    auto tab = new LuaTable();

    tab.register("insert", (LuaState L, LuaValue[] a) {
        long e = auxGetN(L, a, 1, TAB_RW);
        e = cast(long)(cast(ulong)e + 1);
        long pos;
        switch (a.length) {
            case 2: pos = e; break;
            case 3: {
                pos = checkInteger(L, a, 2);
                if (!(cast(ulong)pos - 1u < cast(ulong)e)) throw new ArgError(2, "position out of bounds");
                if (shiftInsert(a[0], e, pos, a[2])) return cast(LuaValue[])[];
                for (long i = e; i > pos; i--) seti(L, a[0], i, geti(L, a[0], i - 1));
                break;
            }
            default: throw new LuaException("wrong number of arguments to 'insert'");
        }
        seti(L, a[0], pos, a[a.length - 1]);
        return cast(LuaValue[])[];
    });

    tab.register("remove", (LuaState L, LuaValue[] a) {
        long size = auxGetN(L, a, 1, TAB_RW);
        long pos = optInteger(L, a, 2, size);
        if (pos != size && !(cast(ulong)pos - 1u <= cast(ulong)size))
            throw new ArgError(2, "position out of bounds");
        LuaValue shifted;
        if (shiftRemove(a[0], size, pos, shifted)) return [shifted];
        auto result = geti(L, a[0], pos);
        for (; pos < size; pos++) seti(L, a[0], pos, geti(L, a[0], pos + 1));
        seti(L, a[0], pos, luaNil());
        return [result];
    });

    tab.register("move", (LuaState L, LuaValue[] a) {
        long f = checkInteger(L, a, 2);
        long e = checkInteger(L, a, 3);
        long t = checkInteger(L, a, 4);
        int tt = !isNoneOrNil(a, 5) ? 5 : 1;
        checkTab(L, a, 1, TAB_R);
        checkTab(L, a, tt, TAB_W);
        if (e >= f) {
            if (!(f > 0 || e < long.max + f)) throw new ArgError(3, "too many elements to move");
            long n = e - f + 1;
            if (!(t <= long.max - n + 1)) throw new ArgError(4, "destination wrap around");
            if (t > e || t <= f || (tt != 1 && !luaRawEqual(a[0], a[tt - 1]))) {
                for (long i = 0; i < n; i++) seti(L, a[tt - 1], t + i, geti(L, a[0], f + i));
            } else {
                for (long i = n - 1; i >= 0; i--) seti(L, a[tt - 1], t + i, geti(L, a[0], f + i));
            }
        }
        return [a[tt - 1]];
    });

    tab.register("concat", (LuaState L, LuaValue[] a) {
        long last = auxGetN(L, a, 1, TAB_R);
        string sep = optString(L, a, 2, "");
        long i = optInteger(L, a, 3, 1);
        last = optInteger(L, a, 4, last);
        auto b = appender!string();
        void addField(long idx) {
            auto v = geti(L, a[0], idx);
            if (!isString(v) && !isNumber(v))
                throw new LuaException("invalid value (" ~ typeName(v) ~ ") at index " ~ idx.to!string ~ " in table for 'concat'");
            b.put(toLuaString(v));
        }
        for (; i < last; i++) { addField(i); b.put(sep); }
        if (i == last) addField(i);
        return [LuaValue(b.data)];
    });

    tab.register("pack", (LuaState L, LuaValue[] a) {
        auto t = new LuaTable(a.length, 1);
        foreach (i, v; a) t.rawset(LuaValue(cast(long)i + 1), v);
        t.rawset(LuaValue("n"), LuaValue(cast(long)a.length));
        return [LuaValue(t)];
    });

    tab.register("unpack", (LuaState L, LuaValue[] a) {
        long i = optInteger(L, a, 2, 1);
        long e = isNoneOrNil(a, 3) ? lenOf(L, argAt(a, 1)) : checkInteger(L, a, 3);
        if (i > e) return cast(LuaValue[])[];
        ulong n = cast(ulong)e - cast(ulong)i;
        if (n >= 1_000_000 - L.currentThread().stackSlots - 40) throw new LuaException("too many results to unpack");
        auto result = new LuaValue[cast(size_t)n + 1];
        foreach (k; 0 .. cast(size_t)n + 1) result[k] = geti(L, a[0], i + cast(long)k);
        return result;
    });

    tab.register("sort", (LuaState L, LuaValue[] a) {
        long n = auxGetN(L, a, 1, TAB_RW);
        if (n > 1) {
            if (!(n < int.max)) throw new ArgError(1, "array too big");
            if (!isNoneOrNil(a, 2) && !isFunction(a[1])) typeError(L, a, 2, "function");
            Sorter s = Sorter(L, a[0], argAt(a, 2), !isNoneOrNil(a, 2));
            s.auxsort(1, cast(uint)n, 0);
        }
        return cast(LuaValue[])[];
    }, true);

    state.setGlobal("table", LuaValue(tab));
}

import std.conv : to;

/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Table manipulation library: a port of ltablib.c.
module varis.lib.table;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.lib.auxlib;
import std.array : appender;

private enum TAB_R = 1, TAB_W = 2, TAB_L = 4, TAB_RW = TAB_R | TAB_W;

// This module reports errors as values (varis.lib.auxlib, status forms): it contains no `throw`.
// A function returning bool has reported an error in the state's slot when it returns false.
private bool argTab(LuaState L, LuaValue[] a, int arg, int what) {
    if (arg <= a.length && isTable(a[arg - 1]))
        return true;
    if (arg <= a.length) {
        auto mt = L.getMetatable(a[arg - 1]);
        if (mt !is null &&
                (!(what & TAB_R) || !isNil(mt.rawget(LuaValue("__index")))) &&
                (!(what & TAB_W) || !isNil(mt.rawget(LuaValue("__newindex")))) &&
                (!(what & TAB_L) || !isNil(mt.rawget(LuaValue("__len")))))
            return true;
    }
    return typeFail(L, a, arg, "table");
}

private LuaValue geti(LuaState L, LuaValue t, long i) {
    if (isTable(t)) {
        auto table = t.match!((LuaTable x) => x, _ => null);
        auto raw = table.rawgetInt(i);
        if (!isNil(raw) || table.metatable is null)
            return raw;
    }
    return VM.getTable(L, t, LuaValue(i));
}

private void seti(LuaState L, LuaValue t, long i, LuaValue v) {
    if (isTable(t)) {
        auto table = t.match!((LuaTable x) => x, _ => null);
        if (table.metatable is null) {
            // A plain table needs no metamethod lookup: store directly.
            ulong slot = cast(ulong) i - 1;
            if (slot < table.arrayPart.length)
                table.arrayPart[cast(size_t) slot] = v;
            else
                table.rawset(LuaValue(i), v);
            return;
        }
    }
    VM.setTable(L, t, LuaValue(i), v);
}

/// `table.insert(t, pos, v)` on a plain sequence stored in the array part: one block move instead
/// of element-wise reads and writes. Returns false (nothing changed) when the generic path must run.
private bool shiftInsert(LuaValue t, long e, long pos, LuaValue v) {
    if (!isTable(t))
        return false;
    auto table = t.match!((LuaTable x) => x, _ => null);
    if (table.metatable !is null || pos < 1 || pos > e || e < 1)
        return false;
    size_t n = cast(size_t)(e - 1);
    if (n > table.arrayPart.length)
        return false;
    if (pos == e) {
        table.rawset(LuaValue(e), v);
        return true;
    }
    table.rawset(LuaValue(e), table.arrayPart[n - 1]);
    auto arr = table.arrayPart;
    if (arr.length < cast(size_t) e)
        return false;
    import core.stdc.string : memmove;

    memmove(cast(void*)&arr[cast(size_t) pos], cast(const(void)*)&arr[cast(size_t) pos - 1], (n - cast(size_t) pos) * LuaValue
            .sizeof);
    arr[cast(size_t) pos - 1] = v;
    return true;
}

/// `table.remove(t, pos)` for 1 <= pos <= size on a plain sequence in the array part.
private bool shiftRemove(LuaValue t, long size, long pos, out LuaValue removed) {
    if (!isTable(t))
        return false;
    auto table = t.match!((LuaTable x) => x, _ => null);
    if (table.metatable !is null || pos < 1 || pos > size)
        return false;
    size_t n = cast(size_t) size;
    if (n > table.arrayPart.length)
        return false;
    auto arr = table.arrayPart;
    removed = arr[cast(size_t) pos - 1];
    import core.stdc.string : memmove;

    // `arr.ptr + pos` may be one past the last element (removing the last one moves nothing).
    memmove(cast(void*)(arr.ptr + (cast(size_t) pos - 1)), cast(const(void)*)(arr.ptr + cast(size_t) pos),
            (n - cast(size_t) pos) * LuaValue.sizeof);
    arr[n - 1] = luaNil();
    return true;
}

/// luaL_len: length honoring __len, which must produce an integer.
private bool lenOf(LuaState L, LuaValue t, out long length) {
    auto n = VM.opLen(L, t);
    long result;
    if (!isInteger(n) && !(isFloat(n) && floatToInteger(n.match!((double d) => d, _ => 0.0), result))) {
        raise(L, "object length is not an integer");
        return false;
    }
    length = isInteger(n) ? n.match!((long i) => i, _ => 0L) : result;
    return true;
}

private bool auxGetN(LuaState L, LuaValue[] a, int arg, int what, out long length) {
    return argTab(L, a, arg, what | TAB_L) && lenOf(L, a[arg - 1], length);
}

// --- sort -------------------------------------------------------------------

private struct Sorter {
    LuaState L;
    LuaValue table;
    LuaValue comparator;
    bool hasComparator;

    bool less(LuaValue x, LuaValue y) {
        if (!hasComparator)
            return VM.opLt(L, x, y);
        // The callee copies its arguments on entry, so a stack buffer is enough.
        LuaValue[2] arguments = [x, y];
        auto r = VM.callValue(L, comparator, arguments[]);
        return r.length && isTruthy(r[0]);
    }

    LuaValue get(uint i) {
        return geti(L, table, i);
    }

    void set(uint i, LuaValue v) {
        seti(L, table, i, v);
    }

    /// Returns false after reporting "invalid order function".
    bool partition(uint lo, uint up, LuaValue P, out uint position) {
        uint i = lo;
        uint j = up - 1;
        for (;;) {
            LuaValue ai, aj;
            while (true) {
                ai = get(++i);
                if (!less(ai, P))
                    break;
                if (i == up - 1) {
                    raise(L, "invalid order function for sorting");
                    return false;
                }
            }
            while (true) {
                aj = get(--j);
                if (!less(P, aj))
                    break;
                if (j < i) {
                    raise(L, "invalid order function for sorting");
                    return false;
                }
            }
            if (j < i) {
                set(up - 1, ai);
                set(i, P);
                position = i;
                return true;
            }
            set(i, aj);
            set(j, ai);
        }
    }

    static uint choosePivot(uint lo, uint up, uint rnd) {
        uint r4 = (up - lo) / 4;
        return rnd % (r4 * 2) + (lo + r4);
    }

    /// ditto
    bool auxsort(uint lo, uint up, uint rnd) {
        while (lo < up) {
            uint p, n;
            auto vlo = get(lo);
            auto vup = get(up);
            if (less(vup, vlo)) {
                set(lo, vup);
                set(up, vlo);
            }
            if (up - lo == 1)
                return true;
            if (up - lo < 100u || rnd == 0)
                p = (lo + up) / 2;
            else
                p = choosePivot(lo, up, rnd);
            auto vp = get(p);
            vlo = get(lo);
            if (less(vp, vlo)) {
                set(p, vlo);
                set(lo, vp);
            } else {
                vup = get(up);
                if (less(vup, vp)) {
                    set(p, vup);
                    set(up, vp);
                }
            }
            if (up - lo == 2)
                return true;
            auto P = get(p);
            auto vup1 = get(up - 1);
            set(p, vup1);
            set(up - 1, P);
            if (!partition(lo, up, P, p))
                return false;
            if (p - lo < up - p) {
                if (!auxsort(lo, p - 1, rnd))
                    return false;
                n = p - lo;
                lo = p + 1;
            } else {
                if (!auxsort(p + 1, up, rnd))
                    return false;
                n = up - p;
                up = p - 1;
            }
            if ((up - lo) / 128 > n) {
                import core.stdc.time : clock, time;

                rnd = cast(uint)(clock() + time(null));
            }
        }
        return true;
    }
}

void openTableLib(LuaState state) {
    auto tab = new LuaTable();

    tab.register("insert", (LuaState L, LuaValue[] a) {
        long e;
        if (!auxGetN(L, a, 1, TAB_RW, e))
            return null;
        e = cast(long)(cast(ulong) e + 1);
        long pos;
        switch (a.length) {
        case 2:
            pos = e;
            break;
        case 3: {
                if (!argInteger(L, a, 2, pos))
                    return null;
                if (!(cast(ulong) pos - 1u < cast(ulong) e))
                    return argFail(L, 2, "position out of bounds");
                if (shiftInsert(a[0], e, pos, a[2]))
                    return cast(LuaValue[])[];
                for (long i = e; i > pos; i--)
                    seti(L, a[0], i, geti(L, a[0], i - 1));
                break;
            }
        default:
            return raise(L, "wrong number of arguments to 'insert'");
        }
        seti(L, a[0], pos, a[a.length - 1]);
        return cast(LuaValue[])[];
    });

    tab.register("remove", (LuaState L, LuaValue[] a) {
        long size, pos;
        if (!auxGetN(L, a, 1, TAB_RW, size) || !argOptInteger(L, a, 2, size, pos))
            return null;
        if (pos != size && !(cast(ulong) pos - 1u <= cast(ulong) size))
            return argFail(L, 2, "position out of bounds");
        LuaValue shifted;
        if (shiftRemove(a[0], size, pos, shifted))
            return [shifted];
        auto result = geti(L, a[0], pos);
        for (; pos < size; pos++)
            seti(L, a[0], pos, geti(L, a[0], pos + 1));
        seti(L, a[0], pos, luaNil());
        return [result];
    });

    tab.register("move", (LuaState L, LuaValue[] a) {
        long f, e, t;
        if (!argInteger(L, a, 2, f) || !argInteger(L, a, 3, e) || !argInteger(L, a, 4, t))
            return null;
        int tt = !isNoneOrNil(a, 5) ? 5 : 1;
        if (!argTab(L, a, 1, TAB_R) || !argTab(L, a, tt, TAB_W))
            return null;
        if (e >= f) {
            if (!(f > 0 || e < long.max + f))
                return argFail(L, 3, "too many elements to move");
            long n = e - f + 1;
            if (!(t <= long.max - n + 1))
                return argFail(L, 4, "destination wrap around");
            if (t > e || t <= f || (tt != 1 && !luaRawEqual(a[0], a[tt - 1]))) {
                for (long i = 0; i < n; i++)
                    seti(L, a[tt - 1], t + i, geti(L, a[0], f + i));
            } else {
                for (long i = n - 1; i >= 0; i--)
                    seti(L, a[tt - 1], t + i, geti(L, a[0], f + i));
            }
        }
        return [a[tt - 1]];
    });

    tab.register("concat", (LuaState L, LuaValue[] a) {
        long last, i;
        string sep;
        if (!auxGetN(L, a, 1, TAB_R, last) || !argOptString(L, a, 2, "", sep) || !argOptInteger(L, a, 3, 1, i)
            || !argOptInteger(L, a, 4, last, last))
            return null;
        auto b = appender!string();
        bool addField(long idx) {
            auto v = geti(L, a[0], idx);
            if (!isString(v) && !isNumber(v)) {
                raise(L, "invalid value (" ~ typeName(v) ~ ") at index " ~ idx.to!string ~ " in table for 'concat'");
                return false;
            }
            b.put(toLuaString(v));
            return true;
        }

        for (; i < last; i++) {
            if (!addField(i))
                return null;
            b.put(sep);
        }
        if (i == last && !addField(i))
            return null;
        return [LuaValue(b.data)];
    });

    tab.register("pack", (LuaState L, LuaValue[] a) {
        auto t = new LuaTable(a.length, 1);
        foreach (i, v; a)
            t.rawset(LuaValue(cast(long) i + 1), v);
        t.rawset(LuaValue("n"), LuaValue(cast(long) a.length));
        return [LuaValue(t)];
    });

    tab.register("unpack", (LuaState L, LuaValue[] a) {
        long i, e;
        if (!argOptInteger(L, a, 2, 1, i))
            return null;
        if (isNoneOrNil(a, 3) ? !lenOf(L, argAt(a, 1), e) : !argInteger(L, a, 3, e))
            return null;
        if (i > e)
            return cast(LuaValue[])[];
        ulong n = cast(ulong) e - cast(ulong) i;
        if (n >= 1_000_000 - L.currentThread().stackUse() - 40)
            return raise(L, "too many results to unpack");
        auto result = new LuaValue[cast(size_t) n + 1];
        foreach (k; 0 .. cast(size_t) n + 1)
            result[k] = geti(L, a[0], i + cast(long) k);
        return result;
    });

    tab.register("sort", (LuaState L, LuaValue[] a) {
        long n;
        if (!auxGetN(L, a, 1, TAB_RW, n))
            return null;
        if (n > 1) {
            if (!(n < int.max))
                return argFail(L, 1, "array too big");
            if (!isNoneOrNil(a, 2) && !isFunction(a[1])) {
                typeFail(L, a, 2, "function");
                return null;
            }
            Sorter s = Sorter(L, a[0], argAt(a, 2), !isNoneOrNil(a, 2));
            if (!s.auxsort(1, cast(uint) n, 0))
                return null;
        }
        return cast(LuaValue[])[];
    }, true);

    state.setGlobal("table", LuaValue(tab));
}

import std.conv : to;

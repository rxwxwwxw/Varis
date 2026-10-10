/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Mathematical library: a port of lmathlib.c.
module varis.lib.math;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.lib.auxlib;
static import std.math;
static import core.stdc.math;
import core.stdc.math : fmod, log2, log10;

private enum double PI = 3.141592653589793238462643383279502884;

private LuaValue numInt(double d) {
    long n;
    if (floatToInteger(d, n))
        return LuaValue(n);
    return LuaValue(d);
}

private bool rotatedLeft(ulong x, int n, out ulong r) {
    r = (x << n) | (x >> (64 - n));
    return true;
}

private ulong rotl(ulong x, int n) {
    return (x << n) | (x >> (64 - n));
}

private struct RanState {
    ulong[4] s;

    ulong next() {
        ulong state0 = s[0];
        ulong state1 = s[1];
        ulong state2 = s[2] ^ state0;
        ulong state3 = s[3] ^ state1;
        ulong res = rotl(state1 * 5, 7) * 9;
        s[0] = state0 ^ state3;
        s[1] = state1 ^ state2;
        s[2] = state2 ^ (state1 << 17);
        s[3] = rotl(state3, 45);
        return res;
    }

    void seed(ulong n1, ulong n2) {
        s[0] = n1;
        s[1] = 0xff;
        s[2] = n2;
        s[3] = 0;
        foreach (i; 0 .. 16)
            next();
    }

    ulong project(ulong ran, ulong n) {
        if ((n & (n + 1)) == 0)
            return ran & n;
        ulong lim = n;
        lim |= (lim >> 1);
        lim |= (lim >> 2);
        lim |= (lim >> 4);
        lim |= (lim >> 8);
        lim |= (lim >> 16);
        lim |= (lim >> 32);
        while ((ran &= lim) > n)
            ran = next();
        return ran;
    }
}

private double toFloat01(ulong x) {
    // 53 significant bits scaled into [0, 1)
    return cast(double)(x >> 11) * (0.5 / (1UL << 52));
}

void openMathLib(LuaState state) {
    auto m = new LuaTable();

    m.register("abs", (LuaState L, LuaValue[] a) {
        if (a.length && isInteger(a[0])) {
            long n = a[0].match!((long i) => i, _ => 0L);
            if (n < 0)
                n = cast(long)(0UL - cast(ulong) n);
            return [LuaValue(n)];
        }
        return [LuaValue(std.math.fabs(checkNumber(L, a, 1)))];
    });
    m.register("sin", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.sin(checkNumber(L, a, 1)))
    ]);
    m.register("cos", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.cos(checkNumber(L, a, 1)))
    ]);
    m.register("tan", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.tan(checkNumber(L, a, 1)))
    ]);
    m.register("asin", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.asin(checkNumber(L, a, 1)))
    ]);
    m.register("acos", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.acos(checkNumber(L, a, 1)))
    ]);
    m.register("atan", (LuaState L, LuaValue[] a) {
        double y = checkNumber(L, a, 1);
        double x = optNumber(L, a, 2, 1);
        return [LuaValue(core.stdc.math.atan2(y, x))];
    });
    m.register("tointeger", (LuaState L, LuaValue[] a) {
        long n;
        if (a.length && toIntegerArg(a[0], n))
            return [LuaValue(n)];
        checkAny(a, 1);
        return [luaNil()];
    });
    m.register("floor", (LuaState L, LuaValue[] a) {
        if (a.length && isInteger(a[0]))
            return [a[0]];
        return [numInt(std.math.floor(checkNumber(L, a, 1)))];
    });
    m.register("ceil", (LuaState L, LuaValue[] a) {
        if (a.length && isInteger(a[0]))
            return [a[0]];
        return [numInt(std.math.ceil(checkNumber(L, a, 1)))];
    });
    m.register("fmod", (LuaState L, LuaValue[] a) {
        if (a.length > 1 && isInteger(a[0]) && isInteger(a[1])) {
            long d = a[1].match!((long i) => i, _ => 0L);
            if (cast(ulong) d + 1u <= 1u) {
                if (d == 0)
                    throw new ArgError(2, "zero");
                return [LuaValue(0L)];
            }
            return [LuaValue(a[0].match!((long i) => i, _ => 0L) % d)];
        }
        return [LuaValue(fmod(checkNumber(L, a, 1), checkNumber(L, a, 2)))];
    });
    m.register("modf", (LuaState L, LuaValue[] a) {
        if (a.length && isInteger(a[0]))
            return [a[0], LuaValue(0.0)];
        double n = checkNumber(L, a, 1);
        double ip = n < 0 ? std.math.ceil(n) : std.math.floor(n);
        return [numInt(ip), LuaValue(n == ip ? 0.0 : n - ip)];
    });
    m.register("sqrt", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.sqrt(checkNumber(L, a, 1)))
    ]);
    m.register("ult", (LuaState L, LuaValue[] a) =>
            [LuaValue(cast(ulong) checkInteger(L, a, 1) < cast(ulong) checkInteger(L, a, 2))]);
    m.register("log", (LuaState L, LuaValue[] a) {
        double x = checkNumber(L, a, 1);
        double res;
        if (isNoneOrNil(a, 2))
            res = core.stdc.math.log(x);
        else {
            double base = checkNumber(L, a, 2);
            if (base == 2.0)
                res = log2(x);
            else if (base == 10.0)
                res = log10(x);
            else
                res = core.stdc.math.log(x) / core.stdc.math.log(base);
        }
        return [LuaValue(res)];
    });
    m.register("exp", (LuaState L, LuaValue[] a) => [
        LuaValue(core.stdc.math.exp(checkNumber(L, a, 1)))
    ]);
    m.register("deg", (LuaState L, LuaValue[] a) => [LuaValue(checkNumber(L, a, 1) * (180.0 / PI))]);
    m.register("rad", (LuaState L, LuaValue[] a) => [LuaValue(checkNumber(L, a, 1) * (PI / 180.0))]);
    m.register("min", (LuaState L, LuaValue[] a) {
        if (a.length < 1)
            throw new ArgError(1, "value expected");
        size_t imin = 0;
        foreach (i; 1 .. a.length) {
            if (VM.opLt(L, a[i], a[imin]))
                imin = i;
        }
        return [a[imin]];
    });
    m.register("max", (LuaState L, LuaValue[] a) {
        if (a.length < 1)
            throw new ArgError(1, "value expected");
        size_t imax = 0;
        foreach (i; 1 .. a.length) {
            if (VM.opLt(L, a[imax], a[i]))
                imax = i;
        }
        return [a[imax]];
    });
    m.register("type", (LuaState L, LuaValue[] a) {
        if (a.length && isNumber(a[0]))
            return [LuaValue(isInteger(a[0]) ? "integer" : "float")];
        checkAny(a, 1);
        return [luaNil()];
    });

    auto rng = new RanState();
    {
        import core.stdc.time : time;

        rng.seed(cast(ulong) time(null), cast(ulong) cast(size_t) cast(void*) state);
    }
    m.register("random", (LuaState L, LuaValue[] a) {
        ulong rv = rng.next();
        long low, up;
        switch (a.length) {
        case 0:
            return [LuaValue(toFloat01(rv))];
        case 1:
            low = 1;
            up = checkInteger(L, a, 1);
            if (up == 0)
                return [LuaValue(cast(long) rv)];
            break;
        case 2:
            low = checkInteger(L, a, 1);
            up = checkInteger(L, a, 2);
            break;
        default:
            throw new LuaException("wrong number of arguments");
        }
        if (!(low <= up))
            throw new ArgError(1, "interval is empty");
        ulong p = rng.project(rv, cast(ulong) up - cast(ulong) low);
        return [LuaValue(cast(long)(p + cast(ulong) low))];
    });
    m.register("randomseed", (LuaState L, LuaValue[] a) {
        ulong n1, n2;
        if (a.length == 0) {
            import core.stdc.time : time;

            n1 = cast(ulong) time(null);
            n2 = cast(ulong) cast(size_t) cast(void*) L;
        } else {
            n1 = cast(ulong) checkInteger(L, a, 1);
            n2 = cast(ulong) optInteger(L, a, 2, 0);
        }
        rng.seed(n1, n2);
        return [LuaValue(cast(long) n1), LuaValue(cast(long) n2)];
    });

    m.rawset(LuaValue("pi"), LuaValue(PI));
    m.rawset(LuaValue("huge"), LuaValue(double.infinity));
    m.rawset(LuaValue("maxinteger"), LuaValue(long.max));
    m.rawset(LuaValue("mininteger"), LuaValue(long.min));

    state.setGlobal("math", LuaValue(m));
}

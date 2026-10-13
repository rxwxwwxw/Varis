/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Argument checking helpers modelled on lauxlib.c.
module varis.lib.auxlib;

import varis.types;
import varis.table;
import varis.state;
import varis.exception : LuaException;
import std.format : format;
import std.conv : to;

/// Raised for invalid library arguments. `VM.callValue` rewrites the message
/// once the call-site name of the failing native function is known.
class ArgError : LuaException {
    int arg;
    string extra;
    bool formatted;
    LuaFunction function_;

    this(int arg, string extra) {
        super("bad argument #" ~ arg.to!string ~ " (" ~ extra ~ ")");
        this.arg = arg;
        this.extra = extra;
    }
}

/// Registers `fn` in `table` under `name` as a native function.
void register(LuaTable table, string name, LuaValue[]delegate(LuaState, LuaValue[]) fn, bool nonYielding = false) {
    table.rawset(LuaValue(name), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                return fn(cast(LuaState) s, args);
            }, name, nonYielding)));
}

alias registerDelegate = register;

string objectTypeName(LuaState state, LuaValue v) {
    if (isTable(v) || v.typeOf() == LuaType.UserData) {
        auto mt = state is null ? null : state.getMetatable(v);
        if (mt !is null) {
            auto name = mt.rawget(LuaValue("__name"));
            if (isString(name))
                return toLuaString(name);
        }
    }
    if (v.typeOf() == LuaType.LightUserData)
        return "light userdata";
    return typeName(v);
}

bool isNone(LuaValue[] a, int n) {
    return n > a.length;
}

bool isNoneOrNil(LuaValue[] a, int n) {
    return n > a.length || isNil(a[n - 1]);
}

LuaValue argAt(LuaValue[] a, int n) {
    return n > a.length ? luaNil() : a[n - 1];
}

/// Converts the value at `n` to an integer following lua_tointegerx (strings allowed).
bool toIntegerArg(LuaValue v, out long result) {
    if (isInteger(v)) {
        result = v.match!((long i) => i, _ => 0L);
        return true;
    }
    if (isFloat(v))
        return floatToInteger(v.match!((double d) => d, _ => 0.0), result);
    if (isString(v)) {
        LuaValue number;
        if (!parseLuaNumber(v.match!((string s) => s, _ => ""), number))
            return false;
        return toIntegerArg(number, result);
    }
    return false;
}

bool toNumberArg(LuaValue v, out double result) {
    if (isInteger(v)) {
        result = cast(double) v.match!((long i) => i, _ => 0L);
        return true;
    }
    if (isFloat(v)) {
        result = v.match!((double d) => d, _ => 0.0);
        return true;
    }
    if (isString(v)) {
        LuaValue number;
        if (!parseLuaNumber(v.match!((string s) => s, _ => ""), number))
            return false;
        return toNumberArg(number, result);
    }
    return false;
}

// ---------------------------------------------------------------------------------------
// Errors as values (performance plan, stage L1). An `arg*` function returns false after reporting the
// error in the state's error slot, and the native then returns at once:
//
//     double x;
//     if (!argNumber(L, a, 1, x))
//         return null;
//
// `argFail` reports a bad argument directly: `return argFail(L, 2, "zero");`.
// A converted module contains no `throw`; the throwing `check*`/`opt*` forms no longer exist.

LuaValue[] argFail(LuaState L, int n, string extra) {
    return raise(L, new ArgError(n, extra));
}

/// Reports "EXPECTED expected, got ..." for argument `n`; always returns false.
bool typeFail(LuaState L, LuaValue[] a, int n, string expected) {
    string actual = n > a.length ? "no value" : objectTypeName(L, a[n - 1]);
    raise(L, new ArgError(n, expected ~ " expected, got " ~ actual));
    return false;
}

bool argAny(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length)
        return true;
    raise(L, new ArgError(n, "value expected"));
    return false;
}

bool argNumber(LuaState L, LuaValue[] a, int n, out double result) {
    if (n <= a.length && toNumberArg(a[n - 1], result))
        return true;
    return typeFail(L, a, n, "number");
}

bool argOptNumber(LuaState L, LuaValue[] a, int n, double def, out double result) {
    if (isNoneOrNil(a, n)) {
        result = def;
        return true;
    }
    return argNumber(L, a, n, result);
}

bool argString(LuaState L, LuaValue[] a, int n, out string result) {
    if (n <= a.length) {
        if (isString(a[n - 1])) {
            result = a[n - 1].asString;
            return true;
        }
        if (isNumber(a[n - 1])) {
            result = toLuaString(a[n - 1]);
            return true;
        }
    }
    return typeFail(L, a, n, "string");
}

bool argOptString(LuaState L, LuaValue[] a, int n, string def, out string result) {
    if (isNoneOrNil(a, n)) {
        result = def;
        return true;
    }
    return argString(L, a, n, result);
}

bool argTable(LuaState L, LuaValue[] a, int n, out LuaTable result) {
    if (n <= a.length && a[n - 1].isTable) {
        result = a[n - 1].asTable;
        return true;
    }
    return typeFail(L, a, n, "table");
}

/// Index of the option named by argument `n` (or by `def` when it is absent and `def` is not null).
bool argOption(LuaState L, LuaValue[] a, int n, string def, const(string)[] options, out int result) {
    string name;
    if (def !is null ? !argOptString(L, a, n, def, name) : !argString(L, a, n, name))
        return false;
    foreach (i, option; options)
        if (option == name) {
            result = cast(int) i;
            return true;
        }
    raise(L, new ArgError(n, "invalid option '" ~ name ~ "'"));
    return false;
}

bool argInteger(LuaState L, LuaValue[] a, int n, out long result) {
    if (n <= a.length && toIntegerArg(a[n - 1], result))
        return true;
    double ignored;
    if (n <= a.length && toNumberArg(a[n - 1], ignored)) {
        raise(L, new ArgError(n, "number has no integer representation"));
        return false;
    }
    return typeFail(L, a, n, "number");
}

bool argOptInteger(LuaState L, LuaValue[] a, int n, long def, out long result) {
    if (isNoneOrNil(a, n)) {
        result = def;
        return true;
    }
    return argInteger(L, a, n, result);
}

/// Raises a Lua error with position information of the calling Lua function.
LuaException luaError(string message) {
    return new LuaException(message);
}

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

void argError(int arg, string extra) {
    throw new ArgError(arg, extra);
}

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

void typeError(LuaState state, LuaValue[] a, int n, string expected) {
    string actual = n > a.length ? "no value" : objectTypeName(state, a[n - 1]);
    throw new ArgError(n, expected ~ " expected, got " ~ actual);
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

void checkAny(LuaValue[] a, int n) {
    if (n > a.length)
        throw new ArgError(n, "value expected");
}

LuaTable checkTable(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length)
        if (auto t = a[n - 1].match!((LuaTable t) => t, _ => cast(LuaTable) null))
            return t;
    typeError(L, a, n, "table");
    assert(0);
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

long checkInteger(LuaState L, LuaValue[] a, int n) {
    long result;
    if (n <= a.length && toIntegerArg(a[n - 1], result))
        return result;
    double ignored;
    if (n <= a.length && toNumberArg(a[n - 1], ignored))
        throw new ArgError(n, "number has no integer representation");
    typeError(L, a, n, "number");
    assert(0);
}

long optInteger(LuaState L, LuaValue[] a, int n, long def) {
    return isNoneOrNil(a, n) ? def : checkInteger(L, a, n);
}

double checkNumber(LuaState L, LuaValue[] a, int n) {
    double result;
    if (n <= a.length && toNumberArg(a[n - 1], result))
        return result;
    typeError(L, a, n, "number");
    assert(0);
}

double optNumber(LuaState L, LuaValue[] a, int n, double def) {
    return isNoneOrNil(a, n) ? def : checkNumber(L, a, n);
}

/// Returns the argument as a number value (integer or float), converting strings.
LuaValue checkNumberValue(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length) {
        if (isNumber(a[n - 1]))
            return a[n - 1];
        if (isString(a[n - 1])) {
            LuaValue number;
            if (parseLuaNumber(a[n - 1].match!((string s) => s, _ => ""), number))
                return number;
        }
    }
    typeError(L, a, n, "number");
    assert(0);
}

string checkString(LuaState L, LuaValue[] a, int n) {
    if (n <= a.length) {
        if (isString(a[n - 1]))
            return a[n - 1].match!((string s) => s, _ => "");
        if (isNumber(a[n - 1]))
            return toLuaString(a[n - 1]);
    }
    typeError(L, a, n, "string");
    assert(0);
}

string optString(LuaState L, LuaValue[] a, int n, string def) {
    return isNoneOrNil(a, n) ? def : checkString(L, a, n);
}

int checkOption(LuaState L, LuaValue[] a, int n, string def, const(string)[] options) {
    string name = def !is null ? optString(L, a, n, def) : checkString(L, a, n);
    foreach (i, option; options)
        if (option == name)
            return cast(int) i;
    throw new ArgError(n, "invalid option '" ~ name ~ "'");
}

/// Raises a Lua error with position information of the calling Lua function.
LuaException luaError(string message) {
    return new LuaException(message);
}

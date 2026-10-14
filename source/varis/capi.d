/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// A small subset of the Lua C API, enough to load simple C modules with `package.loadlib` and
/// `require`. A `lua_State*` handed to C code is a per-call stack of `LuaValue`s; the functions
/// are exported from the executable (see the link flags in the Makefile) so that shared
/// libraries built against `lua.h` resolve them when loaded.
module varis.capi;

import varis.types;
import varis.table;
import varis.state;
import varis.exception : LuaException;
import core.stdc.stdarg;
import core.stdc.string : strlen;
import core.stdc.stdio : snprintf;

alias lua_State = void;
alias lua_CFunction = extern (C) int function(lua_State*);
alias lua_Integer = long;
alias lua_Number = double;

/// The state behind a `lua_State*`: one C function activation.
final class CCall {
    LuaState state;
    LuaValue[] stack;
    string[] pinned; // strings whose bytes were handed to C
    LuaException failure; // the first failed `luaL_check*` of this activation
}

private __gshared CCall[] active; // keeps activations reachable while C code holds raw pointers

private CCall call(lua_State* L) {
    return cast(CCall) cast(void*) L;
}

private size_t absolute(CCall c, int idx) {
    if (idx > 0)
        return cast(size_t) idx - 1;
    return c.stack.length + idx;
}

private LuaValue at(CCall c, int idx) {
    auto i = absolute(c, idx);
    return i < c.stack.length ? c.stack[i] : luaNil();
}

private const(char)* pin(CCall c, string s) {
    auto copy = s ~ '\0';
    c.pinned ~= copy;
    return copy.ptr;
}

/// Wraps a C function so that Lua code can call it.
LuaNativeFunction wrapCFunction(lua_CFunction f, string name = "") {
    return new LuaNativeFunction((void* sp, LuaValue[] args) {
        auto c = new CCall();
        c.state = cast(LuaState) sp;
        c.stack = args.dup;
        active ~= c;
        scope (exit)
            active.length = active.length - 1;
        int n = f(cast(lua_State*) cast(void*) c);
        if (c.failure !is null)
            return raise(c.state, c.failure); // a `luaL_check*` failed while the C function ran
        if (n < 0 || cast(size_t) n > c.stack.length)
            return raise(c.state, "C function returned an invalid number of results");
        return c.stack[$ - n .. $].dup;
    }, name);
}

extern (C):

export int lua_gettop(lua_State* L) {
    return cast(int) call(L).stack.length;
}

export void lua_settop(lua_State* L, int idx) {
    auto c = call(L);
    size_t top = idx >= 0 ? cast(size_t) idx : c.stack.length + idx + 1;
    auto old = c.stack.length;
    c.stack.length = top;
    foreach (i; old .. top)
        c.stack[i] = luaNil();
}

export int lua_absindex(lua_State* L, int idx) {
    return idx > 0 ? idx : cast(int) call(L).stack.length + idx + 1;
}

export void lua_pushvalue(lua_State* L, int idx) {
    auto c = call(L);
    c.stack ~= at(c, idx);
}

export void lua_rotate(lua_State* L, int idx, int n) {
    auto c = call(L);
    auto lo = absolute(c, idx);
    auto seg = c.stack[lo .. $];
    if (seg.length == 0)
        return;
    long k = ((n % cast(long) seg.length) + seg.length) % seg.length;
    auto copy = seg.dup;
    foreach (i, v; copy)
        seg[(i + cast(size_t) k) % seg.length] = v;
}

export void lua_copy(lua_State* L, int from, int to) {
    auto c = call(L);
    auto t = absolute(c, to);
    if (t < c.stack.length)
        c.stack[t] = at(c, from);
}

export int lua_checkstack(lua_State* L, int n) {
    return 1;
}

export int lua_type(lua_State* L, int idx) {
    auto c = call(L);
    auto i = absolute(c, idx);
    if (i >= c.stack.length)
        return -1; // LUA_TNONE
    auto v = c.stack[i];
    final switch (v.typeOf()) {
    case LuaType.Nil:
        return 0;
    case LuaType.Boolean:
        return 1;
    case LuaType.LightUserData:
        return 2;
    case LuaType.Number:
        return 3;
    case LuaType.String:
        return 4;
    case LuaType.Table:
        return 5;
    case LuaType.Function:
        return 6;
    case LuaType.UserData:
        return 7;
    case LuaType.Thread:
        return 8;
    case LuaType.Symbol:
        return 7;
    }
}

export int lua_toboolean(lua_State* L, int idx) {
    return isTruthy(at(call(L), idx)) ? 1 : 0;
}

export lua_Integer lua_tointegerx(lua_State* L, int idx, int* isnum) {
    auto v = at(call(L), idx);
    long result;
    bool ok;
    if (isInteger(v)) {
        result = v.match!((long i) => i, _ => 0L);
        ok = true;
    } else if (isFloat(v))
        ok = floatToInteger(v.match!((double d) => d, _ => 0.0), result);
    else if (isString(v)) {
        LuaValue n;
        parseLuaNumber(v.match!((string t) => t, _ => ""), n);
        if (isInteger(n)) {
            result = n.match!((long i) => i, _ => 0L);
            ok = true;
        } else if (isFloat(n))
            ok = floatToInteger(n.match!((double d) => d, _ => 0.0), result);
    }
    if (isnum !is null)
        *isnum = ok ? 1 : 0;
    return ok ? result : 0;
}

export lua_Number lua_tonumberx(lua_State* L, int idx, int* isnum) {
    auto v = at(call(L), idx);
    if (isString(v)) {
        LuaValue n;
        if (parseLuaNumber(v.match!((string t) => t, _ => ""), n))
            v = n;
    }
    bool ok = isInteger(v) || isFloat(v);
    if (isnum !is null)
        *isnum = ok ? 1 : 0;
    if (isInteger(v))
        return cast(double) v.match!((long i) => i, _ => 0L);
    if (isFloat(v))
        return v.match!((double d) => d, _ => 0.0);
    return 0;
}

export const(char)* lua_tolstring(lua_State* L, int idx, size_t* len) {
    auto c = call(L);
    auto i = absolute(c, idx);
    if (i >= c.stack.length) {
        if (len !is null)
            *len = 0;
        return null;
    }
    auto v = c.stack[i];
    if (!isString(v) && !isNumber(v)) {
        if (len !is null)
            *len = 0;
        return null;
    }
    auto s = toLuaString(v);
    c.stack[i] = LuaValue(s); // numbers are converted in place, as in C Lua
    if (len !is null)
        *len = s.length;
    return pin(c, s);
}

export void lua_pushnil(lua_State* L) {
    call(L).stack ~= luaNil();
}

export void lua_pushnumber(lua_State* L, lua_Number n) {
    call(L).stack ~= LuaValue(n);
}

export void lua_pushinteger(lua_State* L, lua_Integer n) {
    call(L).stack ~= LuaValue(n);
}

export void lua_pushboolean(lua_State* L, int b) {
    call(L).stack ~= LuaValue(b != 0);
}

export const(char)* lua_pushlstring(lua_State* L, const(char)* s, size_t len) {
    auto c = call(L);
    auto str = (s is null ? "" : s[0 .. len].idup);
    c.stack ~= LuaValue(str);
    return pin(c, str);
}

export const(char)* lua_pushstring(lua_State* L, const(char)* s) {
    auto c = call(L);
    if (s is null) {
        c.stack ~= luaNil();
        return null;
    }
    auto str = s[0 .. strlen(s)].idup;
    c.stack ~= LuaValue(str);
    return pin(c, str);
}

export const(char)* lua_pushfstring(lua_State* L, const(char)* fmt, ...) {
    auto c = call(L);
    va_list ap;
    va_start(ap, fmt);
    string result;
    for (auto p = fmt; *p; ++p) {
        if (*p != '%') {
            result ~= *p;
            continue;
        }
        ++p;
        switch (*p) {
        case 's': {
                auto s = va_arg!(const(char)*)(ap);
                result ~= s is null ? "(null)" : s[0 .. strlen(s)].idup;
                break;
            }
        case 'c':
            result ~= cast(char) va_arg!int(ap);
            break;
        case 'd': {
                char[32] buf;
                auto n = snprintf(buf.ptr, buf.length, "%d", va_arg!int(ap));
                result ~= buf[0 .. n].idup;
                break;
            }
        case 'I': {
                char[32] buf;
                auto n = snprintf(buf.ptr, buf.length, "%lld", va_arg!long(ap));
                result ~= buf[0 .. n].idup;
                break;
            }
        case 'f': {
                char[64] buf;
                auto n = snprintf(buf.ptr, buf.length, "%.14g", va_arg!double(ap));
                result ~= buf[0 .. n].idup;
                break;
            }
        case 'p': {
                char[32] buf;
                auto n = snprintf(buf.ptr, buf.length, "%p", va_arg!(void*)(ap));
                result ~= buf[0 .. n].idup;
                break;
            }
        case '%':
            result ~= '%';
            break;
        default:
            result ~= '%';
            result ~= *p;
            break;
        }
    }
    va_end(ap);
    c.stack ~= LuaValue(result);
    return pin(c, result);
}

export void lua_pushcclosure(lua_State* L, lua_CFunction f, int nup) {
    auto c = call(L);
    c.stack.length = c.stack.length - cast(size_t) nup; // upvalues are not supported
    c.stack ~= LuaValue(wrapCFunction(f));
}

export void lua_createtable(lua_State* L, int narr, int nrec) {
    call(L).stack ~= LuaValue(new LuaTable());
}

export int lua_getglobal(lua_State* L, const(char)* name) {
    auto c = call(L);
    c.stack ~= c.state.globals.rawget(LuaValue(name[0 .. strlen(name)].idup));
    return lua_type(L, -1);
}

export void lua_setglobal(lua_State* L, const(char)* name) {
    auto c = call(L);
    auto v = c.stack[$ - 1];
    c.stack.length = c.stack.length - 1;
    c.state.globals.rawset(LuaValue(name[0 .. strlen(name)].idup), v);
}

private LuaTable tableAt(CCall c, int idx) {
    return at(c, idx).match!((LuaTable t) => t, _ => null);
}

export int lua_getfield(lua_State* L, int idx, const(char)* k) {
    auto c = call(L);
    auto t = tableAt(c, idx);
    c.stack ~= t is null ? luaNil() : t.rawget(LuaValue(k[0 .. strlen(k)].idup));
    return lua_type(L, -1);
}

export void lua_setfield(lua_State* L, int idx, const(char)* k) {
    auto c = call(L);
    auto t = tableAt(c, idx);
    auto v = c.stack[$ - 1];
    c.stack.length = c.stack.length - 1;
    if (t !is null)
        t.rawset(LuaValue(k[0 .. strlen(k)].idup), v);
}

export int lua_rawgeti(lua_State* L, int idx, lua_Integer n) {
    auto c = call(L);
    auto t = tableAt(c, idx);
    c.stack ~= t is null ? luaNil() : t.rawget(LuaValue(n));
    return lua_type(L, -1);
}

export void lua_rawseti(lua_State* L, int idx, lua_Integer n) {
    auto c = call(L);
    auto t = tableAt(c, idx);
    auto v = c.stack[$ - 1];
    c.stack.length = c.stack.length - 1;
    if (t !is null)
        t.rawset(LuaValue(n), v);
}

/// Records the first error of the running C function; it is reported when the function
/// returns. (C Lua leaves the function by longjmp; here it runs on with a zero result, which
/// a C API library has to tolerate until a C-API host protocol is designed.)
private void checkFailed(lua_State* L, string message) {
    auto c = call(L);
    if (c.failure is null)
        c.failure = new LuaException(message);
}

export void luaL_checkversion_(lua_State* L, lua_Number ver, size_t sz) {
    if (ver != 504.0 || sz != 8 * 16 + 8)
        checkFailed(L, "version mismatch: core and library have incompatible numeric types");
}

/// `luaL_Reg`: a name and a function, terminated by a null name.
struct luaL_Reg {
    const(char)* name;
    lua_CFunction func;
}

export void luaL_setfuncs(lua_State* L, const(luaL_Reg)* l, int nup) {
    auto c = call(L);
    auto t = tableAt(c, -1 - nup);
    for (; l.name !is null; ++l) {
        auto name = l.name[0 .. strlen(l.name)].idup;
        if (t !is null)
            t.rawset(LuaValue(name), l.func is null ? LuaValue(false) : LuaValue(wrapCFunction(l.func, name)));
    }
    c.stack.length = c.stack.length - cast(size_t) nup;
}

export lua_Integer luaL_checkinteger(lua_State* L, int arg) {
    int ok;
    auto n = lua_tointegerx(L, arg, &ok);
    if (!ok) {
        checkFailed(L, "bad argument #" ~ arg.stringOf ~ " (number expected)");
        return 0;
    }
    return n;
}

export lua_Number luaL_checknumber(lua_State* L, int arg) {
    int ok;
    auto n = lua_tonumberx(L, arg, &ok);
    if (!ok) {
        checkFailed(L, "bad argument #" ~ arg.stringOf ~ " (number expected)");
        return 0;
    }
    return n;
}

private string stringOf(int n) {
    import std.conv : to;

    return n.to!string;
}

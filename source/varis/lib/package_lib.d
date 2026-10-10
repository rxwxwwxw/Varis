/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Package library: a port of loadlib.c. C libraries are loaded with dlopen and use the small
/// C API subset of varis.capi.
module varis.lib.package_lib;

import varis.types;
import varis.table;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.lib.auxlib;
import varis.lib.base : readWholeFile, skipFilePrefix, loadChunk;
import std.array : replace, split, appender;
import std.process : environment;
import varis.capi : wrapCFunction, lua_CFunction;

private __gshared void*[string] libraries;

/// Loads `path` (once) and returns its handle, or null with `error` set.
private void* openLibrary(string path, bool global, out string error) {
    import core.sys.posix.dlfcn;
    import std.string : toStringz, fromStringz;

    if (auto known = path in libraries) {
        if (global) { /* already loaded; promote visibility by reopening */ dlopen(path.toStringz, RTLD_NOW | RTLD_GLOBAL);
        }
        return *known;
    }
    auto handle = dlopen(path.toStringz, RTLD_NOW | (global ? RTLD_GLOBAL : RTLD_LOCAL));
    if (handle is null) {
        error = dlerror().fromStringz.idup;
        return null;
    }
    libraries[path] = handle;
    return handle;
}

/// Mirrors lookforfunc: returns the function, or null with `error`/`when` ("open" or "init").
private LuaValue lookForFunction(string path, string symbol, out string error, out string when) {
    import core.sys.posix.dlfcn;
    import std.string : toStringz, fromStringz;

    bool star = symbol == "*";
    auto handle = openLibrary(path, star, error);
    if (handle is null) {
        when = "open";
        return luaNil();
    }
    if (star)
        return LuaValue(true);
    auto sym = dlsym(handle, symbol.toStringz);
    if (sym is null) {
        auto e = dlerror();
        error = e is null ? "undefined symbol: " ~ symbol : e.fromStringz.idup;
        when = "init";
        return luaNil();
    }
    return LuaValue(wrapCFunction(cast(lua_CFunction) sym, symbol));
}

private bool readable(string filename) {
    import core.stdc.stdio : fopen, fclose;
    import std.string : toStringz;

    auto f = fopen(filename.toStringz, "r");
    if (f is null)
        return false;
    fclose(f);
    return true;
}

private string pathNotFound(string path) {
    // "no file 'a'\n\tno file 'b'"
    auto b = appender!string();
    b.put("no file '");
    b.put(path.replace(";", "'\n\tno file '"));
    b.put("'");
    return b.data;
}

/// Returns the filename found in `path`, or null with `error` describing the failures.
private string searchPath(string name, string path, string sep, string dirsep, out string error) {
    if (sep.length)
        name = name.replace(sep, dirsep);
    auto expanded = path.replace("?", name);
    string errors;
    foreach (candidate; expanded.split(';')) {
        if (candidate.length == 0 && false)
            continue;
        if (readable(candidate))
            return candidate;
        if (errors.length)
            errors ~= "\n\t";
        errors ~= "no file '" ~ candidate ~ "'";
    }
    error = errors;
    return null;
}

private string setPath(LuaState state, string envName, string dflt) {
    if (!isNil(state.registry.rawget(LuaValue("LUA_NOENV"))))
        return dflt;
    string value = environment.get(envName ~ "_5_4", environment.get(envName, null));
    if (value is null)
        return dflt;
    import std.string : indexOf;

    auto mark = value.indexOf(";;");
    if (mark < 0)
        return value;
    string result;
    if (mark > 0)
        result ~= value[0 .. mark] ~ ";";
    result ~= dflt;
    if (cast(size_t) mark + 2 < value.length)
        result ~= ";" ~ value[mark + 2 .. $];
    return result;
}

void openPackageLib(LuaState state) {
    auto pkg = new LuaTable();
    auto loaded = new LuaTable();
    auto preload = new LuaTable();
    auto searchers = new LuaTable();

    pkg.rawset(LuaValue("loaded"), LuaValue(loaded));
    pkg.rawset(LuaValue("preload"), LuaValue(preload));
    pkg.rawset(LuaValue("searchers"), LuaValue(searchers));
    pkg.rawset(LuaValue("config"), LuaValue("/\n;\n?\n!\n-\n"));
    pkg.rawset(LuaValue("path"), LuaValue(setPath(state, "LUA_PATH",
            "/usr/local/share/lua/5.4/?.lua;/usr/local/share/lua/5.4/?/init.lua;" ~
            "/usr/local/lib/lua/5.4/?.lua;/usr/local/lib/lua/5.4/?/init.lua;./?.lua;./?/init.lua")));
    pkg.rawset(LuaValue("cpath"), LuaValue(setPath(state, "LUA_CPATH",
            "/usr/local/lib/lua/5.4/?.so;/usr/local/lib/lua/5.4/loadall.so;./?.so")));

    pkg.register("searchpath", (LuaState L, LuaValue[] a) {
        string name = checkString(L, a, 1);
        string path = checkString(L, a, 2);
        string sep = optString(L, a, 3, ".");
        string rep = optString(L, a, 4, "/");
        string error;
        auto found = searchPath(name, path, sep, rep, error);
        if (found is null)
            return [luaNil(), LuaValue(error)];
        return [LuaValue(found)];
    });

    pkg.register("loadlib", (LuaState L, LuaValue[] a) {
        string error, when;
        auto f = lookForFunction(checkString(L, a, 1), checkString(L, a, 2), error, when);
        if (!isNil(f))
            return [f];
        return [luaNil(), LuaValue(error), LuaValue(when)];
    });

    LuaValue pathField(LuaState L, string field) {
        auto v = pkg.rawget(LuaValue(field));
        if (!isString(v))
            throw new LuaException("'package." ~ field ~ "' must be a string");
        return v;
    }

    // searcher 1: package.preload
    searchers.rawset(LuaValue(1L), LuaValue(new LuaNativeFunction((void* sp, LuaValue[] a) {
                auto L = cast(LuaState) sp;
                string name = checkString(L, a, 1);
                auto loader = preload.rawget(LuaValue(name));
                if (isNil(loader))
                    return [LuaValue("no field package.preload['" ~ name ~ "']")];
                return [loader, LuaValue(":preload:")];
            }, "searcher_preload")));

    // searcher 2: Lua files on package.path
    searchers.rawset(LuaValue(2L), LuaValue(new LuaNativeFunction((void* sp, LuaValue[] a) {
                auto L = cast(LuaState) sp;
                string name = checkString(L, a, 1);
                string path = pathField(L, "path").match!((string s) => s, _ => "");
                string error;
                auto filename = searchPath(name, path, ".", "/", error);
                if (filename is null)
                    return [LuaValue(error)];
                string content, readError;
                LuaFunction fn;
                try {
                    if (!readWholeFile(filename, content, readError))
                        throw new LuaException(readError);
                    fn = loadChunk(L, skipFilePrefix(content), "@" ~ filename, "bt");
                } catch (LuaException failure) {
                    throw new LuaException(
                    "error loading module '" ~ name ~ "' from file '" ~ filename ~ "':\n\t" ~ toLuaString(
                    failure.errorObject));
                }
                return [LuaValue(fn), LuaValue(filename)];
            }, "searcher_Lua")));

    // Loads the `luaopen_` function of `name` from `filename`, trying a "version-" prefix first.
    LuaValue[] loadOpen(LuaState L, string name, string filename) {
        import std.string : indexOf;

        string error, when;
        string modname = name;
        auto mark = modname.indexOf('-');
        string[] candidates;
        if (mark >= 0) {
            candidates ~= "luaopen_" ~ modname[0 .. mark].replace(".", "_");
            modname = modname[mark + 1 .. $];
        }
        candidates ~= "luaopen_" ~ modname.replace(".", "_");
        foreach (symbol; candidates) {
            auto f = lookForFunction(filename, symbol, error, when);
            if (!isNil(f))
                return [f, LuaValue(filename)];
            if (when == "open")
                break;
        }
        throw new LuaException("error loading module '" ~ name ~ "' from file '" ~ filename ~ "':\n\t" ~ error);
    }

    // searcher 3: a C library named after the module
    searchers.rawset(LuaValue(3L), LuaValue(new LuaNativeFunction((void* sp, LuaValue[] a) {
                auto L = cast(LuaState) sp;
                string name = checkString(L, a, 1);
                string path = pathField(L, "cpath").match!((string s) => s, _ => "");
                string error;
                auto filename = searchPath(name, path, ".", "/", error);
                if (filename is null)
                    return [LuaValue(error)];
                return loadOpen(L, name, filename);
            }, "searcher_C")));

    // searcher 4: the library of the root name, holding submodules
    searchers.rawset(LuaValue(4L), LuaValue(new LuaNativeFunction((void* sp, LuaValue[] a) {
                auto L = cast(LuaState) sp;
                string name = checkString(L, a, 1);
                import std.string : indexOf;

                auto dot = name.indexOf('.');
                if (dot < 0)
                    return cast(LuaValue[])[];
                string root = name[0 .. dot];
                string path = pathField(L, "cpath").match!((string s) => s, _ => "");
                string error;
                auto filename = searchPath(root, path, ".", "/", error);
                if (filename is null)
                    return [LuaValue(error)];
                string openError, when;
                string symbol = "luaopen_" ~ name.replace(".", "_");
                auto f = lookForFunction(filename, symbol, openError, when);
                if (isNil(f)) {
                    if (when == "init")
                        return [LuaValue("no module '" ~ name ~ "' in file '" ~ filename ~ "'")];
                    throw new LuaException(
                    "error loading module '" ~ name ~ "' from file '" ~ filename ~ "':\n\t" ~ openError);
                }
                return [f, LuaValue(filename)];
            }, "searcher_Croot")));

    state.globals.register("require", (LuaState L, LuaValue[] a) {
        string name = checkString(L, a, 1);
        auto already = loaded.rawget(LuaValue(name));
        if (isTruthy(already))
            return [already];
        // findloader
        auto searchersValue = pkg.rawget(LuaValue("searchers"));
        if (!isTable(searchersValue))
            throw new LuaException("'package.searchers' must be a table");
        auto list = searchersValue.match!((LuaTable t) => t, _ => null);
        string message;
        LuaValue loader, extra;
        for (long i = 1;; ++i) {
            auto searcher = list.rawget(LuaValue(i));
            if (isNil(searcher))
                throw new LuaException("module '" ~ name ~ "' not found:" ~ message);
            auto results = VM.callValue(L, searcher, [LuaValue(name)]);
            if (results.length && isFunction(results[0])) {
                loader = results[0];
                extra = results.length > 1 ? results[1] : luaNil();
                break;
            }
            if (results.length && (isString(results[0]) || isNumber(results[0])))
                message ~= "\n\t" ~ toLuaString(results[0]);
        }
        auto results = VM.callValue(L, loader, [LuaValue(name), extra]);
        if (results.length && !isNil(results[0]))
            loaded.rawset(LuaValue(name), results[0]);
        else if (isNil(loaded.rawget(LuaValue(name))))
            loaded.rawset(LuaValue(name), LuaValue(true));
        return [loaded.rawget(LuaValue(name)), extra];
    });

    state.setGlobal("package", LuaValue(pkg));
}

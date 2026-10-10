/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib;

public import varis.lib.base;
public import varis.lib.math;
public import varis.lib.string;
public import varis.lib.table;
public import varis.lib.coroutine;
public import varis.lib.os;
public import varis.lib.io;
public import varis.lib.utf8;
public import varis.lib.package_lib;
public import varis.lib.debug_lib;
public import varis.lib.logic;
public import varis.lib.narrative;
public import varis.lib.quality;
import varis.lib.fastcall : installFastCalls;

import varis.types;
import varis.table;
import varis.state : LuaState;

/// Open and register all standard libraries into the given LuaState
void openLibs(LuaState state) {
    openBaseLib(state);
    openMathLib(state);
    openStringLib(state);
    openTableLib(state);
    openCoroutineLib(state);
    openOsLib(state);
    openIoLib(state);
    openUtf8Lib(state);
    openPackageLib(state);
    openDebugLib(state);
    openLogicLib(state);
    openNarrativeLib(state);
    openQualityLib(state);

    // Lua 5.4 convention: register all standard modules in package.loaded
    auto pkgVal = state.getGlobal("package");
    if (isTable(pkgVal)) {
        auto pkgTbl = pkgVal.match!((LuaTable t) => t, _ => null);
        auto loadedVal = pkgTbl.rawget(LuaValue("loaded"));
        if (isTable(loadedVal)) {
            auto loadedTbl = loadedVal.match!((LuaTable t) => t, _ => null);
            loadedTbl.rawset(LuaValue("_G"), LuaValue(state.globals));
            loadedTbl.rawset(LuaValue("package"), pkgVal);
            foreach (name; [
                "math", "string", "table", "coroutine", "os", "io", "utf8", "debug", "logic",
                "narrative", "quality"
            ]) {
                auto g = state.getGlobal(name);
                if (!isNil(g)) {
                    loadedTbl.rawset(LuaValue(name), g);
                }
            }
        }
    }
    // Capture identities before authored code can replace or alias built-ins.
    void remember(string path, LuaValue value) {
        auto function_ = value.match!((LuaFunction f) => f, _ => null);
        if (cast(LuaNativeFunction) function_ !is null) {
            state.standardNativePaths[function_] = path;
            state.standardNativeFunctions[path] = function_;
        }
    }

    foreach (entry; state.globals.hashEntries)
        with (entry)
            if (isString(key))
                remember(key.match!((string s) => s, _ => ""), value);
    foreach (name; [
        "math", "string", "table", "coroutine", "os", "io", "utf8", "debug", "logic", "narrative",
        "quality", "package"
    ]) {
        auto library = state.getGlobal(name).match!((LuaTable t) => t, _ => null);
        if (library is null)
            continue;
        foreach (entry; library.hashEntries)
            with (entry)
                if (isString(key))
                    remember(name ~ "." ~ key.match!((string s) => s, _ => ""), value);
    }
    installFastCalls(state);

}

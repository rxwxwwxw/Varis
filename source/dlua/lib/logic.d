/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.lib.logic;

import dlua.types;
import dlua.table;
import dlua.state;
import dlua.exception : LuaException;
import dlua.logic.model;
import dlua.logic.world;
import dlua.logic.query;
import std.format : format;

/// Register the standard declarative logic library into the Lua state
void openLogicLib(LuaState state) {
    auto logicTable = new LuaTable();

    // logic.global
    logicTable.rawset(LuaValue("global"), wrapWorld(state.globalWorld));

    // logic.world([parent])
    logicTable.rawset(LuaValue("world"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                auto s = cast(LuaState) sPtr;
                if (args.length > 0 && !isNil(args[0])) {
                    auto parent = unwrapWorld(args[0]);
                    return [wrapWorld(parent.cloneSnapshot())];
                }
                return [wrapWorld(s.globalWorld.cloneSnapshot())];
            }, "world")));

    // logic.emptyworld()
    logicTable.rawset(LuaValue("emptyworld"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                auto state = cast(LuaState) sPtr;
                auto world = new World();
                if (state.configureWorld !is null)
                    state.configureWorld(world);
                return [wrapWorld(world)];
            }, "emptyworld")));

    // logic.add(world, name, ...)
    logicTable.rawset(LuaValue("add"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length < 2)
                    throw new LuaException("bad arguments to 'logic.add'");
                auto w = unwrapWorld(args[0]);
                if (!isString(args[1]))
                    throw new LuaException("bad argument #2 to 'logic.add' (string expected)");
                string name = args[1].match!((string s) => s, _ => "");
                LuaValue[] tupleVals = (args.length > 2) ? args[2 .. $] : [];
                w.addFact(name, RelTuple(tupleVals));
                return cast(LuaValue[])[];
            }, "add")));

    // logic.retract(world, name, ...)
    logicTable.rawset(LuaValue("retract"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length < 2)
                    throw new LuaException("bad arguments to 'logic.retract'");
                auto w = unwrapWorld(args[0]);
                if (!isString(args[1]))
                    throw new LuaException("bad argument #2 to 'logic.retract' (string expected)");
                string name = args[1].match!((string s) => s, _ => "");
                LuaValue[] tupleVals = (args.length > 2) ? args[2 .. $] : [];
                w.retractFact(name, RelTuple(tupleVals));
                return cast(LuaValue[])[];
            }, "retract")));

    // Helper for symbol construction
    auto symbolFn = new LuaNativeFunction((void* sPtr, LuaValue[] args) {
        if (args.length == 0)
            throw new LuaException("bad argument #1 to 'symbol' (value expected)");
        auto s = cast(LuaState) sPtr;
        auto arg = args[0];
        if (isSymbol(arg)) {
            return [arg];
        }
        if (isString(arg)) {
            string name = arg.match!((string str) => str, _ => "");
            return [s.getSymbol(name)];
        }
        throw new LuaException(format("bad argument #1 to 'symbol' (string expected, got %s)", typeName(arg)));
    }, "symbol");

    // logic.symbol(name)
    logicTable.rawset(LuaValue("symbol"), LuaValue(symbolFn));

    // Global symbol(name)
    state.registerGlobal("symbol", (void* sPtr, LuaValue[] args) { return symbolFn.call(sPtr, args); });

    // logic.symbolname(val)
    logicTable.rawset(LuaValue("symbolname"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length == 0 || !isSymbol(args[0])) {
                    throw new LuaException(format("bad argument #1 to 'symbolname' (symbol expected, got %s)", args
                    .length > 0 ? typeName(args[0]) : "no value"));
                }
                auto sym = args[0].match!((Symbol s) => s, _ => Symbol.init);
                return [LuaValue(sym.name)];
            }, "symbolname")));

    // logic.hasbinding(record, name)
    logicTable.rawset(LuaValue("hasbinding"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length < 2)
                    throw new LuaException("bad arguments to 'logic.hasbinding'");
                auto rec = unwrapBindingRecord(args[0]);
                string name = args[1].match!((string s) => s, _ => toLuaString(args[1]));
                return [luaValue(rec.hasBinding(name))];
            }, "hasbinding")));

    // logic.binding(record, name)
    logicTable.rawset(LuaValue("binding"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length < 2)
                    throw new LuaException("bad arguments to 'logic.binding'");
                auto rec = unwrapBindingRecord(args[0]);
                string name = args[1].match!((string s) => s, _ => toLuaString(args[1]));
                return [rec.getBinding(name)];
            }, "binding")));

    // Set globals and package.loaded["logic"]
    state.setGlobal("logic", LuaValue(logicTable));

    // Register in package.loaded
    auto pkgVal = state.getGlobal("package");
    if (isTable(pkgVal)) {
        auto pkgTbl = pkgVal.match!((LuaTable t) => t, _ => null);
        auto loadedVal = pkgTbl.rawget(LuaValue("loaded"));
        if (isTable(loadedVal)) {
            auto loadedTbl = loadedVal.match!((LuaTable t) => t, _ => null);
            loadedTbl.rawset(LuaValue("logic"), LuaValue(logicTable));
        }
    }
}

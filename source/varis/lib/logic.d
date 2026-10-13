/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.lib.logic;

import varis.types;
import varis.table;
import varis.state;
import varis.vm : VM;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.world;
import varis.logic.query;
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
                    configureWorld(state)(world);
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

    // logic.one(query): the sole binding record, nil when there is no match, an error when there
    // are several. (Query results are unordered, so there is no "first".)
    logicTable.rawset(LuaValue("one"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                if (args.length != 1 || !isFunction(args[0]) && args[0].typeOf() != LuaType.UserData)
                    throw new LuaException("bad argument #1 to 'logic.one' (query expected)");
                auto s = cast(LuaState) sPtr;
                auto first = VM.callValue(s, args[0], []);
                if (!first.length || isNil(first[0]))
                    return [luaNil()];
                auto second = VM.callValue(s, args[0], []);
                if (second.length && !isNil(second[0]))
                    throw new LuaException("logic.one: the query has more than one match");
                return [first[0]];
            }, "one")));

    // logic.counters(): how much work the world model and the collector have done so far.
    logicTable.rawset(LuaValue("counters"), LuaValue(new LuaNativeFunction((void* sPtr, LuaValue[] args) {
                import core.memory : GC;
                import varis.logic.store : engineCounters;
                import varis.logic.world : currentTransaction, isReadOnlyEvaluation;

                // Like the profile: story logic must not be able to depend on these numbers.
                if (currentTransaction() !is null || isReadOnlyEvaluation())
                    throw new LuaException(
                    "logic.counters is not available inside a transaction or read-only narrative evaluation");
                auto result = new LuaTable;
                void put(string name, ulong value) {
                    result.rawset(LuaValue(name), LuaValue(cast(long) value));
                }

                put("queries", engineCounters.queries);
                put("rule_firings", engineCounters.ruleFirings);
                put("tuples_derived", engineCounters.tuplesDerived);
                put("facts_copied", engineCounters.factsCopied);
                put("table_rows", engineCounters.tableRows);
                put("derived_cache_hits", engineCounters.derivedCacheHits);
                put("collections", GC.profileStats().numCollections);
                put("allocated_bytes", GC.stats().allocatedInCurrentThread);
                return [LuaValue(result)];
            }, "counters")));

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

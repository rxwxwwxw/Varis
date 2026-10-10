/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/
module tests.unit.test_stateful;

import varis;
import varis.logic.model;
import varis.logic.world;
import varis.logic.query;
import tests.unit.unit_runner : UnitMain;
import std.stdio : writeln;

void rejects(void delegate() operation, string diagnostic) {
    import std.string : indexOf;

    bool rejected;
    try {
        operation();
    } catch (LuaException e) {
        assert(e.msg.indexOf(diagnostic) >= 0, e.msg);
        rejected = true;
    }
    assert(rejected, "expected rejection: " ~ diagnostic);
}

@("testKeyIndexes") unittest {
    auto w = new World();
    auto r = w.declareNamedRelation("score", ["value", "entity", "name"], ["name", "entity"]);
    auto tuple = RelTuple([LuaValue(1L), luaNil(), LuaValue("coins")]);
    w.addFact("score", tuple);
    auto initialVersion = w.version_;
    auto relationVersion = r.version_;
    assert(!w.addFact("score", tuple));
    assert(!w.updateFact("score", tuple, "set"));
    assert(w.version_ == initialVersion && r.version_ == relationVersion);
    rejects({ w.addFact("score", RelTuple([LuaValue(2L), luaNil(), LuaValue("coins")])); }, "conflicting fact");
    assert(w.version_ == initialVersion && r.baseFacts.length == 1 && r.keyIndex.length == 1);
    w.updateFact("score", RelTuple([LuaValue("coins"), luaNil()]), "adjust", LuaValue(2L));
    assert(r.baseFacts.length == 1 && r.keyIndex.length == 1);
    auto child = w.cloneSnapshot();
    child.updateFact("score", RelTuple([LuaValue("coins"), luaNil()]), "delete");
    assert(child.getRelation("score").baseFacts.length == 0);
    assert(r.baseFacts.length == 1);
    auto present = RelTuple([LuaValue(3L), luaNil(), LuaValue("coins")]);
    assert(present in r.baseFacts);
    w.retractFact("score", present);
    assert(r.keyIndex.length == 0);
    w.addFact("score", tuple);
    w.declareRelation("implicit", 1);
    rejects({ w.declareNamedRelation("implicit", [], []); }, "conflicting schema");
    rejects({ w.declareNamedRelation("bad", ["a", "b"], ["a", "a"]); }, "duplicate key");
    assert(w.getRelation("bad") is null);
    // Integer adjustment retains Lua's wrapping integer arithmetic.
    w.updateFact("score", RelTuple([LuaValue(long.max), luaNil(), LuaValue("coins")]), "set");
    w.updateFact("score", RelTuple([LuaValue("coins"), luaNil()]), "adjust", LuaValue(1L));
    assert(RelTuple([LuaValue(long.min), luaNil(), LuaValue("coins")]) in r.baseFacts);
    writeln("  [PASS] keyed indexes, versions, schemas and numeric arithmetic");
}

@("testTentativeSnapshots") unittest {
    auto s = new LuaState();
    auto w = s.globalWorld;
    auto r = w.declareNamedRelation("value", ["entity", "n"], ["entity"]);
    w.addFact("value", RelTuple([LuaValue("p"), LuaValue(1L)]));
    auto initialVersion = w.version_;
    auto outer = new Transaction(w);
    w.updateFact("value", RelTuple([LuaValue("p"), LuaValue(2L)]), "set");
    assert(w.version_ == initialVersion);
    assert(RelTuple([LuaValue("p"), LuaValue(1L)]) in r.baseFacts);
    assert(RelTuple([LuaValue("p"), LuaValue(2L)]) in visibleRelation(r).baseFacts);
    auto reference = new RelationRef("value", 2, "", r.id);
    reference.resolvedRelation = r;
    auto goals = [
        Goal.makePositiveAtom(reference, [Term.makeConstant(LuaValue("p")), Term.makeVariable("n")])
    ];
    auto iterator = new QueryIterator(s, goals, ["n"], [r.id: r], []);
    auto nested = new Transaction(w);
    w.updateFact("value", RelTuple([LuaValue("p"), LuaValue(3L)]), "set");
    nested.finish(true);
    assert(unwrapBindingRecord(iterator.next()).getBinding("n") == LuaValue(2L));
    outer.finish(false);
    rejects({ iterator.next(); }, "invalid query iterator");
    assert(currentTransaction() is null && w.transactionOwner is null);
    assert(w.version_ == initialVersion && RelTuple([LuaValue("p"), LuaValue(1L)]) in r.baseFacts);
    auto committing = new Transaction(w);
    w.updateFact("value", RelTuple([LuaValue("p"), LuaValue(4L)]), "set");
    auto retained = new QueryIterator(s, goals, ["n"], [r.id: r], []);
    committing.finish(true);
    assert(w.version_ == initialVersion + 1);
    assert(unwrapBindingRecord(retained.next()).getBinding("n") == LuaValue(4L));
    writeln("  [PASS] tentative snapshots, commit versions and rollback invalidation");
}

@("testCleanup") unittest {
    auto s = new LuaState();
    openLibs(s);
    s.doString(q"{
        relation account(id, n) key(id)
        fact account(1, 1)
        local retained
        local function update()
            transaction do
                set account(1, 2)
                retained = query account(1, ?n)
                return 7
            end
        end
        assert(update() == 7 and retained().n == 2)
        assert(not pcall(function() transaction do error("failure") end end))
        transaction do set account(1, 3) end
        assert((query account(1, ?n))().n == 3)
        local function closer(n, fail)
            return setmetatable({}, {__close = function()
                set account(1, n)
                if fail then error('close failure') end
            end})
        end
        transaction do local c <close> = closer(4) end
        assert((query account(1, ?n))().n == 4)
        transaction do local c <close> = closer(5); rollback end
        assert((query account(1, ?n))().n == 4)
        assert(not pcall(function()
            transaction do local c <close> = closer(6, true) end
        end))
        assert((query account(1, ?n))().n == 4)
        transaction do
            local c <close> = closer(7)
            goto committed
        end
        ::committed::
        assert((query account(1, ?n))().n == 7)
        local function tentative()
            assert((query account(1, ?n))().n == 8)
            error('returned callee failed')
        end
        local function returnedCall()
            transaction do set account(1, 8); return tentative() end
        end
        assert(not pcall(returnedCall))
        assert((query account(1, ?n))().n == 7)
    }");
    assert(currentTransaction() is null && s.globalWorld.transactionOwner is null);
    rejects({ s.doString("rollback"); }, "rollback outside a transaction");
    writeln("  [PASS] VM return/error cleanup and rollback context");
}

mixin UnitMain;

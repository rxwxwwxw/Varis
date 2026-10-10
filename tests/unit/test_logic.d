/*
** dlua - Unit tests for Declarative Engine & Logic Extensions (Milestones 0-8)
*/

module tests.unit.test_logic;

import dlua;
import dlua.logic.model;
import dlua.logic.world;
import dlua.logic.validate;
import dlua.logic.evaluate;
import dlua.logic.query;
import dlua.lib.logic;

import std.stdio : writeln;
import std.math : isNaN;

void testSymbolsAndTuples() {
    auto state = new LuaState();
    openLogicLib(state);

    // Symbols interning
    auto v1 = state.getSymbol("alpha");
    auto v2 = state.getSymbol("alpha");
    auto v3 = state.getSymbol("beta");
    auto s1 = v1.match!((Symbol s) => s, _ => Symbol.init);
    auto s2 = v2.match!((Symbol s) => s, _ => Symbol.init);
    auto s3 = v3.match!((Symbol s) => s, _ => Symbol.init);
    assert(s1 == s2);
    assert(s1 != s3);
    assert(s1.name == "alpha");

    // RelTuples
    auto t1 = RelTuple([LuaValue(1L), LuaValue("x"), LuaValue(s1)]);
    auto t2 = RelTuple([LuaValue(1.0), LuaValue("x"), LuaValue(s2)]);
    assert(t1 == t2);
    assert(t1.toHash() == t2.toHash());

    // RelTuple with nil and boolean
    auto t3 = RelTuple([luaNil(), luaValue(false), luaValue(0L)]);
    auto t4 = RelTuple([luaNil(), luaValue(false), luaValue(0.0)]);
    assert(t3 == t4);
    assert(t3.toHash() == t4.toHash());

    // Different values
    auto t5 = RelTuple([luaNil(), luaValue(true), luaValue(0L)]);
    assert(t3 != t5);

    writeln("  [PASS] testSymbolsAndTuples");
}

void testWorldAndRelations() {
    auto state = new LuaState();
    openLogicLib(state);

    auto wParent = new World();
    wParent.declareRelation("edge", 2);
    assert(wParent.getRelation("edge") !is null);
    assert(wParent.getRelation("edge").arity == 2);

    ulong v0 = wParent.version_;
    wParent.addFact("edge", RelTuple([LuaValue("a"), LuaValue("b")]));
    assert(wParent.version_ > v0);

    // Snapshot inheritance
    auto wChild = wParent.cloneSnapshot();
    assert(wChild.getRelation("edge") !is null);
    assert(wChild.getRelation("edge").baseFacts.length == 1);

    // Child mutations do not affect parent
    wChild.addFact("edge", RelTuple([LuaValue("b"), LuaValue("c")]));
    assert(wChild.getRelation("edge").baseFacts.length == 2);
    assert(wParent.getRelation("edge").baseFacts.length == 1);

    // Retraction
    wParent.retractFact("edge", RelTuple([LuaValue("a"), LuaValue("b")]));
    assert(wParent.getRelation("edge").baseFacts.length == 0);
    // Child snapshot still retains fact
    assert(wChild.getRelation("edge").baseFacts.length == 2);

    writeln("  [PASS] testWorldAndRelations");
}

void testValidation() {
    auto w = new World();
    w.declareRelation("p", 1);
    w.declareRelation("q", 1);

    // Arity mismatch
    bool threwArity = false;
    try {
        w.addFact("p", RelTuple([LuaValue(1L), LuaValue(2L)]));
    } catch (LuaException e) {
        threwArity = true;
    }
    assert(threwArity);

    // Unsafe variable in head
    auto pRel = w.getRelation("p");
    auto qRel = w.getRelation("q");
    auto refP = new RelationRef(pRel.name, pRel.arity, "", pRel.id, false);
    auto refQ = new RelationRef(qRel.name, qRel.arity, "", qRel.id, false);
    auto unsafeRule = new Rule(
        refP,
        [Term.makeVariable("x", 0), Term.makeVariable("y", 1)],
        [Goal.makePositiveAtom(refQ, [Term.makeVariable("x", 0)])]
    );

    bool threwUnsafe = false;
    try {
        validateRuleSafety(unsafeRule);
    } catch (LuaException e) {
        threwUnsafe = true;
    }
    assert(threwUnsafe);

    writeln("  [PASS] testValidation");
}

void testEvaluatorAndQuery() {
    auto state = new LuaState();
    openLogicLib(state);

    auto w = new World();
    w.declareRelation("edge", 2);
    w.declareRelation("path", 2);

    auto rEdge = w.getRelation("edge");
    auto rPath = w.getRelation("path");

    // Facts: edge(a, b), edge(b, c)
    auto symA = state.getSymbol("a");
    auto symB = state.getSymbol("b");
    auto symC = state.getSymbol("c");

    w.addFact("edge", RelTuple([symA, symB]));
    w.addFact("edge", RelTuple([symB, symC]));

    auto refEdge = new RelationRef(rEdge.name, rEdge.arity, "", rEdge.id, false);
    auto refPath = new RelationRef(rPath.name, rPath.arity, "", rPath.id, false);

    // Rules:
    // path(?x, ?y) :- edge(?x, ?y)
    // path(?x, ?y) :- edge(?x, ?z), path(?z, ?y)
    auto rule1 = new Rule(
        refPath,
        [Term.makeVariable("x", 0), Term.makeVariable("y", 1)],
        [Goal.makePositiveAtom(refEdge, [Term.makeVariable("x", 0), Term.makeVariable("y", 1)])]
    );
    auto rule2 = new Rule(
        refPath,
        [Term.makeVariable("x", 0), Term.makeVariable("y", 1)],
        [
            Goal.makePositiveAtom(refEdge, [Term.makeVariable("x", 0), Term.makeVariable("z", 2)]),
            Goal.makePositiveAtom(refPath, [Term.makeVariable("z", 2), Term.makeVariable("y", 1)])
        ]
    );
    w.registerRule(rule1);
    w.registerRule(rule2);

    // Query: path(?x, ?y)
    Relation[size_t] relMap;
    relMap[rEdge.id] = rEdge;
    relMap[rPath.id] = rPath;
    Rule[] rules = [rule1, rule2];

    auto queryGoal = Goal.makePositiveAtom(refPath, [Term.makeVariable("x", 0), Term.makeVariable("y", 1)]);
    auto iter = new QueryIterator(state, [queryGoal], ["x", "y"], relMap, rules);

    size_t count = 0;
    while (true) {
        auto item = iter.next();
        if (isNil(item)) break;
        count++;
        auto rec = unwrapBindingRecord(item);
        assert(rec.hasBinding("x"));
        assert(rec.hasBinding("y"));
    }
    // Expected paths: (a,b), (b,c), (a,c) = 3 paths
    assert(count == 3);

    writeln("  [PASS] testEvaluatorAndQuery");
}

void testEndToEndScript() {
    auto state = new LuaState();
    openLogicLib(state);

    string script = q"{
        relation link(2)
        relation reachable(2)
        fact link(:x, :y)
        fact link(:y, :z)
        rule reachable(?a, ?b) :- link(?a, ?b)
        rule reachable(?a, ?b) :- link(?a, ?c), reachable(?c, ?b)

        local found = 0
        for b in query reachable(:x, ?dest) do
            found = found + 1
        end
        return found
    }";

    auto res = state.doString(script);
    assert(res.length == 1);
    assert(res[0].match!((long i) => i == 2L, _ => false));

    writeln("  [PASS] testEndToEndScript");
}

void testJoinBindings() {
    auto state = new LuaState();
    openLogicLib(state);
    auto res = state.doString(q"{
        relation pair(2)
        fact pair(nil, nil)
        fact pair(1, 1.0)
        fact pair(1, 2)
        fact pair(2, 1)
        local same, joined = 0, 0
        for row in query pair(?x, ?x) do same = same + 1 end
        for row in query {pair(?x, ?y), pair(?y, ?x)} do
            joined = joined + 1
        end
        return same, joined
    }");
    assert(res.length == 2);
    assert(luaRawEqual(res[0], LuaValue(2L)));
    assert(luaRawEqual(res[1], LuaValue(4L)));
    writeln("  [PASS] testJoinBindings");
}

int main() {
    writeln("Running dlua Declarative Logic Unit Tests...");
    testSymbolsAndTuples();
    testWorldAndRelations();
    testValidation();
    testEvaluatorAndQuery();
    testEndToEndScript();
    testJoinBindings();
    writeln("All Declarative Logic Tests Passed Successfully!");
    return 0;
}

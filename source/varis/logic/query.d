/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.logic.query;

import varis.types;
import varis.table;
import varis.state;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.world;
import varis.logic.evaluate;
import std.format : format;

/// An immutable query binding record mapping variable names to Lua values
class BindingRecord {
    bool[string] hasField;
    LuaValue[string] fields;

    this(LuaValue[string] map) {
        foreach (k, v; map) {
            hasField[k] = true;
            fields[k] = v;
        }
    }

    bool hasBinding(string name) const {
        return (name in hasField) !is null;
    }

    LuaValue getBinding(string name) const {
        if (name !in hasField) {
            throw new LuaException(format("variable '%s' not found in binding record", name));
        }
        return fields.get(name, luaNil());
    }

    LuaValue getField(string name) const {
        return fields.get(name, luaNil());
    }

    override string toString() const {
        import std.array : appender;

        auto app = appender!string();
        app.put("{");
        size_t idx = 0;
        foreach (k, v; fields) {
            if (idx > 0)
                app.put(", ");
            app.put(format("%s = %s", k, toLuaString(v)));
            idx++;
        }
        app.put("}");
        return app.data;
    }
}

/// Create a Lua metatable for BindingRecord protecting immutability
private LuaTable g_bindingRecordMetatable = null;

LuaTable getBindingRecordMetatable(LuaState state) {
    if (g_bindingRecordMetatable !is null)
        return g_bindingRecordMetatable;

    auto mt = new LuaTable();
    mt.rawset(LuaValue("__name"), LuaValue("binding_record"));

    // __index: function(rec, key)
    mt.rawset(LuaValue("__index"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                if (args.length < 2)
                    return [luaNil()];
                auto ud = args[0].match!((LuaUserData u) => u, _ => null);
                if (ud !is null && ud.payload !is null) {
                    if (auto rec = cast(BindingRecord) ud.payload) {
                        string key = args[1].match!((string s) => s, _ => toLuaString(args[1]));
                        return [rec.getField(key)];
                    }
                }
                return [luaNil()];
            }, "__index")));

    // __newindex: reject modification
    mt.rawset(LuaValue("__newindex"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                throw new LuaException("cannot modify immutable binding record");
                return cast(LuaValue[])[];
            }, "__newindex")));

    // __tostring
    mt.rawset(LuaValue("__tostring"), LuaValue(new LuaNativeFunction((void* s, LuaValue[] args) {
                if (args.length > 0) {
                    auto ud = args[0].match!((LuaUserData u) => u, _ => null);
                    if (ud !is null && ud.payload !is null) {
                        if (auto rec = cast(BindingRecord) ud.payload) {
                            return [LuaValue(rec.toString())];
                        }
                    }
                }
                return [LuaValue("binding_record")];
            }, "__tostring")));

    g_bindingRecordMetatable = mt;
    return mt;
}

/// Wrap a BindingRecord in a LuaUserData with immutable metatable
LuaValue wrapBindingRecord(LuaState state, BindingRecord rec) {
    auto mt = getBindingRecordMetatable(state);
    auto ud = new LuaUserData(rec, mt);
    return LuaValue(ud);
}

/// Unwrap BindingRecord or throw
BindingRecord unwrapBindingRecord(LuaValue val) {
    if (val.typeOf() == LuaType.UserData) {
        auto ud = val.match!((LuaUserData u) => u, _ => null);
        if (ud !is null && ud.payload !is null) {
            if (auto rec = cast(BindingRecord) ud.payload) {
                return rec;
            }
        }
    }
    throw new LuaException("expected binding record");
}

/// A snapshot query iterator preserving point-in-time state
class QueryIterator {
    LuaState state;
    Goal[] goals;
    string[] returnedVarNames;

    // Captured snapshot of relations and rules
    Relation[size_t] snapshotRels;
    Rule[] snapshotRules;

    bool evaluated = false;
    bool isInvalid = false;
    size_t currentIndex = 0;
    BindingRecord[] resultRecords;

    this(
            LuaState state,
            Goal[] goals,
            string[] returnedVarNames,
            Relation[size_t] closureRels,
            Rule[] closureRules
    ) {
        if (auto transaction = currentTransaction()) {
            transaction.invalidateIterators ~= { this.isInvalid = true; };
        }
        this.state = state;
        this.goals = goals;
        this.returnedVarNames = returnedVarNames;

        // Traverse only query dependencies. Local rule references retain their live
        // relations even after the declaring stack frame has gone away.
        bool[Rule] seenRules;
        void snapshot(RelationRef reference) {
            if (reference.relId in this.snapshotRels)
                return;
            auto rel = closureRels.get(reference.relId, reference.resolvedRelation);
            if (rel is null) {
                throw new LuaException(format("missing query dependency relation '%s'", reference.name));
            }
            auto visible = visibleRelation(rel);
            auto clonedRel = new Relation(rel.id, rel.name, rel.arity, rel.ownerWorld, rel.isLocal);
            foreach (tuple, _; visible.baseFacts) {
                clonedRel.baseFacts[tuple] = true;
            }
            this.snapshotRels[rel.id] = clonedRel;

            void includeRule(Rule rule) {
                if (rule in seenRules)
                    return;
                seenRules[rule] = true;
                clonedRel.rules ~= rule;
                this.snapshotRules ~= rule;
                foreach (goal; flattenGoals(rule.bodyGoals)) {
                    if (goal.relRef !is null)
                        snapshot(goal.relRef);
                }
            }

            foreach (rule; rel.rules)
                includeRule(rule);
            // Direct engine callers may supply rules separately from Relation.rules.
            foreach (rule; closureRules) {
                if (rule.headRel.relId == rel.id)
                    includeRule(rule);
            }
        }

        foreach (goal; flattenGoals(goals)) {
            if (goal.relRef !is null)
                snapshot(goal.relRef);
        }
    }

    /// Advance iterator. Returns next BindingRecord or nil when exhausted.
    LuaValue next() {
        if (isInvalid) {
            throw new LuaException("attempt to call an invalid query iterator");
        }

        if (!evaluated) {
            evaluated = true;
            try {
                auto evaluator = Evaluator(state);
                auto rawResults = evaluator.evaluateQuery(goals, snapshotRels, snapshotRules, returnedVarNames);
                foreach (res; rawResults) {
                    resultRecords ~= new BindingRecord(res);
                }
            } catch (Exception e) {
                isInvalid = true;
                throw e;
            }
        }

        if (currentIndex < resultRecords.length) {
            auto rec = resultRecords[currentIndex++];
            return wrapBindingRecord(state, rec);
        }

        // Exhausted: returns nil forever (§12.5)
        return luaNil();
    }
}

/// Create a callable Lua iterator function from a QueryIterator
class LuaQueryFunction : LuaNativeFunction {
    QueryIterator iterator;
    this(QueryIterator iterator) {
        this.iterator = iterator;
        super((void* sPtr, LuaValue[] args) { return [iterator.next()]; }, "query_iterator");
    }
}

LuaValue createCallableQueryIterator(LuaState state, QueryIterator iter) {
    return LuaValue(new LuaQueryFunction(iter));
}

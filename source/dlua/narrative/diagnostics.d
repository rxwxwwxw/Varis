/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** dlua - D port of Lua 5.4
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 dlua contributors.
** See LICENSE for license details.
*/

module dlua.narrative.diagnostics;

import dlua.types;
import dlua.state;
import dlua.vm;
import dlua.table;
import dlua.exception : LuaException;
import dlua.logic.world;
import dlua.logic.model;
import dlua.logic.query;
import dlua.logic.evaluate;
import dlua.narrative.registry;
import dlua.narrative.session;
import dlua.narrative.codec;
import std.conv : to;
import std.algorithm : sort;

LuaValue[string] diagnosticBindings(LuaValue value) {
    if (isNil(value)) return null;
    auto userdata = value.match!((LuaUserData u) => u, _ => null);
    if (userdata !is null) {
        if (auto record = cast(ImmutableRecord)userdata.payload) return record.fields.dup;
        if (auto record = cast(BindingRecord)userdata.payload) return record.fields.dup;
    }
    auto table = value.match!((LuaTable t) => t, _ => null);
    if (table is null) throw new LuaException("explanation bindings must be a table or immutable record");
    LuaValue[string] result;
    LuaValue previous, key, field;
    while (table.next(previous, key, field)) {
        previous = key;
        if (!isString(key)) throw new LuaException("explanation binding names must be strings");
        result[key.match!((string s) => s, _ => "")] = field;
    }
    return result;
}

private LuaValue termDescription(Term term) {
    LuaValue[string] fields = ["kind":LuaValue(term.kind.to!string)];
    if (term.kind == TermKind.Constant) fields["value"] = term.constantValue;
    if (term.kind == TermKind.Variable) fields["name"] = LuaValue(term.varName);
    return immutableRecord(fields);
}

private LuaValue goalDescription(Goal goal, size_t index, size_t before, size_t after, string outcome, string error = "") {
    LuaValue[] terms;
    foreach (term; goal.terms) terms ~= termDescription(term);
    LuaValue[string] fields = ["index":LuaValue(cast(long)index + 1), "kind":LuaValue(goal.kind.to!string),
        "before":LuaValue(cast(long)before), "after":LuaValue(cast(long)after), "outcome":LuaValue(outcome), "terms":immutableSequence(terms)];
    if (goal.relRef !is null) fields["relation"] = LuaValue(goal.relRef.name);
    if (goal.kind == GoalKind.Comparison) {
        fields["operator"] = LuaValue(goal.compOp.to!string); fields["left"] = termDescription(goal.leftTerm); fields["right"] = termDescription(goal.rightTerm);
    }
    if (goal.kind == GoalKind.Aggregate) { fields["operation"] = LuaValue(goal.aggregateOp); fields["result"] = LuaValue(goal.resultVariable); }
    if (error.length) fields["error"] = LuaValue(error);
    return immutableRecord(fields);
}

/// Prefix outcomes use actual evaluator order; blocked goals are identified as
/// not reached, rather than presented as independently false recursive proofs.
private LuaValue traceAvailability(Session session, ContentDefinition definition, World snapshot, LuaValue[string] bindings) {
    if (!isFunction(definition.availability)) return immutableRecord(["success":LuaValue(true), "goals":immutableSequence([])]);
    LuaValue[] args = [wrapWorld(snapshot)];
    foreach (name; definition.incomingParameters) args ~= bindings.get(name, luaNil());
    auto returned = VM.callValue(session.state, definition.availability, args);
    auto function_ = returned.length ? returned[0].match!((LuaFunction f) => cast(LuaQueryFunction)f, _ => null) : null;
    if (function_ is null) throw new LuaException("content availability did not return a typed query iterator");
    auto query = function_.iterator;
    size_t[] order;
    foreach (kind; [GoalKind.PositiveAtom, GoalKind.Aggregate, GoalKind.Comparison, GoalKind.Guard, GoalKind.NegatedAtom])
        foreach (index, goal; query.goals) if (goal.kind == kind) order ~= index;
    LuaValue[] outcomes; outcomes.length = query.goals.length;
    Goal[] prefix;
    size_t count = 1;
    bool failed;
    string errorMessage;
    foreach (index; order) {
        auto goal = query.goals[index];
        if (failed) { outcomes[index] = goalDescription(goal, index, 0, 0, "not_reached"); continue; }
        prefix ~= goal;
        bool[string] variables;
        foreach (name; bindings.keys) variables[name] = true;
        foreach (entry; prefix) foreach (name; goalVariables(entry)) variables[name] = true;
        auto names = variables.keys; names.sort;
        size_t before = count;
        try {
            auto evaluator = Evaluator(session.state);
            auto rows = evaluator.evaluateQuery(prefix, query.snapshotRels, query.snapshotRules, names, bindings);
            count = 0;
            foreach (row; rows) {
                bool compatible = true;
                foreach (name, value; bindings) {
                    auto actual = name in row;
                    if (actual is null || !luaRawEqual(*actual, value)) { compatible = false; break; }
                }
                if (compatible) count++;
            }
            outcomes[index] = goalDescription(goal, index, before, count, count ? "success" : "failure");
            if (!count) failed = true;
        } catch (LuaException error) {
            failed = true; count = 0; errorMessage = error.msg;
            outcomes[index] = goalDescription(goal, index, before, 0, "error", error.msg);
        }
    }
    return immutableRecord(["success":LuaValue(!failed), "goals":immutableSequence(outcomes), "error":LuaValue(errorMessage)]);
}

private bool matches(ContentInstance instance, LuaValue[string] bindings) {
    foreach (name, value; bindings) {
        auto existing = name in instance.bindings;
        if (existing is null || !luaRawEqual(*existing, value)) return false;
    }
    return true;
}

private LuaValue[] exclusions(Session session, ContentInstance instance) {
    LuaValue[] result;
    auto data = session.data;
    if (instance.definition.kind == "action") {
        try {
            auto key = session.onceKey(instance, data);
            if (key.length && key in data.actionHistory) result ~= session.state.getSymbol("once_per");
        } catch (LuaException error) { result ~= immutableRecord(["reason":session.state.getSymbol("period_unset"), "error":LuaValue(error.msg)]); }
        return result;
    }
    if (instance.definition.symbolOption("deck", "default") != session.activeDeck()) result ~= session.state.getSymbol("deck");
    if (auto previous = instance.key in data.completed) {
        if (!instance.definition.option("repeatable", LuaValue(true)).match!((bool b) => b, _ => true)) result ~= session.state.getSymbol("completed");
        if (data.turn - *previous < cast(ulong)instance.definition.integerOption("cooldown", 0)) result ~= session.state.getSymbol("cooldown");
    }
    double weight = instance.definition.option("weight", LuaValue(1L)).match!((long n) => cast(double)n, (double n) => n, _ => 0.0);
    if (!weight) result ~= session.state.getSymbol("zero_weight");
    auto deck = session.registry.deck(session.activeDeck());
    if (!deck.replacement && !instance.definition.sticky && instance.key in data.decks[$ - 1].drawn) result ~= session.state.getSymbol("already_drawn");
    return result;
}

LuaValue explainContent(Session session, string id, LuaValue[string] bindings = null) {
    session.requireIdle();
    auto definition = session.registry.storylet(id);
    if (definition is null) definition = session.registry.action(id);
    if (definition is null) throw new LuaException("unknown narrative content '" ~ id ~ "'");
    bool[string] parameters;
    foreach (name; definition.parameters) parameters[name] = true;
    foreach (name, value; bindings) {
        if (name !in parameters) throw new LuaException("unknown explanation parameter '" ~ name ~ "'");
        canonicalScalar(value);
    }
    auto snapshot = session.world.cloneSnapshot();
    beginReadOnlyEvaluation(); scope(exit) endReadOnlyEvaluation();
    auto trace = traceAvailability(session, definition, snapshot, bindings);
    bool available = VM.getTable(session.state, trace, LuaValue("success")).isTruthy();
    LuaValue[] instances;
    bool eligible;
    if (available) foreach (instance; session.instances(definition, snapshot)) if (matches(instance, bindings)) {
        auto excluded = exclusions(session, instance);
        bool allowed = excluded.length == 0; eligible = eligible || allowed;
        LuaValue[] choices;
        foreach (choice; definition.choices) {
            auto choiceTrace = traceAvailability(session, choice, snapshot, instance.bindings);
            choices ~= immutableRecord(["id":session.state.getSymbol(choice.id), "availability":choiceTrace]);
        }
        instances ~= immutableRecord(["instance_key":LuaValue(instance.key), "bindings":immutableRecord(instance.bindings),
            "eligible":LuaValue(allowed), "exclusions":immutableSequence(excluded), "choices":immutableSequence(choices)]);
    }
    return immutableRecord(["id":session.state.getSymbol(id), "kind":LuaValue(definition.kind), "eligible":LuaValue(eligible),
        "availability":trace, "instances":immutableSequence(instances), "world_version":LuaValue(cast(long)session.world.version_)]);
}

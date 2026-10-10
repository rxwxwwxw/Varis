/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.observe;

import varis.types;
import varis.state;
import varis.vm;
import varis.table;
import varis.exception : LuaException;
import varis.logic.world;
import varis.logic.model;
import varis.logic.query;
import varis.narrative.codec;
import varis.narrative.session : currentEffectSession;
import std.algorithm : sort;
import std.conv : to;
import std.format : format;
import std.math : isFinite;

/// Raw reference values have a stable per-process address order; portable scalar
/// order uses the same canonical equality encoding as narrative instance keys.
string observationValueKey(LuaValue value) {
    if (isNumber(value)) {
        auto number = value.match!((long n) => cast(double) n, (double n) => n, _ => 0.0);
        if (!isFinite(number))
            return number < 0 ? "f-inf" : "f+inf";
    }
    try {
        return canonicalScalar(value);
    } catch (LuaException error) {
    }
    auto identity = value.match!(
            (LuaTable object) => cast(size_t) cast(void*) object,
            (LuaFunction object) => cast(size_t) cast(void*) object,
            (LuaUserData object) => cast(size_t) cast(void*) object,
            (LuaThread object) => cast(size_t) cast(void*) object,
            (LightUserData pointer) => cast(size_t) pointer.ptr,
            _ => cast(size_t) 0);
    return "r" ~ value.typeOf().to!string ~ format("%016x", identity);
}

string observationTupleKey(RelTuple tuple) {
    string result;
    foreach (value; tuple.values) {
        auto encoded = observationValueKey(value);
        result ~= encoded.length.to!string ~ ":" ~ encoded;
    }
    return result;
}

bool[RelTuple] committedVisibleSet(LuaState state, World world, string name) {
    auto relation = world.getRelation(name);
    if (relation is null)
        throw new LuaException("unknown observed relation '" ~ name ~ "'");
    auto reference = new RelationRef(name, relation.arity, "", relation.id);
    reference.resolvedRelation = relation;
    Term[] terms;
    string[] names;
    foreach (i; 0 .. relation.arity) {
        auto variable = "column" ~ i.to!string;
        terms ~= Term.makeVariable(variable, i);
        names ~= variable;
    }
    auto goal = new Goal(GoalKind.PositiveAtom);
    goal.relRef = reference;
    goal.terms = terms;
    beginReadOnlyEvaluation();
    scope (exit)
        endReadOnlyEvaluation();
    auto iterator = new QueryIterator(state, [goal], names, null, null);
    bool[RelTuple] result;
    while (true) {
        auto value = iterator.next();
        if (isNil(value))
            break;
        auto record = unwrapBindingRecord(value);
        LuaValue[] tuple;
        foreach (variable; names)
            tuple ~= record.fields[variable];
        result[RelTuple(tuple)] = true;
    }
    return result;
}

private class Subscription {
    string name;
    LuaValue onEnter;
    LuaValue onLeave;
    bool[RelTuple] baseline;
    bool active = true;
}

private struct Delta {
    string name;
    RelTuple tuple;
    bool enters;
    string key;
}

private class ObserverHub {
    LuaState state;
    World world;
    Subscription[] subscriptions;
    LuaValue[] queued;
    bool flushing;

    this(LuaState state, World world) {
        this.state = state;
        this.world = world;
    }

    void requireIdle() {
        if (world.notifyingDepth || currentTransaction() !is null || currentEffectSession() !is null || isReadOnlyEvaluation())
            throw new LuaException("observer operation requires an idle world");
    }

    void dispatch() {
        // Compute every new visible set before touching baselines or callbacks.
        bool[RelTuple][string] current;
        foreach (subscription; subscriptions)
            if (subscription.active && subscription.name !in current)
                current[subscription.name] = committedVisibleSet(state, world, subscription.name);
        Delta[] deltas;
        bool[RelTuple][string] enters, leaves;
        foreach (subscription; subscriptions)
            if (subscription.active) {
                auto next = current[subscription.name];
                foreach (tuple; subscription.baseline.keys)
                    if (tuple !in next)
                        leaves[subscription.name][tuple] = true;
                foreach (tuple; next.keys)
                    if (tuple !in subscription.baseline)
                        enters[subscription.name][tuple] = true;
            }
        foreach (name, tuples; leaves)
            foreach (tuple; tuples.keys)
                deltas ~= Delta(name, tuple, false, observationTupleKey(tuple));
        foreach (name, tuples; enters)
            foreach (tuple; tuples.keys)
                deltas ~= Delta(name, tuple, true, observationTupleKey(tuple));
        // A second subscription may be installed at a different baseline. Compute
        // its own delivery selection against the delta universe before publishing.
        bool[RelTuple][Subscription] old;
        foreach (subscription; subscriptions)
            if (subscription.active) {
                old[subscription] = subscription.baseline;
                subscription.baseline = current[subscription.name];
            }
        deltas.sort!((a, b) => a.name < b.name || (a.name == b.name && (a.key < b.key || (a.key == b.key && !a.enters && b
                .enters))));
        auto previous = currentHub;
        currentHub = this;
        world.notifyingDepth++;
        beginNotificationDispatch();
        scope (exit) {
            endNotificationDispatch();
            world.notifyingDepth--;
            currentHub = previous;
        }
        Exception firstError;
        foreach (delta; deltas)
            foreach (subscription; subscriptions)
                if (subscription.active && subscription.name == delta.name) {
                    bool existed = (delta.tuple in old[subscription]) !is null;
                    if (delta.enters == existed)
                        continue;
                    auto callback = delta.enters ? subscription.onEnter : subscription.onLeave;
                    if (!isFunction(callback))
                        continue;
                    try {
                        VM.callValue(state, callback, [immutableSequence(delta.tuple.values)]);
                    } catch (Exception error) {
                        if (firstError is null)
                            firstError = error;
                    }
                }
        if (firstError !is null)
            throw firstError;
    }

    void flush(size_t limit) {
        requireIdle();
        if (flushing)
            throw new LuaException("recursive observer queue flush");
        flushing = true;
        scope (exit)
            flushing = false;
        size_t count;
        while (queued.length) {
            if (count >= limit)
                throw new LuaException("OBSERVER_QUEUE_LIMIT: queued observer command budget exhausted");
            auto callback = queued[0];
            queued = queued[1 .. $];
            VM.callValue(state, callback, []);
            count++;
        }
    }
}

private ObserverHub currentHub;

LuaValue observeRelation(LuaState state, World world, string name, LuaValue callbacks) {
    if (world.transactionOwner !is null)
        throw new LuaException("cannot observe world with an active transaction");
    auto table = callbacks.match!((LuaTable table) => table, _ => null);
    if (table is null)
        throw new LuaException("observer callbacks must be a table");
    auto subscription = new Subscription();
    subscription.name = name;
    subscription.onEnter = table.rawget(LuaValue("on_enter"));
    subscription.onLeave = table.rawget(LuaValue("on_leave"));
    foreach (callback; [subscription.onEnter, subscription.onLeave])
        if (!isNil(callback) && !isFunction(callback))
            throw new LuaException("observer callback must be a function");
    if (isNil(subscription.onEnter) && isNil(subscription.onLeave))
        throw new LuaException("observer requires on_enter or on_leave");
    auto hub = cast(ObserverHub) world.observerState;
    if (hub is null)
        hub = new ObserverHub(state, world);
    if (hub.state !is state)
        throw new LuaException("observed world belongs to another Lua state");
    hub.requireIdle();
    subscription.baseline = committedVisibleSet(state, world, name);
    hub.subscriptions ~= subscription;
    world.observerState = hub;
    world.committedChange = &hub.dispatch;
    return LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
            hub.requireIdle();
            subscription.active = false;
            return cast(LuaValue[])[];
        }, "cancel_observer"));
}

void enqueueObserverCommand(LuaValue callback) {
    if (currentHub is null)
        throw new LuaException("enqueue requires an active observer callback");
    if (!isFunction(callback))
        throw new LuaException("queued observer command must be a function");
    currentHub.queued ~= callback;
}

void flushObserverCommands(World world, size_t limit = 1000) {
    if (!limit)
        throw new LuaException("observer queue limit must be positive");
    if (auto hub = cast(ObserverHub) world.observerState)
        hub.flush(limit);
}

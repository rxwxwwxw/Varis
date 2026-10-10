/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.session;

import varis.types;
import varis.state;
import varis.table;
import varis.vm;
import varis.exception : LuaException;
import varis.logic.world;
import varis.logic.model;
import varis.logic.query;
import varis.narrative.registry;
import varis.narrative.codec;
import varis.narrative.templates : NarrativeTemplate;
import std.algorithm : sort;
import std.conv : to;
import std.math : isFinite;
import core.thread : Fiber;

struct DeckEntry {
    string name;
    ulong identity;
    bool[string] drawn;
    DeckEntry copy() {
        return DeckEntry(name, identity, drawn.dup);
    }
}

struct NarrativeEvent {
    ulong sequence;
    ulong turn;
    string kind;
    LuaValue arguments;
}

struct ScheduledEvent {
    ulong due;
    ulong sequence;
    string kind;
    LuaValue arguments;
}

class SessionData {
    ulong turn;
    ulong rng;
    bool seeded;
    long initialSeed;
    DeckEntry[] decks;
    ulong nextDeck = 1;
    ulong nextToken = 1;
    ulong nextSchedule = 1;
    ulong[string] completed;
    bool[string] actionHistory;
    LuaValue[string] periods;
    NarrativeEvent[] events;
    ScheduledEvent[] scheduled;
    bool[ulong] consumedTokens;
    LuaValue[] replayInputs;

    SessionData copy() {
        auto result = new SessionData();
        result.turn = turn;
        result.rng = rng;
        result.seeded = seeded;
        result.initialSeed = initialSeed;
        result.nextDeck = nextDeck;
        result.nextToken = nextToken;
        result.nextSchedule = nextSchedule;
        foreach (entry; decks)
            result.decks ~= entry.copy();
        result.completed = completed.dup;
        result.actionHistory = actionHistory.dup;
        result.periods = periods.dup;
        result.events = events.dup;
        result.scheduled = scheduled.dup;
        result.consumedTokens = consumedTokens.dup;
        result.replayInputs = replayInputs.dup;
        return result;
    }
}

class ContentInstance {
    ContentDefinition definition;
    LuaValue[string] bindings;
    LuaValue[] values;
    string key;
    ulong worldVersion;
}

/// Opaque token identity is issued by a session, never reconstructed from text.
class ChoiceToken {
    Session session;
    ContentInstance storylet;
    ContentInstance choice;
    ulong deckEntry;
    ulong identity;
}

private Session[Fiber] effectSessions;
Session currentEffectSession() {
    return effectSessions.get(Fiber.getThis(), null);
}

Session requireEffectSession() {
    auto session = currentEffectSession();
    if (session is null || currentTransaction() is null || currentTransaction().world !is session.world)
        throw new LuaException("narrative command requires an active transactional effect");
    if (isReadOnlyEvaluation())
        throw new LuaException("narrative command prohibited during read-only evaluation");
    return session;
}

/// Session state participates in exactly the same savepoints as relational facts.
class Session : TransactionParticipant {
    LuaState state;
    World world;
    ContentRegistry registry;
    SessionData data;
    bool busy;
    size_t actionLimit = 1000;
    size_t eventLimit = 1000;
    private Relation eventRelation;

    private this() {
    }
    /// Engine-only shell used while copying cyclic analysis object graphs.
    static Session analysisShell(LuaState state, World world) {
        auto session = new Session();
        session.state = state;
        session.world = world;
        session.registry = state.narrativeRegistry;
        if (world !is null)
            session.bindAnalysisWorld(world);
        return session;
    }

    void bindAnalysisWorld(World world) {
        this.world = world;
        this.eventRelation = world.getRelation("narrative_event");
        world.narrativeOwner = this;
    }

    this(LuaState state, World world, bool adoptHistory = false) {
        if (currentTransaction() !is null || currentEffectSession() !is null || isReadOnlyEvaluation())
            throw new LuaException("cannot create session during an active operation");
        if (world.transactionOwner !is null)
            throw new LuaException("world has an active transaction");
        if (world.narrativeOwner !is null)
            throw new LuaException("world already belongs to a narrative session");
        this.state = state;
        this.world = world;
        this.registry = state.narrativeRegistry;
        if (state.configureWorld !is null)
            state.configureWorld(world);
        registry.seal();
        eventRelation = world.getRelation("narrative_event");
        if (eventRelation !is null && (!eventRelation.protectedRelation || eventRelation.arity != 4))
            throw new LuaException("narrative_event is reserved for read-only session history");
        if (eventRelation is null) {
            eventRelation = world.declareNamedRelation("narrative_event", [
                "sequence", "turn", "kind", "args"
            ], []);
            eventRelation.protectedRelation = true;
        }
        if (!adoptHistory && eventRelation.baseFacts.length)
            throw new LuaException("world contains narrative history; restore or clone its session state");
        data = new SessionData();
        data.decks ~= DeckEntry("default", data.nextDeck++, null);
        world.narrativeOwner = this;
    }

    override Object committedState() {
        return data;
    }

    override Object copyState(Object value) {
        return (cast(SessionData) value).copy();
    }

    override void prepareCommit(Transaction transaction, Object value) {
        auto tentative = cast(SessionData) value;
        foreach (event; tentative.events[data.events.length .. $]) {
            eventRelation.appendSystemFact(RelTuple([
                LuaValue(cast(long) event.sequence), LuaValue(cast(long) event.turn),
                state.getSymbol(event.kind), event.arguments
            ]));
        }
    }

    override void publishState(Object value) {
        data = cast(SessionData) value;
    }

    SessionData view() {
        auto transaction = currentTransaction();
        return transaction !is null && transaction.world is world ? cast(SessionData) transaction.readParticipant(
                this) : data;
    }

    SessionData edit() {
        if (isReadOnlyEvaluation())
            throw new LuaException("session mutation prohibited during read-only evaluation");
        auto transaction = currentTransaction();
        if (transaction !is null) {
            if (transaction.world !is world)
                throw new LuaException("cross-world session mutation during a transaction");
            return cast(SessionData) transaction.writeParticipant(this);
        }
        return data;
    }

    void requireIdle() {
        if (busy || currentEffectSession() !is null || currentTransaction() !is null || world
                .transactionOwner !is null || world.notifyingDepth || isReadOnlyEvaluation())
            throw new LuaException("recursive or conflicting narrative session command");
    }

    void seed(long seed) {
        requireIdle();
        auto value = cast(ulong) seed + 0x9e3779b97f4a7c15UL;
        value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9UL;
        value = (value ^ (value >> 27)) * 0x94d049bb133111ebUL;
        data.rng = value ^ (value >> 31);
        if (!data.rng)
            data.rng = 0x9e3779b97f4a7c15UL;
        data.initialSeed = seed;
        data.seeded = true;
        data.replayInputs ~= immutableRecord([
            "kind": state.getSymbol("seed"),
            "value": LuaValue(seed)
        ]);
    }

    void setLimits(size_t actions, size_t events) {
        requireIdle();
        if (!actions || !events)
            throw new LuaException("narrative execution limits must be positive");
        actionLimit = actions;
        eventLimit = events;
        data.replayInputs ~= immutableRecord([
            "kind": state.getSymbol("limits"),
            "value": immutableSequence([LuaValue(cast(long) actions), LuaValue(cast(long) events)])
        ]);
    }

    void setPeriod(string period, LuaValue value) {
        encodeValue(value, "period");
        auto active = currentEffectSession();
        if (active is this)
            requireEffectSession();
        else
            requireIdle();
        edit().periods[period] = value;
        if (active is null)
            data.replayInputs ~= immutableRecord([
            "kind": state.getSymbol("period"),
            "value": immutableSequence([state.getSymbol(period), value])
        ]);
    }

    string activeDeck() {
        return view().decks[$ - 1].name;
    }

    void pushDeck(string name) {
        registry.deck(name);
        auto value = edit();
        if (value.nextDeck == ulong.max)
            throw new LuaException("deck identity exhausted");
        value.decks ~= DeckEntry(name, value.nextDeck++, null);
    }

    void popDeck() {
        if (view().decks.length <= 1)
            throw new LuaException("cannot pop the last narrative deck");
        edit().decks.length--;
    }

    void replaceDeck(string name) {
        registry.deck(name);
        auto value = edit();
        if (value.nextDeck == ulong.max)
            throw new LuaException("deck identity exhausted");
        value.decks[$ - 1] = DeckEntry(name, value.nextDeck++, null);
    }

    void resetDeck() {
        edit().decks[$ - 1].drawn = null;
    }

    void emit(string kind, LuaValue[] arguments) {
        foreach (i, value; arguments)
            encodeValue(value, "event[" ~ i.to!string ~ "]");
        auto value = edit();
        if (value.events.length >= long.max)
            throw new LuaException("narrative event sequence exhausted");
        value.events ~= NarrativeEvent(value.events.length + 1, value.turn, kind, immutableSequence(arguments));
    }

    void schedule(string kind, LuaValue arguments, long afterTurns) {
        if (afterTurns < 0)
            throw new LuaException("scheduled delay must be nonnegative");
        encodeValue(arguments, "scheduled arguments");
        auto sequence = arguments.match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
        if (sequence is null)
            throw new LuaException("scheduled arguments must be an immutable sequence");
        auto existing = view();
        if (cast(ulong) afterTurns > cast(ulong) long.max - existing.turn)
            throw new LuaException("scheduled turn overflow");
        auto value = edit();
        if (value.nextSchedule == ulong.max)
            throw new LuaException("scheduled event identity exhausted");
        value.scheduled ~= ScheduledEvent(value.turn + afterTurns, value.nextSchedule++, kind, arguments);
    }

    private void runEffect(void delegate() operation) {
        auto transaction = new Transaction(world);
        scope (exit)
            if (!transaction.finished)
                transaction.finish(false);
        auto previous = currentEffectSession();
        effectSessions[Fiber.getThis()] = this;
        scope (exit) {
            if (previous is null)
                effectSessions.remove(Fiber.getThis());
            else
                effectSessions[Fiber.getThis()] = previous;
        }
        operation();
        if (previous is null)
            effectSessions.remove(Fiber.getThis());
        else
            effectSessions[Fiber.getThis()] = previous;
        transaction.finish(true);
    }

    ContentInstance[] instances(ContentDefinition definition, World snapshot, LuaValue[string] inputs = null) {
        beginReadOnlyEvaluation();
        scope (exit)
            endReadOnlyEvaluation();
        LuaValue[string][] rows;
        if (isFunction(definition.availability)) {
            LuaValue[] args = [wrapWorld(snapshot)];
            foreach (name; definition.incomingParameters)
                args ~= inputs.get(name, luaNil());
            auto returned = VM.callValue(state, definition.availability, args);
            if (!returned.length)
                throw new LuaException("availability callback did not return an iterator");
            // Results live in a per-depth buffer that guard calls made by the iterator reuse.
            auto iterator = returned[0];
            while (true) {
                auto next = VM.callValue(state, iterator, []);
                if (!next.length || isNil(next[0]))
                    break;
                rows ~= unwrapBindingRecord(next[0]).fields;
            }
        } else
            rows ~= (LuaValue[string]).init;
        bool[string] seen;
        ContentInstance[] result;
        foreach (row; rows) {
            auto instance = new ContentInstance();
            instance.definition = definition;
            instance.bindings = inputs.dup;
            foreach (name; definition.parameters) {
                if (name !in row)
                    throw new LuaException("availability did not ground parameter '" ~ name ~ "'");
                auto value = row[name];
                canonicalScalar(value);
                instance.bindings[name] = value;
                instance.values ~= value;
            }
            instance.key = canonicalScalar(state.getSymbol(definition.id)) ~ ":" ~ canonicalBindings(instance.values);
            instance.worldVersion = world.version_;
            if (instance.key !in seen) {
                seen[instance.key] = true;
                result ~= instance;
            }
        }
        result.sort!((left, right) => left.key < right.key);
        return result;
    }

    bool policyAllows(ContentInstance instance, SessionData value, bool requireDeck = true) {
        if (requireDeck && instance.definition.symbolOption("deck", "default") != value.decks[$ - 1].name)
            return false;
        if (auto previous = instance.key in value.completed) {
            if (!instance.definition.option("repeatable", LuaValue(true)).match!((bool b) => b, _ => true))
                return false;
            ulong cooldown = cast(ulong) instance.definition.integerOption("cooldown", 0);
            if (value.turn - *previous < cooldown)
                return false;
        }
        return true;
    }

    private bool stillAvailable(ContentInstance selected, World snapshot, LuaValue[string] inputs = null) {
        foreach (instance; instances(selected.definition, snapshot, inputs))
            if (instance.key == selected.key)
                return true;
        return false;
    }

    private double random(SessionData value) {
        if (!value.seeded)
            throw new LuaException("session RNG must be explicitly seeded before selection");
        ulong x = value.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        value.rng = x;
        ulong draw = x * 2685821657736338717UL;
        return cast(double)(draw >> 11) * 0x1p-53;
    }

    private double weight(ContentInstance instance) {
        return instance.definition.option("weight", LuaValue(1L)).match!((long n) => cast(double) n, (double n) => n, _ => 0.0);
    }

    private size_t[] selectVariants(NarrativeTemplate template_, SessionData tentative) {
        if (template_ is null || template_.variantGroups.length == 0)
            return null;
        size_t[] chosen;
        foreach (group; template_.variantGroups) {
            double sum = 0.0;
            foreach (opt; group.options)
                sum += opt.weight;
            double target = random(tentative) * sum;
            size_t idx = group.options.length - 1;
            foreach (i, opt; group.options) {
                target -= opt.weight;
                if (target < 0) {
                    idx = i;
                    break;
                }
            }
            chosen ~= idx;
        }
        return chosen;
    }

    LuaValue present() {
        requireIdle();
        busy = true;
        scope (exit)
            busy = false;
        size_t eventCount;
        runPhase("pre", eventCount);
        auto snapshot = world.cloneSnapshot();
        auto tentative = data.copy();
        auto deck = registry.deck(tentative.decks[$ - 1].name);
        ContentInstance[] candidates;
        ContentInstance[] pinned;
        foreach (definition; registry.storylets()) {
            if (definition.symbolOption("deck", "default") != tentative.decks[$ - 1].name)
                continue;
            foreach (instance; instances(definition, snapshot)) {
                if (!policyAllows(instance, tentative) || weight(instance) == 0)
                    continue;
                if (instance.definition.sticky) {
                    pinned ~= instance;
                    continue;
                }
                if (!deck.replacement && instance.key in tentative.decks[$ - 1].drawn)
                    continue;
                candidates ~= instance;
            }
        }
        candidates.sort!((left, right) => left.definition.integerOption("priority", 0) > right.definition.integerOption(
                "priority", 0) ||
                (left.definition.integerOption("priority", 0) == right.definition.integerOption("priority", 0) && left
                    .key < right.key));
        ContentInstance[] selected;
        while (candidates.length && selected.length < deck.draw) {
            long priority = candidates[0].definition.integerOption("priority", 0);
            size_t tier;
            double largest;
            while (tier < candidates.length && candidates[tier].definition.integerOption("priority", 0) == priority) {
                auto w = weight(candidates[tier]);
                if (w > largest)
                    largest = w;
                tier++;
            }
            double sum;
            foreach (instance; candidates[0 .. tier])
                sum += weight(instance) / largest;
            double target = random(tentative) * sum;
            size_t chosen = tier - 1;
            foreach (index, instance; candidates[0 .. tier]) {
                target -= weight(instance) / largest;
                if (target < 0) {
                    chosen = index;
                    break;
                }
            }
            selected ~= candidates[chosen];
            tentative.decks[$ - 1].drawn[candidates[chosen].key] = true;
            candidates = candidates[0 .. chosen] ~ candidates[chosen + 1 .. $];
        }
        // Sticky storylets are always listed: no draw slot, no RNG, exempt from non-replacement history.
        selected ~= pinned;
        selected.sort!((left, right) {
            auto lo = left.definition.integerOption("order", 0), ro = right.definition.integerOption("order", 0);
            if (lo != ro)
                return lo < ro;
            auto lp = left.definition.integerOption("priority", 0), rp = right.definition.integerOption("priority", 0);
            return lp > rp || (lp == rp && left.key < right.key);
        });
        LuaValue[] stories;
        LuaValue[] variantLog;
        void logVariants(string key, string field, size_t[] vars) {
            if (!vars.length)
                return;
            LuaValue[] indices;
            foreach (idx; vars)
                indices ~= LuaValue(cast(long) idx);
            variantLog ~= immutableRecord([
                "key": LuaValue(key),
                "field": LuaValue(field),
                "indices": immutableSequence(indices)
            ]);
        }

        foreach (story; selected) {
            auto storyTitleVars = selectVariants(story.definition.titleTemplate, tentative);
            auto storyTextVars = selectVariants(story.definition.textTemplate, tentative);
            logVariants(story.key, "title", storyTitleVars);
            logVariants(story.key, "text", storyTextVars);
            LuaValue[] choices;
            foreach (definition; story.definition.choices)
                foreach (choice; instances(definition, snapshot, story.bindings)) {
                    auto choiceTitleVars = selectVariants(definition.titleTemplate, tentative);
                    auto choiceTextVars = selectVariants(definition.textTemplate, tentative);
                    logVariants(choice.key, "title", choiceTitleVars);
                    logVariants(choice.key, "text", choiceTextVars);
                    auto token = new ChoiceToken();
                    token.session = this;
                    token.storylet = story;
                    token.choice = choice;
                    if (tentative.nextToken == ulong.max)
                        throw new LuaException("choice token identity exhausted");
                    token.deckEntry = tentative.decks[$ - 1].identity;
                    token.identity = tentative.nextToken++;
                    auto tokenMetatable = new LuaTable();
                    tokenMetatable.rawset(LuaValue("__metatable"), LuaValue("choice token"));
                    tokenMetatable.rawset(LuaValue("__newindex"), LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
                                throw new LuaException("cannot modify immutable choice token");
                                return cast(LuaValue[])[];
                            })));
                    choices ~= immutableRecord([
                        "id": state.getSymbol(definition.id),
                        "instance_key": LuaValue(choice.key),
                        "bindings": immutableRecord(choice.bindings),
                        "title": LuaValue(definition.titleTemplate.render(state, snapshot, choice.bindings, &registry
                                .display, choiceTitleVars)),
                        "text": LuaValue(definition.textTemplate.render(state, snapshot, choice.bindings, &registry
                                .display, choiceTextVars)),
                        "token": LuaValue(new LuaUserData(token, tokenMetatable))
                    ]);
                }
            stories ~= immutableRecord([
                "id": state.getSymbol(story.definition.id),
                "instance_key": LuaValue(story.key),
                "bindings": immutableRecord(story.bindings),
                "title": LuaValue(story.definition.titleTemplate.render(state, snapshot, story.bindings, &registry
                        .display, storyTitleVars)),
                "text": LuaValue(story.definition.textTemplate.render(state, snapshot, story.bindings, &registry
                        .display, storyTextVars)),
                "world_version": LuaValue(cast(long) story.worldVersion),
                "choices": immutableSequence(choices)
            ]);
        }
        auto presentation = immutableRecord([
            "turn": LuaValue(cast(long) tentative.turn),
            "deck": state.getSymbol(tentative.decks[$ - 1].name),
            "storylets": immutableSequence(stories)
        ]);
        LuaValue[] selections;
        foreach (story; selected)
            selections ~= LuaValue(story.key);
        tentative.replayInputs ~= immutableRecord([
            "kind": state.getSymbol("present"),
            "value": immutableSequence(selections)
        ]);
        if (variantLog.length > 0)
            tentative.replayInputs ~= immutableRecord([
            "kind": state.getSymbol("variants"),
            "value": immutableSequence(variantLog)
        ]);
        data = tentative;
        return presentation;
    }

    void choose(ChoiceToken token) {
        requireIdle();
        busy = true;
        scope (exit)
            busy = false;
        if (token is null || token.session !is this || token.identity in data.consumedTokens)
            throw new LuaException("STALE_CHOICE: invalid or consumed token");
        if (data.turn >= long.max)
            throw new LuaException("narrative turn counter exhausted");
        runEffect({
            auto tentative = view();
            if (token.deckEntry != tentative.decks[$ - 1].identity || !policyAllows(token.storylet, tentative) ||
                !stillAvailable(token.storylet, world) || !stillAvailable(token.choice, world, token.storylet.bindings))
                throw new LuaException("STALE_CHOICE: eligibility or deck changed");
            LuaValue[] args = [wrapWorld(world)];
            foreach (name; token.choice.definition.incomingParameters ~ token.choice.definition.parameters)
                args ~= token.choice.bindings[name];
            VM.callValue(state, token.choice.definition.effect, args);
            auto changes = edit();
            changes.turn++;
            changes.completed[token.storylet.key] = changes.turn;
            changes.consumedTokens[token.identity] = true;
            changes.replayInputs ~= immutableRecord([
                "kind": state.getSymbol("choose"),
                "value": immutableSequence([
                    LuaValue(token.storylet.key), LuaValue(token.choice.key)
                ])
            ]);
        });
        size_t eventCount;
        runPhase("post", eventCount);
    }

    string onceKey(ContentInstance instance, SessionData value) {
        string period = instance.definition.symbolOption("once_per", "turn");
        if (period == "always")
            return "";
        string stamp;
        if (period == "turn")
            stamp = value.turn.to!string;
        else if (period == "game")
            stamp = "game";
        else {
            auto serial = period in value.periods;
            if (serial is null)
                throw new LuaException("unregistered narrative period '" ~ period ~ "'");
            stamp = canonicalPersisted(*serial);
        }
        return instance.key ~ ":period:" ~ canonicalScalar(state.getSymbol(period)) ~ ":" ~ stamp;
    }

    private void runPhase(string phase, ref size_t eventCount) {
        size_t count;
        while (true) {
            processDue(eventCount);
            ContentInstance[] eligible;
            auto snapshot = world.cloneSnapshot();
            foreach (definition; registry.actions())
                if (definition.symbolOption("phase", "post") == phase)
                    foreach (instance; instances(definition, snapshot)) {
                        string key = onceKey(instance, data);
                        if (!key.length || key !in data.actionHistory)
                            eligible ~= instance;
                    }
            if (!eligible.length)
                return;
            if (count >= actionLimit)
                throw new LuaException("ACTION_LIMIT: automatic action phase exhausted");
            eligible.sort!((left, right) => left.definition.integerOption("priority", 0) > right
                    .definition.integerOption("priority", 0) ||
                    (left.definition.integerOption("priority", 0) == right.definition.integerOption("priority", 0) && left
                        .key < right.key));
            auto instance = eligible[0];
            runEffect({
                auto key = onceKey(instance, view());
                if (!stillAvailable(instance, world) || (key.length && key in view().actionHistory))
                    throw new LuaException("automatic action changed during revalidation");
                LuaValue[] args = [wrapWorld(world)];
                args ~= instance.values;
                VM.callValue(state, instance.definition.effect, args);
                if (key.length)
                    edit().actionHistory[key] = true;
            });
            count++;
        }
    }

    private void processDue(ref size_t count) {
        while (true) {
            ScheduledEvent[] due;
            foreach (event; data.scheduled)
                if (event.due <= data.turn)
                    due ~= event;
            if (!due.length)
                return;
            if (count >= eventLimit)
                throw new LuaException("EVENT_LIMIT: scheduled event phase exhausted");
            due.sort!((left, right) => left.due < right.due || (left.due == right.due && left.sequence < right.sequence));
            auto event = due[0];
            runEffect({
                auto tentative = edit();
                ScheduledEvent[] remaining;
                foreach (queued; tentative.scheduled)
                    if (queued.sequence != event.sequence)
                        remaining ~= queued;
                tentative.scheduled = remaining;
                auto arguments = event.arguments.match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
                emit(event.kind, arguments.values);
                auto handler = registry.handler(event.kind);
                if (isFunction(handler))
                    VM.callValue(state, handler, [
                    wrapWorld(world), state.getSymbol(event.kind), event.arguments
                ]);
            });
            count++;
        }
    }
}

ChoiceToken unwrapChoiceToken(LuaValue value) {
    return value.match!((LuaUserData u) => cast(ChoiceToken) u.payload, _ => null);
}

Session unwrapSession(LuaValue value) {
    auto session = value.match!((LuaUserData u) => cast(Session) u.payload, _ => null);
    if (session is null)
        throw new LuaException("expected narrative session");
    return session;
}

LuaValue wrapSession(Session session) {
    auto methods = new LuaTable();
    void method(string name, LuaNativeFunction.NativeDelegate callback) {
        auto function_ = new LuaNativeFunction(callback, "session:" ~ name);
        function_.analysisSafeToCopy = true;
        methods.rawset(LuaValue(name), LuaValue(function_));
    }

    method("record_input", (void* p, LuaValue[] a) {
        if (a.length != 3 || !isSymbol(a[1]))
            throw new LuaException("record_input requires a name symbol and portable value");
        auto session = unwrapSession(a[0]);
        session.requireIdle();
        encodeValue(a[2], "external input");
        session.data.replayInputs ~= immutableRecord([
            "kind": session.state.getSymbol("external"),
            "value": immutableSequence([a[1], a[2]])
        ]);
        return cast(LuaValue[])[];
    });
    method("replay_log", (void* p, LuaValue[] a) {
        import varis.narrative.persistence : narrativeRuntimeVersion, schemaFingerprint;

        if (a.length != 1)
            throw new LuaException("replay_log requires a session");
        auto session = unwrapSession(a[0]);
        session.requireIdle();
        return [
            immutableRecord([
                "runtime": LuaValue(narrativeRuntimeVersion),
                "content": LuaValue(session.registry.contentVersion),
                "program": LuaValue(session.world.narrativeProgramVersion),
                "schema": LuaValue(schemaFingerprint(session.world)),
                "inputs": immutableSequence(session.data.replayInputs)
            ])
        ];
    });
    method("save", (void* p, LuaValue[] a) {
        import varis.narrative.persistence : saveSession;

        if (a.length != 1)
            throw new LuaException("save requires a session");
        return [LuaValue(saveSession(unwrapSession(a[0])))];
    });
    method("world", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("world requires a session");
        return [wrapWorld(unwrapSession(a[0]).world)];
    });
    method("turn", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("turn requires a session");
        return [LuaValue(cast(long) unwrapSession(a[0]).view().turn)];
    });
    method("active_deck", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("active_deck requires a session");
        return [LuaValue(Symbol(unwrapSession(a[0]).activeDeck()))];
    });
    method("seed", (void* p, LuaValue[] a) {
        if (a.length != 2 || !isInteger(a[1]))
            throw new LuaException("session seed must be an integer");
        unwrapSession(a[0]).seed(a[1].match!((long n) => n, _ => 0L));
        return cast(LuaValue[])[];
    });
    method("limits", (void* p, LuaValue[] a) {
        if (a.length != 3 || !isInteger(a[1]) || !isInteger(a[2]))
            throw new LuaException("session limits require two positive integers");
        long actions = a[1].match!((long n) => n, _ => 0L), events = a[2].match!((long n) => n, _ => 0L);
        if (actions <= 0 || events <= 0)
            throw new LuaException("session limits must be positive");
        unwrapSession(a[0]).setLimits(cast(size_t) actions, cast(size_t) events);
        return cast(LuaValue[])[];
    });
    method("set_period", (void* p, LuaValue[] a) {
        if (a.length != 3 || !isSymbol(a[1]))
            throw new LuaException("period requires a symbol and a serializable value");
        unwrapSession(a[0]).setPeriod(a[1].match!((Symbol s) => s.name, _ => ""), a[2]);
        return cast(LuaValue[])[];
    });
    method("present", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("present requires a session");
        return [unwrapSession(a[0]).present()];
    });
    method("choose", (void* p, LuaValue[] a) {
        if (a.length != 2)
            throw new LuaException("STALE_CHOICE: expected exact choice token");
        unwrapSession(a[0]).choose(unwrapChoiceToken(a[1]));
        return cast(LuaValue[])[];
    });
    auto metatable = new LuaTable();
    metatable.rawset(LuaValue("__index"), LuaValue(methods));
    metatable.rawset(LuaValue("__metatable"), LuaValue("narrative session"));
    return LuaValue(new LuaUserData(session, metatable));
}

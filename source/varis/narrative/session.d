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
import varis.narrative.translation;
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

/// Collects garbage between turns once the heap has grown well past what survived the last
/// collection. The interpreter runs the collector with a large growth factor (good for scripts
/// that allocate heavily); a session produces little garbage per turn, so without this the heap
/// drifts up to that factor before anything is reclaimed. Collecting here keeps the pause out of
/// the middle of a turn (benchmarks/PERFORMANCE_PLAN.md, stage M).
private void collectAtTurnBoundary() {
    import core.memory : GC;

    static size_t liveAfterCollection;
    auto used = GC.stats().usedSize;
    if (liveAfterCollection == 0 || used > liveAfterCollection + liveAfterCollection / 2 + (4 << 20)) {
        GC.collect();
        liveAfterCollection = GC.stats().usedSize;
    }
}

/// A ground positive goal of a definition's availability query: if that fact is absent the
/// query has no result, so the definition has no instance.
private final class RequiredFact {
    string relation;
    LuaValue[] values;
    /// Set after the full query has completed once without error. Skipping is then exact: with
    /// the fact absent the positive join is empty, so no comparison, guard or negation would run
    /// and nothing could be raised (relations are never removed and arities never change).
    bool verified;
}

/// Finds the required fact of a definition whose availability closure does nothing but load
/// constants and build one query on the world it is given (what `when { ... }` compiles to).
/// Anything else (upvalues, parameters, calls, guards, aggregates, several queries) returns null.
private RequiredFact requiredFact(LuaState state, ContentDefinition definition) {
    import varis.opcode : OpCode;
    import varis.relterms : GoalKind, TermKind;

    if (definition.availabilityFilterBuilt)
        return cast(RequiredFact) definition.availabilityFilter;
    definition.availabilityFilterBuilt = true;
    if (definition.incomingParameters.length || !isFunction(definition.availability))
        return null;
    auto closure = cast(LuaClosure) definition.availability.asFunction;
    if (closure is null)
        return null;
    auto proto = closure.proto;
    if (proto.upvalues.length || proto.numParams != 1 || proto.isVararg || proto.queryTemplates.length != 1)
        return null;
    // Abstract run of the constant-loading prefix.
    auto known = new bool[proto.maxStackSize + 1];
    auto values = new LuaValue[proto.maxStackSize + 1];
    size_t pc;
    for (; pc < proto.code.length; ++pc) {
        auto instr = proto.code[pc];
        if (instr.op == OpCode.MakeQuery)
            break;
        if (instr.a < 0 || instr.a >= values.length)
            return null;
        if (instr.op == OpCode.LoadInt)
            values[instr.a] = LuaValue(cast(long) instr.sBx);
        else if (instr.op == OpCode.LoadSymbol && instr.b >= 0 && instr.b < proto.constants.length && isString(
                proto.constants[instr.b]))
            values[instr.a] = state.getSymbol(proto.constants[instr.b].asString);
        else if (instr.op == OpCode.LoadK && instr.b >= 0 && instr.b < proto.constants.length && (
                isString(
                proto.constants[instr.b]) || proto.constants[instr.b].isInteger))
            values[instr.a] = proto.constants[instr.b];
        else
            return null;
        known[instr.a] = true;
    }
    if (pc + 1 >= proto.code.length || proto.code[pc].b != 0 || proto.code[pc + 1].op != OpCode.Return)
        return null;
    foreach (rest; proto.code[pc + 1 .. $])
        if (rest.op != OpCode.Return)
            return null;
    auto goals = proto.queryTemplates[0].goals;
    foreach (goal; goals)
        if (goal.kind == GoalKind.Guard || goal.kind == GoalKind.Aggregate)
            return null;
    foreach (goal; goals) {
        if (goal.kind != GoalKind.PositiveAtom || goal.worldReg != 0 || goal.localRelReg >= 0 || goal.localRelUpval >= 0)
            continue;
        LuaValue[] fact;
        foreach (term; goal.terms) {
            if (term.kind != TermKind.Constant || term.reg < 0 || term.reg >= known.length || !known[term.reg])
                break;
            fact ~= values[term.reg];
        }
        if (fact.length != goal.terms.length || fact.length == 0)
            continue;
        auto filter = new RequiredFact;
        filter.relation = goal.relName;
        filter.values = fact;
        definition.availabilityFilter = filter;
        return filter;
    }
    return null;
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
/// One rendered message of a presentation, with what is needed to render it in another language.
final class MessageRender {
    string key; // `lamp.title`, `lamp.light.title`
    string source; // the text rendered from the authored template
    LuaValue[string] bindings;
    RenderTrace trace;
}

final class ChoiceRender {
    LuaValue[string] fields; // everything except `title` and `text`
    MessageRender title;
    MessageRender text;
}

final class StoryRender {
    LuaValue[string] fields;
    MessageRender title;
    MessageRender text;
    ChoiceRender[] choices;
}

/// Kept with a presentation: selection is finished, only rendering is left.
final class PresentationRender {
    LuaValue turn;
    LuaValue deck;
    StoryRender[] stories;
}

/// The payload of a presentation record: its fields, as for any immutable record, and the data
/// to render it again in another language.
final class PresentationRecord : ImmutableRecord {
    PresentationRender render;

    this(LuaValue[string] fields, PresentationRender render) {
        super(fields);
        this.render = render;
    }
}

class Session : TransactionParticipant {
    LuaState state;
    World world;
    ContentRegistry registry;
    SessionData data;
    bool busy;
    size_t actionLimit = 1000;
    size_t eventLimit = 1000;
    /// The language presentations are rendered in; empty is the source language. A host
    /// preference: not saved, never an input to eligibility, draws or replay.
    string language;
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
            configureWorld(state)(world);
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
        // Stage W5: skip the query entirely when a fact it requires is absent.
        auto filter = inputs is null ? requiredFact(state, definition) : null;
        if (filter !is null && filter.verified && state.analysisBudget is null && !vmSlowMode) {
            auto relation = snapshot.getRelation(filter.relation);
            if (relation !is null && relation.rules.length == 0 && relation.arity == filter.values.length
                    && !visibleRelation(relation).factTable().contains(filter.values))
                return null;
        }
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
            if (filter !is null)
                filter.verified = true; // the unfiltered query ran to completion once
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

    /// Renders the finished selection of a presentation in a language: a pure function of what
    /// `present` captured. It draws no random number, issues no token, and writes nothing. A
    /// message with no translation, or whose translation asks for more than the source offered,
    /// is rendered in the source language as a whole.
    private LuaValue buildPresentation(PresentationRender data, string language) {
        string text(MessageRender message) {
            if (language.length) {
                if (auto translated = registry.translation(language, message.key)) {
                    string output;
                    if (renderTranslation(translated, message.bindings, (LuaValue v) => registry.displayIn(language, v),
                            message.trace, language, output))
                        return output;
                }
            }
            return message.source;
        }

        LuaValue[] stories;
        foreach (story; data.stories) {
            LuaValue[] choices;
            foreach (choice; story.choices) {
                auto fields = choice.fields.dup;
                fields["title"] = LuaValue(text(choice.title));
                fields["text"] = LuaValue(text(choice.text));
                choices ~= immutableRecord(fields);
            }
            auto fields = story.fields.dup;
            fields["title"] = LuaValue(text(story.title));
            fields["text"] = LuaValue(text(story.text));
            fields["choices"] = immutableSequence(choices);
            stories ~= immutableRecord(fields);
        }
        LuaValue[string] fields = [
            "turn": data.turn,
            "deck": data.deck,
            "storylets": immutableSequence(stories)
        ];
        // An ordinary immutable record that also remembers how to be rendered again.
        return wrapImmutable(new PresentationRecord(fields, data));
    }

    /// `render(presentation, language)`: the same presentation, with titles and texts in `language`
    /// (empty: the source language). The tokens are the same ones.
    LuaValue render(LuaValue presentation, string target) {
        PresentationRecord record;
        if (presentation.typeOf() == LuaType.UserData)
            record = cast(PresentationRecord) presentation.asUserData.payload;
        if (record is null)
            throw new LuaException("render requires a presentation returned by present");
        return buildPresentation(record.render, target);
    }

    LuaValue present() {
        requireIdle();
        busy = true;
        scope (exit)
            busy = false;
        // Not during bounded analysis: it presents hundreds of cloned sessions in a row.
        if (state.analysisBudget is null)
            collectAtTurnBoundary();
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
        StoryRender[] storyRenders;
        LuaValue[] variantLog;
        // The replay log names what was drawn: the option's index, and its name when it has one,
        // so that reordering alternatives never makes an old log mean something else.
        void logVariants(string key, string field, size_t[] vars, NarrativeTemplate template_) {
            if (!vars.length)
                return;
            LuaValue[] indices;
            LuaValue[] names;
            bool named;
            foreach (i, idx; vars) {
                indices ~= LuaValue(cast(long) idx);
                string optionName;
                if (template_ !is null && i < template_.variantGroups.length && idx < template_
                        .variantGroups[i].options.length)
                    optionName = template_.variantGroups[i].options[idx].name;
                named = named || optionName.length > 0;
                names ~= LuaValue(optionName);
            }
            LuaValue[string] record = [
                "key": LuaValue(key),
                "field": LuaValue(field),
                "indices": immutableSequence(indices)
            ];
            if (named)
                record["names"] = immutableSequence(names);
            variantLog ~= immutableRecord(record);
        }

        MessageRender message(string key, NarrativeTemplate template_, LuaValue[string] bindings, size_t[] vars) {
            auto rendered = new MessageRender();
            rendered.key = key;
            rendered.bindings = bindings;
            rendered.source = template_.render(state, snapshot, bindings, &registry.display, vars, &rendered.trace,
                    registry.sourceLanguage);
            return rendered;
        }

        foreach (story; selected) {
            auto storyTitleVars = selectVariants(story.definition.titleTemplate, tentative);
            auto storyTextVars = selectVariants(story.definition.textTemplate, tentative);
            logVariants(story.key, "title", storyTitleVars, story.definition.titleTemplate);
            logVariants(story.key, "text", storyTextVars, story.definition.textTemplate);
            auto storyRender = new StoryRender();
            auto storyId = story.definition.id;
            storyRender.title = message(storyId ~ ".title", story.definition.titleTemplate, story.bindings, storyTitleVars);
            storyRender.text = message(storyId ~ ".text", story.definition.textTemplate, story.bindings, storyTextVars);
            foreach (definition; story.definition.choices)
                foreach (choice; instances(definition, snapshot, story.bindings)) {
                    auto choiceTitleVars = selectVariants(definition.titleTemplate, tentative);
                    auto choiceTextVars = selectVariants(definition.textTemplate, tentative);
                    logVariants(choice.key, "title", choiceTitleVars, definition.titleTemplate);
                    logVariants(choice.key, "text", choiceTextVars, definition.textTemplate);
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
                    auto choiceRender = new ChoiceRender();
                    choiceRender.fields = [
                        "id": state.getSymbol(definition.id),
                        "instance_key": LuaValue(choice.key),
                        "bindings": immutableRecord(choice.bindings),
                        "token": LuaValue(new LuaUserData(token, tokenMetatable))
                    ];
                    auto choiceKey = storyId ~ "." ~ definition.id;
                    choiceRender.title = message(choiceKey ~ ".title", definition.titleTemplate, choice.bindings, choiceTitleVars);
                    choiceRender.text = message(choiceKey ~ ".text", definition.textTemplate, choice.bindings, choiceTextVars);
                    storyRender.choices ~= choiceRender;
                }
            storyRender.fields = [
                "id": state.getSymbol(story.definition.id),
                "instance_key": LuaValue(story.key),
                "bindings": immutableRecord(story.bindings),
                "world_version": LuaValue(cast(long) story.worldVersion)
            ];
            storyRenders ~= storyRender;
        }
        auto renderData = new PresentationRender();
        renderData.turn = LuaValue(cast(long) tentative.turn);
        renderData.deck = state.getSymbol(tentative.decks[$ - 1].name);
        renderData.stories = storyRenders;
        auto presentation = buildPresentation(renderData, language);
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
    // Language is a view (localization plan §2): these change what is shown, nothing else.
    method("set_language", (void* p, LuaValue[] a) {
        if (a.length != 2 || !(isString(a[1]) || isNil(a[1])))
            throw new LuaException("set_language requires a session and a language tag (or nil)");
        unwrapSession(a[0]).language = isNil(a[1]) ? "" : a[1].match!((string s) => s, _ => "");
        return cast(LuaValue[])[];
    });
    method("language", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("language requires a session");
        auto tag = unwrapSession(a[0]).language;
        return [tag.length ? LuaValue(tag) : luaNil()];
    });
    method("render", (void* p, LuaValue[] a) {
        if (a.length < 2 || a.length > 3 || !(a.length == 2 || isString(a[2]) || isNil(a[2])))
            throw new LuaException("render requires a session, a presentation and optionally a language tag");
        string tag = a.length == 3 && isString(a[2]) ? a[2].match!((string s) => s, _ => "") : "";
        return [unwrapSession(a[0]).render(a[1], tag)];
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

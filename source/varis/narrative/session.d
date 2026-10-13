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
import varis.narrative.scenes;
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
private bool collectIfGrown(size_t slack) {
    import core.memory : GC;

    static size_t liveAfterCollection;
    auto used = GC.stats().usedSize;
    if (liveAfterCollection == 0 || used > liveAfterCollection + liveAfterCollection / 2 + slack) {
        GC.collect();
        liveAfterCollection = GC.stats().usedSize;
        return true;
    }
    return false;
}

private void collectAtTurnBoundary() {
    collectIfGrown(4 << 20);
}

/// Calls `callback` with the session's world as the default world: unqualified relation names,
/// `fact`/`set`/`adjust`, queries and `quality.*` in a session handler or a deferred callback mean
/// the world the event came from, not the process-wide global one. The real global world stays
/// reachable as `logic.global`. Restored on every exit.
LuaValue[] callInSessionWorld(LuaState state, World world, LuaValue callback, LuaValue[] arguments) {
    auto previous = state.globalWorldObject;
    state.globalWorldObject = world;
    scope (exit)
        state.globalWorldObject = previous;
    return VM.callValue(state, callback, arguments);
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
    SceneState scene;
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
    /// The ending recorded by `narrative.finish`; empty while the session is playable.
    string ending;
    /// Events with a sequence number above this were delivered by an earlier presentation.
    ulong eventCursor;

    SessionData copy() {
        auto result = new SessionData();
        result.scene = scene is null ? null : scene.copy();
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
        result.ending = ending;
        result.eventCursor = eventCursor;
        return result;
    }
}

/// One undo point: the session data (with the live scene object, which is replaced and never
/// mutated, so beat tokens issued for it stay valid), the world's facts and the presentation.
private final class UndoEntry {
    SessionData data;
    FactSnapshot facts;
    LuaValue presentation;
}

class ContentInstance {
    ContentDefinition definition;
    LuaValue[string] bindings;
    LuaValue[] values;
    /// Values of the definition's `expose ?name` variables, in declaration order. Visible to
    /// templates and effects; not part of `key`, cooldowns or history.
    LuaValue[] exposedValues;
    string exposure; // canonical form of exposedValues, to notice a change at choosing time
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
    LuaValue id;
    LuaValue instanceKey;
    LuaValue bindings; // immutable record
    LuaValue exposed; // immutable record of `expose` values, or nil
    LuaValue token;
    MessageRender title;
    MessageRender text;
    /// Set when the choice has a `require`: `enabled` says whether it holds, and `because` is
    /// the reason shown for a disabled choice. A disabled choice has no token.
    bool hasRequirement;
    bool enabled = true;
    MessageRender because;
}

final class StoryRender {
    LuaValue id;
    LuaValue instanceKey;
    LuaValue bindings;
    LuaValue exposed; // immutable record of `expose` values, or nil
    LuaValue worldVersion;
    MessageRender title;
    MessageRender text;
    ChoiceRender[] choices;
}

/// Kept with a presentation: selection is finished, only rendering is left.
final class PresentationRender {
    LuaValue turn;
    LuaValue deck;
    StoryRender[] stories;
    LuaValue stage;
    LuaValue events; // immutable sequence of the events this presentation delivered
    LuaValue ending; // the ending symbol of a terminal presentation, else nil
}

/// The payload of a presentation record: its fields, as for any immutable record, and the data
/// to render it again in another language.
final class ScenePresentationRecord : ImmutableRecord {
    SceneState snapshot;
    LuaValue token;
    ulong turn;
    MessageRender message;
    LuaValue delivered;
    this(LuaValue[string] fields, SceneState snapshot, LuaValue token, ulong turn, MessageRender message,
            LuaValue delivered = LuaValue.init) {
        super(fields);
        this.delivered = delivered;
        this.snapshot = snapshot;
        this.token = token;
        this.turn = turn;
        this.message = message;
    }
}

final class PresentationRecord : ImmutableRecord {
    PresentationRender render;

    this(LuaValue[string] fields, PresentationRender render) {
        super(fields);
        this.render = render;
    }
}

private class SceneToken {
    Session session;
    SceneState scene;
    this(Session session, SceneState scene) {
        this.session = session;
        this.scene = scene;
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
    /// Bounded ring of states taken just before each choice or beat advance (`undo`). Not saved:
    /// a loaded session starts with an empty ring.
    private UndoEntry[] undoRing;
    private size_t undoLimit_;
    /// The value the last `present` returned; `undo` hands back the one that was current when
    /// the undone command ran, so its tokens are valid again.
    private LuaValue lastPresentation;
    private LuaValue autosaveHook;

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

    void playScene(string id) {
        if (currentEffectSession() is this)
            requireEffectSession();
        else
            requireIdle();
        if (registry.scene(id) is null)
            throw new LuaException("unknown scene '" ~ id ~ "'");
        if (inProcedure)
            throw new LuaException("a scene procedure cannot start a scene");
        auto next = new SceneState;
        auto previous = view().scene;
        next.stage = previous is null ? immutableRecord(null) : previous.stage;
        next.revision = previous is null ? 1 : previous.revision + 1;
        next.frames = [SceneFrame(id, 0, immutableRecord(null))];
        bool outside = currentEffectSession() is null;
        void seek() {
            auto problem = seekBeat(registry, next, &runSceneProcedure);
            if (problem.length)
                throw new LuaException(problem);
            edit().scene = next;
            if (outside)
                edit().replayInputs ~= immutableRecord([
                "kind": state.getSymbol("play"),
                "value": state.getSymbol(id)
            ]);
        }

        // Effect beats write to the world: outside an effect the whole seek is one transaction.
        if (outside && registry.procedures().length)
            runEffect(&seek);
        else
            seek();
    }

    private bool inProcedure;

    /// Runs the named procedure of a scene `effect` beat inside the surrounding transaction.
    private string runSceneProcedure(string id, LuaValue[string] arguments) {
        auto definition = registry.procedure(id);
        if (definition is null)
            return "unknown procedure '" ~ id ~ "'";
        LuaValue[] args = [wrapWorld(world)];
        foreach (name; definition.parameters)
            args ~= arguments.get(name, luaNil());
        inProcedure = true;
        scope (exit)
            inProcedure = false;
        VM.callValue(state, definition.effect, args);
        return "";
    }

    LuaValue scenePresentation() {
        auto delivered = eventsAfter(data.eventCursor);
        data.eventCursor = data.events.length;
        return buildScenePresentation(data.scene, language, LuaValue(new LuaUserData(new SceneToken(this, data.scene))), data
                .turn, null, delivered);
    }

    /// The committed events with a sequence number above `after`, as an immutable sequence of
    /// `{sequence, turn, kind, args}` records.
    LuaValue eventsAfter(ulong after) {
        LuaValue[] items;
        auto committed = view().events;
        foreach (event; committed)
            if (event.sequence > after)
                items ~= immutableRecord([
                "sequence": LuaValue(cast(long) event.sequence),
                "turn": LuaValue(cast(long) event.turn),
                "kind": state.getSymbol(event.kind),
                "args": event.arguments
        ]);
        return immutableSequence(items);
    }

    /// Record the ending of the session (`narrative.finish`). Repeating it is harmless; a second,
    /// different ending in the same session is an error.
    void finish(string ending) {
        auto value = edit();
        if (value.ending.length && value.ending != ending)
            throw new LuaException("session already finished with ending '" ~ value.ending ~ "'");
        value.ending = ending;
    }

    /// The ending symbol, or nil while the session is playable.
    LuaValue endedWith() {
        auto name = view().ending;
        return name.length ? state.getSymbol(name) : LuaValue.init;
    }

    private LuaValue terminalPresentation() {
        auto renderData = new PresentationRender();
        renderData.turn = LuaValue(cast(long) data.turn);
        renderData.deck = state.getSymbol(data.decks[$ - 1].name);
        renderData.events = eventsAfter(data.eventCursor);
        renderData.ending = state.getSymbol(data.ending);
        if (data.scene !is null)
            renderData.stage = data.scene.stage;
        data.eventCursor = data.events.length;
        return buildPresentation(renderData, language);
    }

    private LuaValue buildScenePresentation(SceneState scene, string target, LuaValue token, ulong turn,
            MessageRender message = null, LuaValue delivered = LuaValue.init) {
        auto frame = scene.frames[$ - 1];
        auto beat = scene.beat;
        auto text = field(beat, "text");
        if (text.isString) {
            // Locals are portable scalar bindings; templates use the existing narrative grammar.
            auto locals = cast(ImmutableRecord) frame.locals.asUserData.payload;
            string[] names;
            foreach (name; locals.fields.keys)
                names ~= name;
            auto template_ = new NarrativeTemplate(text.asString, names);
            if (message is null) {
                message = new MessageRender;
                message.bindings = locals.fields;
                message.source = template_.render(state, world.cloneSnapshot(), locals.fields, &registry.display, null, &message
                        .trace, registry.sourceLanguage);
                message.key = "scene." ~ nameOf(field(beat, "id")) ~ ".text";
            }
            auto text_ = message.source;
            if (target.length)
                if (auto translated = registry.translation(target, message.key)) {
                    string output;
                    if (renderTranslation(translated, message.bindings, (LuaValue v) => registry.displayIn(target, v), message
                            .trace, target, output))
                        text_ = output;
                }
            beat = replaceField(beat, "text", LuaValue(text_));
        }
        if (nameOf(field(beat, "kind")) == "menu") {
            // Option labels are translatable text: key `scene.<label id>.label`, where the label
            // id is the choice's `label_id` or `<scene>.<choice id>`. A label that cannot be
            // rendered in the target language stays in the source language.
            auto locals = cast(ImmutableRecord) frame.locals.asUserData.payload;
            string[] names;
            foreach (name; locals.fields.keys)
                names ~= name;
            LuaValue[] labelled;
            foreach (choice; sequence(field(beat, "choices"))) {
                auto key = "scene." ~ sceneLabelId(frame.id, choice) ~ ".label";
                if (target.length)
                    if (auto translated = registry.translation(target, key)) {
                        RenderTrace trace;
                        string output;
                        auto template_ = new NarrativeTemplate(field(choice, "text").asString, names);
                        template_.render(state, world.cloneSnapshot(), locals.fields, &registry.display, null, &trace,
                                registry.sourceLanguage);
                        if (renderTranslation(translated, locals.fields, (LuaValue v) => registry.displayIn(target, v),
                                trace, target, output))
                            choice = replaceField(choice, "text", LuaValue(output));
                    }
                labelled ~= choice;
            }
            beat = replaceField(beat, "choices", immutableSequence(labelled));
        }
        auto character = registry.character(nameOf(field(beat, "character")));
        if (character !is null)
            beat = replaceField(beat, "speaker", character.fields);
        LuaValue[string] fields = [
            "turn": LuaValue(cast(long) turn), "scene": state.getSymbol(frame.id),
            "beat_index": LuaValue(cast(long) frame.pc + 1), "locals": frame.locals,
            "beats": immutableSequence([beat]), "stage": scene.stage,
            "token": token,
            "storylets": immutableSequence(null),
            "events": delivered.isNil ? immutableSequence(null) : delivered
        ];
        return wrapImmutable(new ScenePresentationRecord(fields, scene, token, turn, message, delivered));
    }

    void advanceScene(LuaValue token, LuaValue input) {
        advanceCommitted(token, input);
        runAutosave();
    }

    private void advanceCommitted(LuaValue token, LuaValue input) {
        requireIdle();
        if (data.ending.length)
            throw new LuaException("SESSION_ENDED: the session finished with ending '" ~ data.ending ~ "'");
        SceneToken identity;
        if ((token.typeOf() == LuaType.UserData))
            identity = cast(SceneToken) token.asUserData.payload;
        if (identity is null || identity.session !is this || identity.scene !is data.scene || !data.scene.frames.length)
            throw new LuaException("STALE_BEAT: expected exact scene token");
        auto next = data.scene.copy();
        auto beat = next.beat;
        auto kind = nameOf(field(beat, "kind"));
        auto frame = &next.frames[$ - 1];
        if (kind == "input") {
            auto value = input.isNil ? field(beat, "default") : input;
            canonicalScalar(value);
            auto problem = checkInputValue(beat, value);
            if (problem.length)
                throw new LuaException("invalid scene input: " ~ problem);
            frame.locals = replaceField(frame.locals, nameOf(field(beat, "local")), value, false);
        } else if (kind == "menu") {
            string target;
            foreach (choice; sequence(field(beat, "choices")))
                if (luaRawEqual(field(choice, "id"), input))
                    target = nameOf(field(choice, "target"));
            if (!target.length)
                throw new LuaException("invalid scene menu choice");
            frame.id = target;
            frame.pc = 0;
        } else if (!input.isNil)
            throw new LuaException("this scene beat accepts no input");
        if (kind != "menu")
            frame.pc++;
        if (kind == "ended")
            next.frames.length = 0;
        next.revision++;
        void seek() {
            auto problem = seekBeat(registry, next, &runSceneProcedure);
            if (problem.length)
                throw new LuaException(problem);
            edit().scene = next;
            edit().replayInputs ~= immutableRecord([
                "kind": state.getSymbol("advance"),
                "value": input
            ]);
        }

        bool captured = captureUndo();
        try {
            if (registry.procedures().length)
                runEffect(&seek);
            else
                seek();
        } catch (Throwable error) {
            if (captured)
                discardUndo();
            throw error;
        }
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
        ContentInstance[string] byKey;
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
            foreach (name; definition.exposed) {
                if (name !in row)
                    throw new LuaException("availability did not ground exposed variable '?" ~ name ~ "'");
                auto value = row[name];
                canonicalScalar(value);
                instance.bindings[name] = value;
                instance.exposedValues ~= value;
            }
            instance.exposure = canonicalBindings(instance.exposedValues);
            instance.key = canonicalScalar(state.getSymbol(definition.id)) ~ ":" ~ canonicalBindings(instance.values);
            instance.worldVersion = world.version_;
            if (instance.key !in seen) {
                seen[instance.key] = true;
                byKey[instance.key] = instance;
                result ~= instance;
            } else if (definition.exposed.length && byKey[instance.key].exposure != instance.exposure) {
                // One instance, several different exposed values: nothing says which to show.
                string names;
                foreach (i, name; definition.exposed)
                    names ~= (i ? ", ?" : "?") ~ name;
                throw new LuaException("AMBIGUOUS_EXPOSE: " ~ definition.kind ~ " '" ~ definition.id
                        ~ "' exposes " ~ names ~ " but its query matches more than one value for one instance ("
                        ~ definition.id ~ "); constrain the query or make it a parameter");
            }
        }
        result.sort!((left, right) => left.key < right.key);
        return result;
    }

    /// An instance's bindings as a presentation shows them: its parameters (and a choice's
    /// storylet's), never the `expose` values, which are not identity.
    private LuaValue presentedBindings(ContentInstance instance) {
        LuaValue[string] visible;
        foreach (name, value; instance.bindings) {
            bool hidden;
            foreach (candidate; instance.definition.exposed ~ instance.definition.incomingExposed)
                hidden = hidden || candidate == name;
            if (!hidden)
                visible[name] = value;
        }
        return immutableRecord(visible);
    }

    private LuaValue exposedRecord(ContentInstance instance) {
        if (!instance.definition.exposed.length)
            return LuaValue.init;
        LuaValue[string] fields;
        foreach (i, name; instance.definition.exposed)
            fields[name] = instance.exposedValues[i];
        return immutableRecord(fields);
    }

    /// Whether a choice's `require` query has a result for these bindings (true when it has none).
    bool requirementHolds(ContentDefinition definition, World snapshot, LuaValue[string] bindings) {
        if (!isFunction(definition.requirement))
            return true;
        beginReadOnlyEvaluation();
        scope (exit)
            endReadOnlyEvaluation();
        LuaValue[] args = [wrapWorld(snapshot)];
        foreach (name; definition.incomingParameters ~ definition.parameters ~ definition.exposed)
            args ~= bindings.get(name, luaNil());
        auto returned = VM.callValue(state, definition.requirement, args);
        if (!returned.length)
            throw new LuaException("requirement callback did not return an iterator");
        auto next = VM.callValue(state, returned[0], []);
        return next.length && !isNil(next[0]);
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
            if (instance.key == selected.key && instance.exposure == selected.exposure)
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
        stories.reserve(data.stories.length);
        foreach (story; data.stories) {
            LuaValue[] choices;
            choices.reserve(story.choices.length);
            foreach (choice; story.choices) {
                LuaValue[string] record = [
                    "id": choice.id,
                    "instance_key": choice.instanceKey,
                    "bindings": choice.bindings,
                    "title": LuaValue(text(choice.title)),
                    "text": LuaValue(text(choice.text)),
                    "token": choice.token
                ];
                if (!choice.exposed.isNil)
                    record["exposed"] = choice.exposed;
                if (choice.hasRequirement) {
                    record["enabled"] = LuaValue(choice.enabled);
                    record["because"] = LuaValue(choice.enabled ? "" : text(choice.because));
                }
                if (auto meta = (nameOf(story.id) ~ "." ~ nameOf(choice.id)) in registry.metadata)
                    record["meta"] = *meta;
                choices ~= immutableRecord(record);
            }
            LuaValue[string] storyRecord = [
                "id": story.id,
                "instance_key": story.instanceKey,
                "bindings": story.bindings,
                "title": LuaValue(text(story.title)),
                "text": LuaValue(text(story.text)),
                "world_version": story.worldVersion,
                "choices": immutableSequence(choices)
            ];
            if (!story.exposed.isNil)
                storyRecord["exposed"] = story.exposed;
            if (auto meta = nameOf(story.id) in registry.metadata)
                storyRecord["meta"] = *meta;
            // Passage links in the rendered text, resolved to the choice they name (position
            // order). A link to a choice that is not enabled carries no token.
            {
                import varis.narrative.text : markupSpans;

                LuaValue[] links;
                foreach (span; markupSpans(text(story.text))) {
                    if (!span.link.length)
                        continue;
                    LuaValue token;
                    bool enabled;
                    bool known;
                    foreach (choice; story.choices)
                        if (nameOf(choice.id) == span.link && !known) {
                            known = true;
                            enabled = !choice.token.isNil;
                            token = choice.token;
                        }
                    if (!known)
                        continue;
                    links ~= immutableRecord([
                        "text": LuaValue(span.text),
                        "choice": state.getSymbol(span.link),
                        "token": token,
                        "enabled": LuaValue(enabled)
                    ]);
                }
                if (links.length)
                    storyRecord["links"] = immutableSequence(links);
            }
            stories ~= immutableRecord(storyRecord);
        }
        LuaValue[string] fields = [
            "turn": data.turn,
            "deck": data.deck,
            "storylets": immutableSequence(stories),
            "events": data.events.isNil ? immutableSequence(null) : data.events
        ];
        if (!data.ending.isNil)
            fields["ending"] = data.ending;
        if (!data.stage.isNil)
            fields["stage"] = data.stage;
        // An ordinary immutable record that also remembers how to be rendered again.
        return wrapImmutable(new PresentationRecord(fields, data));
    }

    /// `render(presentation, language)`: the same presentation, with titles and texts in `language`
    /// (empty: the source language). The tokens are the same ones.
    LuaValue render(LuaValue presentation, string target) {
        if (presentation.typeOf() == LuaType.UserData) {
            auto scene = cast(ScenePresentationRecord) presentation.asUserData.payload;
            if (scene !is null)
                return buildScenePresentation(scene.snapshot, target, scene.token, scene.turn, scene.message,
                        scene.delivered);
        }
        PresentationRecord record;
        if (presentation.typeOf() == LuaType.UserData)
            record = cast(PresentationRecord) presentation.asUserData.payload;
        if (record is null)
            throw new LuaException("render requires a presentation returned by present");
        return buildPresentation(record.render, target);
    }

    LuaValue present() {
        auto result = presentCurrent();
        lastPresentation = result;
        return result;
    }

    /// How many times a choice of the storylet `id` has been committed (any bindings). Derived
    /// from the replay log, which is saved, so it survives save and load unchanged.
    size_t visitCount(string id) {
        auto prefix = canonicalScalar(state.getSymbol(id)) ~ ":";
        size_t count;
        foreach (record; view().replayInputs) {
            auto payload = record.match!((LuaUserData u) => cast(ImmutableRecord) u.payload, _ => null);
            if (payload is null)
                continue;
            auto kind = "kind" in payload.fields;
            auto value = "value" in payload.fields;
            if (kind is null || value is null || !isSymbol(*kind) || nameOf(*kind) != "choose")
                continue;
            auto pair = (*value).match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
            if (pair is null || !pair.values.length || !isString(pair.values[0]))
                continue;
            auto key = pair.values[0].asString;
            if (key.length >= prefix.length && key[0 .. prefix.length] == prefix)
                ++count;
        }
        return count;
    }

    /// The turn of the latest committed choice of the storylet `id`; false when never chosen.
    bool lastChosen(string id, out ulong turn) {
        auto prefix = canonicalScalar(state.getSymbol(id)) ~ ":";
        bool found;
        foreach (key, at; view().completed) {
            if (key.length >= prefix.length && key[0 .. prefix.length] == prefix && (!found || at > turn)) {
                turn = at;
                found = true;
            }
        }
        return found;
    }

    /// Maximum number of choices or beats `undo` can take back (0 turns undo off, the default).
    void setUndoLimit(size_t limit) {
        requireIdle();
        undoLimit_ = limit;
        if (undoRing.length > limit)
            undoRing = undoRing[$ - limit .. $];
    }

    /// The host's "idle now": the presentation has been handed over and nobody is waiting, so a
    /// collection pause here costs nothing visible. Collects when the heap has grown by 1 MiB over
    /// the live size (the turn-boundary rule uses 4 MiB), returns whether it did, and never
    /// runs inside an effect or during bounded analysis.
    bool idle() {
        if (busy || state.analysisBudget !is null)
            return false;
        return collectIfGrown(1 << 20);
    }

    size_t undoDepth() {
        return undoRing.length;
    }

    private bool captureUndo() {
        if (undoLimit_ == 0)
            return false;
        auto entry = new UndoEntry;
        entry.data = data.copy();
        entry.data.scene = data.scene;
        entry.facts = world.captureFacts();
        entry.presentation = lastPresentation;
        if (undoRing.length >= undoLimit_)
            undoRing = undoRing[1 .. $];
        undoRing ~= entry;
        return true;
    }

    private void discardUndo() {
        if (undoRing.length)
            undoRing.length--;
    }

    /// Takes back the last committed choice or beat advance: the world's facts, the turn, decks,
    /// the random state, periods, events, schedules and the scene position return to what they
    /// were when that command started, and the presentation shown then is returned (its tokens
    /// are usable again). Counters for tokens, decks and schedules keep running, and tokens issued
    /// after that point are voided. Effects outside the session (host tables, `narrative.defer`
    /// callbacks, files) are not taken back.
    LuaValue undo() {
        requireIdle();
        if (!undoRing.length)
            throw new LuaException("nothing to undo");
        auto entry = undoRing[$ - 1];
        undoRing.length--;
        auto restored = entry.data;
        foreach (identity; restored.nextToken .. data.nextToken)
            restored.consumedTokens[identity] = true;
        if (data.nextToken > restored.nextToken)
            restored.nextToken = data.nextToken;
        if (data.nextDeck > restored.nextDeck)
            restored.nextDeck = data.nextDeck;
        if (data.nextSchedule > restored.nextSchedule)
            restored.nextSchedule = data.nextSchedule;
        world.restoreFacts(entry.facts);
        data = restored;
        lastPresentation = entry.presentation;
        return entry.presentation;
    }

    private LuaValue presentCurrent() {
        requireIdle();
        busy = true;
        scope (exit)
            busy = false;
        // Not during bounded analysis: it presents hundreds of cloned sessions in a row.
        if (state.analysisBudget is null)
            collectAtTurnBoundary();
        size_t eventCount;
        runPhase("pre", eventCount);
        if (data.ending.length)
            return terminalPresentation();
        if (data.scene !is null && data.scene.frames.length)
            return scenePresentation();
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
                    bool enabled = requirementHolds(definition, snapshot, choice.bindings);
                    auto token = new ChoiceToken();
                    token.session = this;
                    token.storylet = story;
                    token.choice = choice;
                    if (enabled) {
                        if (tentative.nextToken == ulong.max)
                            throw new LuaException("choice token identity exhausted");
                        token.deckEntry = tentative.decks[$ - 1].identity;
                        token.identity = tentative.nextToken++;
                    }
                    auto tokenMetatable = new LuaTable();
                    tokenMetatable.rawset(LuaValue("__metatable"), LuaValue("choice token"));
                    tokenMetatable.rawset(LuaValue("__newindex"), LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
                                throw new LuaException("cannot modify immutable choice token");
                                return cast(LuaValue[])[];
                            })));
                    auto choiceRender = new ChoiceRender();
                    choiceRender.id = state.getSymbol(definition.id);
                    choiceRender.instanceKey = LuaValue(choice.key);
                    choiceRender.bindings = presentedBindings(choice);
                    choiceRender.exposed = exposedRecord(choice);
                    if (enabled)
                        choiceRender.token = LuaValue(new LuaUserData(token, tokenMetatable));
                    if (definition.becauseTemplate !is null) {
                        choiceRender.hasRequirement = true;
                        choiceRender.enabled = enabled;
                    }
                    auto choiceKey = storyId ~ "." ~ definition.id;
                    choiceRender.title = message(choiceKey ~ ".title", definition.titleTemplate, choice.bindings, choiceTitleVars);
                    choiceRender.text = message(choiceKey ~ ".text", definition.textTemplate, choice.bindings, choiceTextVars);
                    if (choiceRender.hasRequirement && !enabled) {
                        auto becauseVars = selectVariants(definition.becauseTemplate, tentative);
                        logVariants(choice.key, "because", becauseVars, definition.becauseTemplate);
                        choiceRender.because = message(choiceKey ~ ".because", definition.becauseTemplate,
                                choice.bindings, becauseVars);
                    }
                    storyRender.choices ~= choiceRender;
                }
            storyRender.id = state.getSymbol(story.definition.id);
            storyRender.instanceKey = LuaValue(story.key);
            storyRender.bindings = presentedBindings(story);
            storyRender.exposed = exposedRecord(story);
            storyRender.worldVersion = LuaValue(cast(long) story.worldVersion);
            storyRenders ~= storyRender;
        }
        auto renderData = new PresentationRender();
        renderData.turn = LuaValue(cast(long) tentative.turn);
        renderData.deck = state.getSymbol(tentative.decks[$ - 1].name);
        renderData.stories = storyRenders;
        if (tentative.scene !is null)
            renderData.stage = tentative.scene.stage;
        renderData.events = eventsAfter(tentative.eventCursor);
        tentative.eventCursor = tentative.events.length;
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
        chooseCommitted(token);
        runAutosave();
    }

    /// Called with the save text after every committed choice or beat advance, at an idle
    /// boundary, so a host never has to remember to autosave. nil removes the hook. A hook that
    /// raises propagates after the command has committed; it never undoes it.
    void setAutosave(LuaValue hook) {
        requireIdle();
        autosaveHook = hook;
    }

    private void runAutosave() {
        if (!isFunction(autosaveHook) || busy || currentTransaction() !is null)
            return;
        import varis.narrative.persistence : saveSession;

        VM.callValue(state, autosaveHook, [LuaValue(saveSession(this))]);
    }

    private void chooseCommitted(ChoiceToken token) {
        requireIdle();
        if (data.ending.length)
            throw new LuaException("SESSION_ENDED: the session finished with ending '" ~ data.ending ~ "'");
        if (data.scene !is null && data.scene.frames.length)
            throw new LuaException("STALE_CHOICE: a scene is active");
        busy = true;
        scope (exit)
            busy = false;
        if (token is null || token.session !is this || token.identity in data.consumedTokens)
            throw new LuaException("STALE_CHOICE: invalid or consumed token");
        if (data.turn >= long.max)
            throw new LuaException("narrative turn counter exhausted");
        bool captured = captureUndo();
        try {
            runEffect({
                auto tentative = view();
                if (token.deckEntry != tentative.decks[$ - 1].identity || !policyAllows(token.storylet, tentative) ||
                    !stillAvailable(token.storylet, world) || !stillAvailable(token.choice, world, token
                    .storylet.bindings))
                    throw new LuaException("STALE_CHOICE: eligibility or deck changed");
                if (!requirementHolds(token.choice.definition, world, token.choice.bindings))
                    throw new LuaException("STALE_CHOICE: requirement no longer holds");
                LuaValue[] args = [wrapWorld(world)];
                foreach (name; token.choice.definition.incomingParameters ~ token.choice.definition.parameters
                    ~ token.choice.definition.exposed)
                    args ~= token.choice.bindings[name];
                // `leads :deck` navigates after the authored effect, in the same transaction; an
                // effect that also moves between decks would navigate twice, so it is refused.
                string leads = token.choice.definition.symbolOption("leads", "");
                auto before = view();
                auto stackLength = before.decks.length;
                auto nextDeckBefore = before.nextDeck;
                VM.callValue(state, token.choice.definition.effect, args);
                if (leads.length) {
                    auto after = view();
                    if (after.decks.length != stackLength || after.nextDeck != nextDeckBefore)
                        throw new LuaException("choice '" ~ token.choice.definition.id
                            ~ "' has 'leads' and also navigates decks in its effect");
                    pushDeck(leads);
                }
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
        } catch (Throwable error) {
            if (captured)
                discardUndo();
            throw error;
        }
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
            // A finished session runs no further automatic actions or scheduled events.
            if (data.ending.length)
                return;
            processDue(eventCount);
            if (data.ending.length)
                return;
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
                args ~= instance.exposedValues;
                VM.callValue(state, instance.definition.effect, args);
                if (key.length)
                    edit().actionHistory[key] = true;
            });
            count++;
        }
    }

    private void processDue(ref size_t count) {
        while (true) {
            if (data.ending.length)
                return;
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
                    callInSessionWorld(state, world, handler, [
                    wrapWorld(world), state.getSymbol(event.kind), event.arguments
                ]);
            });
            count++;
        }
    }
}

/// `session:save` with its optional `{label = string, meta = portable value}` table.
string saveWithOptions(Session session, LuaValue options) {
    import varis.narrative.persistence : saveSession;

    string label;
    LuaValue meta;
    if (!isNil(options)) {
        auto table = options.match!((LuaTable t) => t, _ => null);
        if (table is null)
            throw new LuaException("save options must be a table with optional label and meta");
        LuaValue key, nextKey, value;
        while (table.next(key, nextKey, value)) {
            key = nextKey;
            auto name = key.match!((string s) => s, _ => "");
            if (name == "label" && isString(value))
                label = value.match!((string s) => s, _ => "");
            else if (name == "meta")
                meta = value;
            else
                throw new LuaException("unknown save option; expected label (string) or meta");
        }
    }
    return saveSession(session, label, meta);
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

        if (a.length < 1 || a.length > 2)
            throw new LuaException("save requires a session and an optional {label=, meta=} table");
        return [LuaValue(saveWithOptions(unwrapSession(a[0]), a.length == 2 ? a[1] : luaNil()))];
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
    method("ended", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("ended takes no arguments");
        return [unwrapSession(a[0]).endedWith()];
    });
    method("events_since", (void* p, LuaValue[] a) {
        if (a.length != 2 || !isInteger(a[1]) || a[1].match!((long n) => n, _ => -1L) < 0)
            throw new LuaException("events_since requires a nonnegative event sequence number");
        return [unwrapSession(a[0]).eventsAfter(a[1].match!((long n) => cast(ulong) n, _ => 0UL))];
    });
    method("set_period", (void* p, LuaValue[] a) {
        if (a.length != 3 || !isSymbol(a[1]))
            throw new LuaException("period requires a symbol and a serializable value");
        unwrapSession(a[0]).setPeriod(a[1].match!((Symbol s) => s.name, _ => ""), a[2]);
        return cast(LuaValue[])[];
    });
    method("play", (void* p, LuaValue[] a) {
        if (a.length != 2 || !a[1].isSymbol)
            throw new LuaException("play requires a scene symbol");
        unwrapSession(a[0]).playScene(nameOf(a[1]));
        return cast(LuaValue[])[];
    });
    method("advance", (void* p, LuaValue[] a) {
        if (a.length < 2 || a.length > 3)
            throw new LuaException("advance requires the scene token and optional input");
        unwrapSession(a[0]).advanceScene(a[1], a.length == 3 ? a[2] : LuaValue.init);
        return cast(LuaValue[])[];
    });
    method("visited", (void* p, LuaValue[] a) {
        if (a.length != 2 || !isSymbol(a[1]))
            throw new LuaException("visited requires a storylet symbol");
        return [LuaValue(cast(long) unwrapSession(a[0]).visitCount(nameOf(a[1])))];
    });
    method("last_chosen", (void* p, LuaValue[] a) {
        if (a.length != 2 || !isSymbol(a[1]))
            throw new LuaException("last_chosen requires a storylet symbol");
        ulong turn;
        if (!unwrapSession(a[0]).lastChosen(nameOf(a[1]), turn))
            return [luaNil()];
        return [LuaValue(cast(long) turn)];
    });
    method("set_autosave", (void* p, LuaValue[] a) {
        if (a.length != 2 || !(isFunction(a[1]) || isNil(a[1])))
            throw new LuaException("set_autosave requires a function (or nil) taking the save text");
        unwrapSession(a[0]).setAutosave(a[1]);
        return cast(LuaValue[])[];
    });
    method("set_undo_limit", (void* p, LuaValue[] a) {
        if (a.length != 2 || !isInteger(a[1]) || a[1].match!((long n) => n < 0, _ => true))
            throw new LuaException("set_undo_limit requires a nonnegative integer");
        unwrapSession(a[0]).setUndoLimit(cast(size_t) a[1].match!((long n) => n, _ => 0L));
        return cast(LuaValue[])[];
    });
    method("idle", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("idle requires a session");
        return [LuaValue(unwrapSession(a[0]).idle())];
    });
    method("undo_depth", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("undo_depth requires a session");
        return [LuaValue(cast(long) unwrapSession(a[0]).undoDepth())];
    });
    method("undo", (void* p, LuaValue[] a) {
        if (a.length != 1)
            throw new LuaException("undo requires a session");
        return [unwrapSession(a[0]).undo()];
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

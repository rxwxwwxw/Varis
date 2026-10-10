/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module tests.unit.test_narrative;
import varis;
import varis.narrative.codec;
import varis.narrative.registry;
import varis.narrative.templates;
import varis.narrative.persistence;
import varis.narrative.session;
import varis.logic.world;
import varis.logic.model;
import varis.vm;
import tests.unit.unit_runner : UnitMain;
import std.stdio : writeln;
import std.json;

void rejects(void delegate() operation, string message) {
    import std.string : indexOf;

    bool rejected;
    try {
        operation();
    } catch (LuaException e) {
        assert(e.msg.indexOf(message) >= 0, e.msg);
        rejected = true;
    }
    assert(rejected, message);
}

@("testCodec") unittest {
    LuaValue[] values = [
        luaNil(), LuaValue(true), LuaValue(long.max), LuaValue(long.min), LuaValue(1.25),
        LuaValue(1.0), LuaValue(-0.0), LuaValue("binary\0value"), LuaValue(Symbol("binary\0symbol"))
    ];
    foreach (value; values) {
        auto decoded = decodeValue(parseJSON(encodeValue(value).toString));
        assert(luaRawEqual(value, decoded));
        assert(value.typeOf() == decoded.typeOf());
    }
    assert(canonicalScalar(LuaValue(1L)) == canonicalScalar(LuaValue(1.0)));
    assert(canonicalScalar(LuaValue(-0.0)) == canonicalScalar(LuaValue(0L)));
    rejects({ canonicalScalar(LuaValue(double.infinity)); }, "nonfinite");
    rejects({ encodeValue(LuaValue(new LuaTable())); }, "unsupported save value");
    auto nested = immutableRecord(["values": immutableSequence(values)]);
    auto decoded = decodeValue(parseJSON(encodeValue(nested).toString));
    auto state = new LuaState();
    auto sequence = VM.getTable(state, decoded, LuaValue("values"));
    assert(luaRawEqual(VM.getTable(state, sequence, LuaValue(3L)), LuaValue(long.max)));
    rejects({ VM.setTable(state, decoded, LuaValue("values"), luaNil()); }, "immutable");
    writeln("  [PASS] canonical scalar identities and portable immutable codec");
}

@("testRegistryFailures") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation source(1)
        storylet unsafe(?missing)
            when {source(?value)}
            title "Unsafe"
            choice continue effect do end end
        end
    }");
    rejects({ state.narrativeRegistry.seal(); }, "unbound storylet parameter");
    assert(!state.narrativeRegistry.sealed());
    auto unknown = new LuaState();
    openLibs(unknown);
    unknown.doString(q"{
        relation source(1)
        storylet unknown(?value)
            when {source(?value)}
            deck :missing
            title "Unknown"
            choice continue effect do end end
        end
    }");
    rejects({ unknown.narrativeRegistry.seal(); }, "unknown narrative deck");
    auto badTemplate = new LuaState();
    openLibs(badTemplate);
    badTemplate.doString(q"{
        relation source(1)
        storylet unknown(?value)
            when {source(?value)}
            title "{missing}"
            choice continue effect do end end
        end
    }");
    rejects({ badTemplate.narrativeRegistry.seal(); }, "unknown narrative template placeholder");
    auto readonly = new LuaState();
    openLibs(readonly);
    rejects({ readonly.doString(q"{
        relation source(1)
        storylet readonly(?value)
            when {source(?value)}
            title "Readonly"
            choice continue effect do value = 2 end end
        end
    }"); }, "read-only narrative parameter");
    auto runtimeReadonly = new LuaState();
    openLibs(runtimeReadonly);
    runtimeReadonly.doString(q"{
        relation source(1) fact source(:p)
        storylet readonly(?value) when {source(?value)} title "Readonly"
            choice continue effect do debug.setlocal(1, 1, :changed) end end
        end
    }");
    runtimeReadonly.narrativeRegistry.seal();
    auto readonlyEffect = runtimeReadonly.narrativeRegistry.storylet("readonly").choices[0].effect;
    rejects({
        VM.callValue(runtimeReadonly, readonlyEffect, [
            wrapWorld(runtimeReadonly.globalWorld), LuaValue(Symbol("p"))
        ]);
    }, "read-only narrative parameter");
    writeln("  [PASS] sealing validation and read-only effect parameters");
}

@("testCompanionErrors") unittest {
    struct Failure {
        string source;
        string message;
        bool seal;
    }

    Failure[] cases = [
        Failure("relation p(1) storylet x(?v) when {p(?v)} title \"X\" title \"Y\" choice go effect do end end end", "duplicate content field", false),
        Failure("relation p(1) storylet x(?v) when {p(?v)} title \"X\" choice go(?missing) effect do end end end", "unbound choice parameter", true),
        Failure("relation p(1) action x(?missing) when {p(?v)} effect do end end", "unbound action parameter", true),
        Failure("relation p(0) storylet x() when {p()} title \"X\" choice go effect do end end end storylet x() when {p()} title \"Y\" choice go effect do end end end", "duplicate storylet", false),
        Failure("relation p(0) storylet x() when {p()} priority 1.5 title \"X\" choice go effect do end end end", "priority must be an integer", true),
        Failure("relation p(0) storylet x() when {p()} weight -1 title \"X\" choice go effect do end end end", "weight must be finite and nonnegative", true),
        Failure("relation p(0) storylet x() when {p()} cooldown -1 title \"X\" choice go effect do end end end", "cooldown must be a nonnegative integer", true),
        Failure("relation p(0) storylet x() when {p()} repeatable 1 title \"X\" choice go effect do end end end", "repeatable must be Boolean", true),
        Failure("deck :bad {draw=0}", "draw must be a positive integer", true),
        Failure("deck :bad {replacement=1}", "replacement must be Boolean", true)
    ];
    foreach (failure; cases) {
        auto state = new LuaState();
        openLibs(state);
        rejects({
            state.doString(failure.source);
            if (failure.seal)
                state.narrativeRegistry.seal();
        }, failure.message);
    }
    auto keys = new LuaState();
    openLibs(keys);
    keys.doString(q"{
        relation item(1) fact item({})
        storylet bad(?id) when {item(?id)} title "Bad" choice go effect do end end end
        local session = narrative.new(logic.global)
        session:seed(1)
        local ok, err = pcall(function() session:present() end)
        assert(not ok and string.find(err, "instance", 1, true), tostring(err))
        assert(session:turn() == 0)
    }");
    writeln("  [PASS] companion content/parameter/option error diagnostics");
}

@("testCompiledContexts") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation source(id, value) key(id)
        fact source(:p, 1)
        storylet update(?id)
            when {source(?id, ?existential)}
            title "Update {id}"
            choice increment(?value)
                when {source(?id, ?value)}
                title "Increase {value}"
                effect do adjust source(id) by 1 end
            end
        end
    }");
    state.narrativeRegistry.seal();
    auto definition = state.narrativeRegistry.storylet("update");
    auto child = state.globalWorld.cloneSnapshot();
    child.updateFact("source", RelTuple([LuaValue(Symbol("p")), LuaValue(5L)]), "set");
    auto iterator = VM.callValue(state, definition.availability, [wrapWorld(child)])[0];
    auto row = VM.callValue(state, iterator, [])[0];
    auto id = VM.getTable(state, row, LuaValue("id"));
    auto choice = definition.choices[0];
    auto choiceIterator = VM.callValue(state, choice.availability, [wrapWorld(child), id])[0];
    auto choiceRow = VM.callValue(state, choiceIterator, [])[0];
    assert(luaRawEqual(VM.getTable(state, choiceRow, LuaValue("value")), LuaValue(5L)));
    auto transaction = new Transaction(child);
    VM.callValue(state, choice.effect, [wrapWorld(child), id, LuaValue(5L)]);
    transaction.finish(true);
    assert(RelTuple([id, LuaValue(6L)]) in child.getRelation("source").baseFacts);
    assert(RelTuple([id, LuaValue(1L)]) in state.globalWorld.getRelation("source").baseFacts);
    state.doString("relation literal(1) fact literal(\"} -- { literal\")");
    auto template_ = new NarrativeTemplate(
            "{{outer}} {#if query {literal([=[} -- { literal]=]), -- } ignored\n" ~
            "where (true --[==[ { } ]==] )}}yes {#if query literal(\"missing\")}bad{#else}nested{/if}{#else}no{/if}", [
    ]);
    assert(template_.render(state, state.globalWorld.cloneSnapshot(), null,
            (LuaValue value) => toLuaString(value)) == "{outer} yes nested");
    rejects({ new NarrativeTemplate("{#if query literal([=[unterminated)}", []); }, "unterminated long bracket");
    writeln("  [PASS] narrative session-world contexts and correlated choice bindings");
}

@("testSessions") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation counter(id, value) key(id)
        fact counter(:p, 0)
        deck :other {draw = 2, replacement = false}
        local fail = true
        local callbacks = 0
        storylet start(?id)
            when {counter(?id, ?n)}
            title "Start {id}"
            choice go(?n)
                when {counter(?id, ?n)}
                title "Go {n}"
                effect do
                    adjust counter(id) by 1
                    narrative.push_deck(:other)
                    narrative.emit(:chosen, id, nil, n)
                    narrative.defer(function() callbacks = callbacks + 1 end)
                    if fail then error("effect failed") end
                end
            end
        end
        storylet other()
            when {counter(:p, ?n)}
            deck :other
            title "Other"
            choice done effect do narrative.pop_deck() end end
        end
        local session = narrative.new(logic.global)
        session:seed(42)
        assert(session:turn() == 0 and session:active_deck() == :default)
        local p = session:present()
        assert(#p.storylets == 1 and p.storylets[1].bindings.id == :p)
        local token = p.storylets[1].choices[1].token
        local ok, err = pcall(function() session:choose(token) end)
        assert(not ok and string.find(err, "effect failed", 1, true))
        assert(session:turn() == 0 and session:active_deck() == :default and callbacks == 0)
        assert((query {counter(:p, 0)})() ~= nil)
        assert((query {narrative_event(?s, ?t, ?k, ?a)})() == nil)
        fail = false
        session:choose(token)
        assert(session:turn() == 1 and session:active_deck() == :other and callbacks == 1)
        assert((query {counter(:p, 1)})() ~= nil)
        local event = (query {narrative_event(?s, ?t, ?k, ?a)})()
        assert(event.s == 1 and event.t == 0 and event.k == :chosen)
        assert(#event.a == 3 and event.a[1] == :p and event.a[2] == nil and event.a[3] == 0)
        ok, err = pcall(function() session:choose(token) end)
        assert(not ok and string.find(err, "STALE_CHOICE", 1, true))
        local next = session:present()
        assert(#next.storylets == 1 and next.storylets[1].id == :other)
        assert(#session:present().storylets == 0)
        session:choose(next.storylets[1].choices[1].token)
        assert(session:turn() == 2 and session:active_deck() == :default)
        local stale = session:present().storylets[1].choices[1].token
        delete counter(:p)
        ok, err = pcall(function() session:choose(stale) end)
        assert(not ok and string.find(err, "STALE_CHOICE", 1, true) and session:turn() == 2)
        ok, err = pcall(function() fact narrative_event(7, 0, :bad, nil) end)
        assert(not ok and string.find(err, "read-only relation", 1, true))
        ok, err = pcall(function() narrative.emit(:outside) end)
        assert(not ok and string.find(err, "active transactional effect", 1, true))
    }");
    writeln("  [PASS] session choices, deck draws, atomic rollback, events and stale tokens");
}

@("testActionsAndEvents") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation counter(id, value) key(id)
        relation seen(1)
        fact counter(:p, 0)
        local callbacks = 0
        narrative.on(:tick, function(world, kind, args)
            logic (world) do
                fact seen(args[1])
                narrative.emit(:handled, args[1])
            end
        end)
        action prepare(?id)
            when {counter(?id, ?n)}
            phase :pre
            once_per :game
            effect do
                transaction do
                    narrative.emit(:discarded)
                    narrative.defer(function() callbacks = callbacks + 100 end)
                    narrative.push_deck(:default)
                    rollback
                end
                narrative.schedule(:tick, narrative.sequence(id), 0)
                narrative.defer(function() callbacks = callbacks + 1 end)
            end
        end
        action post(?id)
            when {counter(?id, ?n)}
            phase :post
            once_per :turn
            effect do adjust counter(id) by 10 end
        end
        storylet advance(?id)
            when {counter(?id, ?n), seen(?id)}
            title "Advance"
            choice go effect do adjust counter(id) by 1 end end
        end
        local session = narrative.new(logic.global)
        session:seed(12)
        local p = session:present()
        assert(callbacks == 1 and #p.storylets == 1)
        assert((query {narrative_event(?s, ?t, :discarded, ?a)})() == nil)
        assert((query {narrative_event(1, 0, :tick, ?a)})() ~= nil)
        assert((query {narrative_event(2, 0, :handled, ?a)})() ~= nil)
        session:choose(p.storylets[1].choices[1].token)
        assert(session:turn() == 1 and (query {counter(:p, 11)})() ~= nil)
        session:present()
        assert(callbacks == 1 and (query {counter(:p, 11)})() ~= nil)
    }");
    auto loop = new LuaState();
    openLibs(loop);
    loop.doString(q"{
        relation counter(id, value) key(id)
        fact counter(:p, 0)
        action endless(?id)
            when {counter(?id, ?n)}
            phase :pre
            once_per :always
            effect do adjust counter(id) by 1 end
        end
        local session = narrative.new(logic.global)
        session:limits(3, 3)
        local ok, err = pcall(function() session:present() end)
        assert(not ok and string.find(err, "ACTION_LIMIT", 1, true))
        assert((query {counter(:p, 3)})() ~= nil and session:turn() == 0)
    }");
    writeln("  [PASS] action scheduling, nested narrative savepoints, due events and action limits");
}

@("testDeterminismAndBudgets") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation candidate(1)
        fact candidate(:a)
        fact candidate(:b)
        fact candidate(nil)
        deck :default {draw = 2, replacement = true}
        storylet sample(?id)
            when {candidate(?id)}
            title "Sample {id}"
            choice stay effect do end end
        end
        local left = narrative.new(logic.world(logic.global))
        local right = narrative.new(logic.world(logic.global))
        local ok, err = pcall(function() left:present() end)
        assert(not ok and string.find(err, "explicitly seeded", 1, true))
        left:seed(987)
        right:seed(987)
        for n = 1, 12 do
            local a, b = left:present(), right:present()
            assert(#a.storylets == 2 and #b.storylets == 2)
            assert(a.storylets[1].bindings.id == b.storylets[1].bindings.id)
            assert(a.storylets[2].bindings.id == b.storylets[2].bindings.id)
            assert(a.storylets[1].bindings.id ~= a.storylets[2].bindings.id)
        end
        local a = left:present()
        ok, err = pcall(function() right:choose(a.storylets[1].choices[1].token) end)
        assert(not ok and string.find(err, "STALE_CHOICE", 1, true))
        left:choose(a.storylets[1].choices[1].token)
        assert(left:turn() == 1 and right:turn() == 0)
    }");
    auto events = new LuaState();
    openLibs(events);
    events.doString(q"{
        relation ready(0)
        fact ready()
        narrative.on(:loop, function(world, kind, args)
            narrative.schedule(:loop, args, 0)
        end)
        action begin()
            when {ready()}
            phase :pre
            once_per :game
            effect do narrative.schedule(:loop, narrative.sequence(nil), 0) end
        end
        local session = narrative.new(logic.global)
        session:limits(5, 3)
        local ok, err = pcall(function() session:present() end)
        assert(not ok and string.find(err, "EVENT_LIMIT", 1, true))
        local count = 0
        for row in query {narrative_event(?s, ?t, :loop, ?a)} do
            count = count + 1
            assert(row.t == 0 and #row.a == 1 and row.a[1] == nil)
        end
        assert(count == 3 and session:turn() == 0)
    }");
    auto callback = new LuaState();
    openLibs(callback);
    callback.doString(q"{
        relation ready(0)
        fact ready()
        storylet committed()
            when {ready()}
            title "Commit"
            repeatable false
            choice go effect do
                retract ready()
                narrative.defer(function() error("external callback failed") end)
            end end
        end
        local session = narrative.new(logic.global)
        session:seed(1)
        local token = session:present().storylets[1].choices[1].token
        local ok, err = pcall(function() session:choose(token) end)
        assert(not ok and string.find(err, "external callback failed", 1, true))
        assert(session:turn() == 1 and (query {ready()})() == nil)
        ok, err = pcall(function() session:choose(token) end)
        assert(not ok and string.find(err, "STALE_CHOICE", 1, true))
    }");
    writeln("  [PASS] independent deterministic sessions, scheduled-event budgets and post-commit errors");
}

@("testQualities") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        assert(require("quality") == quality)
        quality.define(:coins, {initial = 0, minimum = 0, maximum = 100, label = "Coins"})
        quality.define(:optional, {initial = nil, visible = false})
        quality.define(:large, {initial = 9007199254740993, minimum = 9007199254740993})
        local function rejects(f, text)
            local ok, err = pcall(f)
            assert(not ok and string.find(err, text, 1, true), tostring(err))
        end
        rejects(function() quality.define(:bad, {initial = -1, minimum = 0}) end, "below minimum")
        quality.define(:bad, {initial = 1, minimum = 0})
        rejects(function() quality.define(:reversed, {initial = 0, minimum = 10, maximum = 1}) end, "minimum exceeds")
        assert(quality.get(:p, :coins) == nil)
        assert((query {quality(:p, :coins, ?n)})() == nil)
        rejects(function() quality.add(:p, :coins, 1) end, "key is absent")
        quality.initialize(:p, :coins)
        quality.add(:p, :coins, 10)
        quality.initialize(:p, :coins)
        assert(quality.get(:p, :coins) == 10)
        rejects(function() quality.set(:p, :coins, 101) end, "above maximum")
        rejects(function() set quality(:p, :coins, -1) end, "below minimum")
        rejects(function() adjust quality(:p, :coins) by -20 end, "below minimum")
        rejects(function() fact quality(:q, :coins, -1) end, "below minimum")
        assert(quality.get(:p, :coins) == 10 and quality.get(:q, :coins) == nil)
        rejects(function() fact quality(:p, :unknown, 0) end, "unknown quality")
        rejects(function() quality.initialize(:p, "coins") end, "must be a symbol")
        rejects(function() quality.set(:p, :large, 9007199254740992.0) end, "below minimum")
        quality.initialize(:p, :large)
        quality.initialize(:p, :optional)
        assert(quality.get(:p, :optional) == nil)
        assert((query {quality(:p, :optional, nil)})() ~= nil)
        transaction do
            quality.add(:p, :coins, 5)
            assert(quality.get(:p, :coins) == 15)
            transaction do
                quality.add(:p, :coins, 5)
                rollback
            end
            assert(quality.get(:p, :coins) == 15)
            rollback
        end
        assert(quality.get(:p, :coins) == 10)
        local child = logic.world()
        quality.set(:p, :coins, 20, child)
        assert(quality.get(:p, :coins, child) == 20 and quality.get(:p, :coins) == 10)
        logic (child) do
            rejects(function() adjust quality(:p, :coins) by 100 end, "above maximum")
        end
        local empty = logic.emptyworld()
        quality.initialize(:p, :coins, empty)
        assert(quality.get(:p, :coins, empty) == 0)
        local read_global = function() return quality.get(:p, :coins) end
        local read_child
        logic (child) do
            read_child = function() return quality.get(:p, :coins) end
            -- Outside effects the library still defaults to global.
            assert(read_child() == 10)
        end
        local add_alias = quality.add
        storylet earn(?id)
            when {quality(?id, :coins, ?n)}
            title "Earn"
            choice go effect do
                assert(read_global() == 10 and read_child() == 20)
                logic (empty) do
                    assert(quality.get(id, :coins) == 0)
                    rejects(function() add_alias(id, :coins, 1) end, "cross-world mutation")
                end
                logic (child) do add_alias(id, :coins, 1) end
                assert(quality.get(id, :coins) == 21)
            end end
        end
        local session = narrative.new(child)
        session:seed(1)
        local token = session:present().storylets[1].choices[1].token
        session:choose(token)
        assert(quality.get(:p, :coins, child) == 21 and quality.get(:p, :coins) == 10)
        rejects(function() quality.define(:late, {initial = 0}) end, "sealed")
    }");
    writeln("  [PASS] quality metadata, nil presence, direct-write bounds, numeric precision and transactional world defaults");
}

private string stringValueForTest(JSONValue value) {
    return decodeValue(value).match!((string s) => s, _ => "");
}

@("testPortableSessions") unittest {
    enum authored = q"{
        quality.define(:coins, {initial = 0, minimum = 0, maximum = 1000})
        narrative.on(:later, function(world, kind, args)
            logic (world) do fact received(args[1]) end
        end)
        deck :default {draw = 2, replacement = true}
        storylet earn(?id)
            when {eligible(?id)}
            title "Earn {id}"
            choice go effect do
                quality.add(id, :coins, 1)
                narrative.emit(:earned, id, nil, "binary\0value")
                narrative.schedule(:later, narrative.sequence(id), 2)
            end end
        end
        function make_world()
            local world = logic.emptyworld()
            logic (world) do
                relation person(1)
                relation received(1)
                relation payload(2)
                relation eligible(1)
                fact person(:a)
                fact person(:b)
                fact person(nil)
                local threshold = 0
                rule eligible(?id) :- person(?id), quality(?id, :coins, ?n), where (?n >= threshold)
            end
            quality.initialize(:a, :coins, world)
            quality.initialize(:b, :coins, world)
            quality.initialize(nil, :coins, world)
            narrative.program(world, "rules-v1")
            return world
        end
        narrative.seal()
    }";
    auto state = new LuaState();
    openLibs(state);
    state.doString(authored);
    state.doString(q"{
        session = narrative.new(make_world())
        session:seed(345)
        session:record_input(:weather, narrative.sequence(nil, :sunny))
        session:set_period(:day, narrative.sequence(nil, :morning, "binary\0name"))
        session:choose(session:present().storylets[1].choices[1].token)
        local log = session:replay_log()
        assert(log.inputs[1].kind == :seed and log.inputs[2].kind == :external)
        assert(log.inputs[3].kind == :period and log.inputs[4].kind == :present and log.inputs[5].kind == :choose)
        saved = session:save()
        replayed = narrative.new(make_world())
        local current
        for index = 1, #log.inputs do
            local command = log.inputs[index]
            if command.kind == :seed then replayed:seed(command.value)
            elseif command.kind == :external then replayed:record_input(command.value[1], command.value[2])
            elseif command.kind == :period then replayed:set_period(command.value[1], command.value[2])
            elseif command.kind == :present then
                current = replayed:present()
                assert(#current.storylets == #command.value)
                for i = 1, #current.storylets do assert(current.storylets[i].instance_key == command.value[i]) end
            elseif command.kind == :choose then
                local token
                for i = 1, #current.storylets do
                    local story = current.storylets[i]
                    if story.instance_key == command.value[1] then
                        for j = 1, #story.choices do
                            if story.choices[j].instance_key == command.value[2] then token = story.choices[j].token end
                        end
                    end
                end
                assert(token ~= nil)
                replayed:choose(token)
            end
        end
        restored = narrative.load(saved, make_world)
        assert(saved == restored:save())
        assert(restored:turn() == 1 and restored:world() ~= session:world())
        for n = 1, 32 do
            local a, b = session:present(), restored:present()
            assert(#a.storylets == #b.storylets)
            for i = 1, #a.storylets do assert(a.storylets[i].bindings.id == b.storylets[i].bindings.id) end
            session:choose(a.storylets[1].choices[1].token)
            restored:choose(b.storylets[1].choices[1].token)
            assert(session:save() == restored:save())
        end
        logic (restored:world()) do
            assert((query {received(?id)})() ~= nil)
        end
    }");
    auto session = unwrapSession(state.getGlobal("session"));
    auto replayed = parseJSON(saveSession(unwrapSession(state.getGlobal("replayed"))));
    auto initial = parseJSON(state.getGlobal("saved").match!((string s) => s, _ => ""));
    replayed["world_identity"] = initial["world_identity"];
    assert(canonicalJSON(replayed) == canonicalJSON(initial), "replaying recorded commands changed committed state");
    auto saved = saveSession(session);
    auto second = new LuaState();
    openLibs(second);
    second.doString(authored);
    auto restored = loadSession(second, saved, second.getGlobal("make_world"));
    assert(saved == saveSession(restored), "cross-state canonical roundtrip");
    auto factory = state.getGlobal("make_world");
    auto pristine = unwrapWorld(VM.callValue(state, factory, [])[0]);
    auto unchanged = pristine.version_;
    auto constantFactory = LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
            return [wrapWorld(pristine)];
        }));
    auto input = parseJSON(saved);
    input["turn"] = JSONValue("-1");
    rejects({ loadSession(state, input.toString, constantFactory); }, "invalid save counter");
    input = parseJSON(saved);
    input["content"] = JSONValue("wrong");
    rejects({ loadSession(state, input.toString, constantFactory); }, "content version");
    input = parseJSON(saved);
    input["runtime"] = JSONValue("wrong");
    rejects({ loadSession(state, input.toString, constantFactory); }, "runtime version");
    input = parseJSON(saved);
    foreach (ref relation; input["relations"].array)
        if (relation["columns"].array.length == 3) {
            auto columns = relation["columns"].array;
            auto temporary = columns[0];
            columns[0] = columns[1];
            columns[1] = temporary;
            break;
        }
    rejects({ loadSession(state, input.toString, constantFactory); }, "relation schema");
    input = parseJSON(saved);
    input["program_fingerprint"] = JSONValue("wrong");
    rejects({ loadSession(state, input.toString, constantFactory); }, "rule program");
    input = parseJSON(saved);
    input["events"].array[0]["turn"] = JSONValue("999");
    rejects({ loadSession(state, input.toString, constantFactory); }, "event history");
    input = parseJSON(saved);
    foreach (ref relation; input["relations"].array)
        if (stringValueForTest(relation["name"]) == "quality") {
            auto facts = relation["facts"].array;
            facts[0].array[2] = encodeValue(LuaValue(1001L));
            break;
        }
    rejects({ loadSession(state, input.toString, constantFactory); }, "above maximum");
    input = parseJSON(saved);
    input["events"].array[0]["kind"] = encodeValue(LuaValue(Symbol("changed")));
    rejects({ loadSession(state, input.toString, constantFactory); }, "relation/history mismatch");
    assert(pristine.version_ == unchanged && pristine.narrativeOwner is null && pristine.getRelation(
            "narrative_event") is null,
            "failed load changed authored destination");
    session.world.addFact("payload", RelTuple([LuaValue("mutable"), LuaValue(new LuaTable())]));
    rejects({ saveSession(session); }, "relation.payload[1]");
    session.world.getRelation("payload").baseFacts = null;
    state.doString(q"{
        logic (session:world()) do
            rule eligible(?id) :- person(?id)
        end
    }");
    rejects({ saveSession(session); }, "program changed");
    writeln("  [PASS] portable session roundtrips, authored programs, cross-state replay and atomic load rejection");
}

@("testPersistenceRejections") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation ready(0)
        fact ready()
        storylet boundary()
            when {ready()}
            title "Boundary"
            choice save effect do boundary_session:save() end end
        end
        boundary_session = narrative.new(logic.global)
        boundary_session:seed(1)
        local token = boundary_session:present().storylets[1].choices[1].token
        local ok, err = pcall(function() boundary_session:choose(token) end)
        assert(not ok and string.find(err, "conflicting narrative session command", 1, true))
        assert(boundary_session:turn() == 0)
        transaction do
            ok, err = pcall(function() boundary_session:save() end)
            assert(not ok and string.find(err, "conflicting narrative session command", 1, true))
            ok, err = pcall(function() narrative.load("invalid", function() return logic.emptyworld() end) end)
            assert(not ok and string.find(err, "active operation", 1, true))
        end
    }");
    auto guards = new LuaState();
    openLibs(guards);
    guards.doString(q"{
        relation seed(1)
        fact seed(1)
        rule out(?x) :- seed(?x), where (?x > 0)
        s = narrative.new(logic.global)
    }");
    rejects({ saveSession(unwrapSession(guards.getGlobal("s"))); }, "non-reconstructible runtime rule guard");
    auto mutable = new LuaState();
    openLibs(mutable);
    mutable.doString(q"{
        relation seed(1)
        fact seed(1)
        local object = {}
        storylet captured(?x)
            when {seed(?x)}
            title "Captured"
            choice go effect do object.value = x end end
        end
        s = narrative.new(logic.global)
    }");
    rejects({ saveSession(unwrapSession(mutable.getGlobal("s"))); }, "non-reconstructible capture");
    auto aggregate = new LuaState();
    openLibs(aggregate);
    aggregate.doString(q"{
        function factory()
            local w = logic.emptyworld()
            logic (w) do
                relation seed(2)
                fact seed(:a, 1)
                fact seed(:b, 1)
                rule total(?n) :- ?n = count {seed(?_, ?_)}
            end
            return w
        end
        local s = narrative.new(factory())
        local restored = narrative.load(s:save(), factory)
        logic (restored:world()) do assert((query {total(?n)})().n == 2) end
        saved = s:save()
    }");
    auto source = unwrapWorld(VM.callValue(aggregate, aggregate.getGlobal("factory"), [])[0]);
    auto counterBefore = source.version_;
    auto factory = LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
            return [wrapWorld(source)];
        }));
    auto saved = aggregate.getGlobal("saved").match!((string s) => s, _ => "");
    auto incompatible = parseJSON(saved);
    incompatible["content"] = JSONValue("old-content");
    auto library = aggregate.getGlobal("narrative");
    auto load = VM.getTable(aggregate, library, LuaValue("load"));
    auto migration = LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) {
            return [LuaValue(saved)];
        }));
    auto restored = VM.callValue(aggregate, load, [
        LuaValue(incompatible.toString), factory, migration
    ]);
    assert(restored.length == 1 && unwrapSession(restored[0]).world !is source);
    auto badMigration = LuaValue(new LuaNativeFunction((void* p, LuaValue[] a) { return [luaNil()]; }));
    rejects({
        VM.callValue(aggregate, load, [LuaValue(incompatible.toString), factory, badMigration]);
    }, "migration must return");
    assert(source.version_ == counterBefore && source.narrativeOwner is null);
    writeln("  [PASS] active-save restrictions, unsupported runtime closures, anonymous aggregate reconstruction and explicit migration");
}

@("testObservers") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation seed(1)
        relation blocked(1)
        relation visible(1)
        relation other(1)
        fact seed(:a)
        rule visible(?x) :- seed(?x), not blocked(?x)
        local notifications = {}
        local function append(kind, tuple)
            assert(#tuple == 1)
            notifications[#notifications + 1] = kind .. narrative.display(tuple[1])
            local ok, err = pcall(function() tuple[1] = :changed end)
            assert(not ok and string.find(err, "immutable", 1, true))
        end
        local cancel_seed = narrative.observe(logic.global, "seed", {
            on_enter = function(tuple) append("seed+", tuple) end,
            on_leave = function(tuple) append("seed-", tuple) end
        })
        narrative.observe(logic.global, :visible, {
            on_enter = function(tuple) append("visible+", tuple) end,
            on_leave = function(tuple) append("visible-", tuple) end
        })
        transaction do
            fact seed(:c)
            fact seed(:b)
            fact blocked(:a)
            assert(#notifications == 0)
        end
        assert(table.concat(notifications, ",") == "seed+b,seed+c,visible-a,visible+b,visible+c")
        notifications = {}
        fact seed(:a)
        assert(#notifications == 0)
        transaction do
            fact seed(:d)
            retract seed(:a)
            rollback
        end
        assert(#notifications == 0)
        transaction do
            transaction do fact seed(:d) rollback end
            fact blocked(:b)
        end
        assert(table.concat(notifications, ",") == "visible-b")
        notifications = {}
        retract blocked(:a)
        retract seed(:b)
        assert(table.concat(notifications, ",") == "visible+a,seed-b")
        notifications = {}
        local child = logic.world()
        fact child.seed(:child)
        assert(#notifications == 0)
        cancel_seed()
        fact blocked(:c)
        fact seed(:new)
        assert(table.concat(notifications, ",") == "visible-c,visible+new")

        local entered, later = 0, 0
        narrative.observe(logic.global, "other", {
            on_enter = function(tuple)
                entered = entered + 1
                local ok, err = pcall(function() fact other(:forbidden) end)
                assert(not ok and string.find(err, "notifying world", 1, true))
                local fiber = coroutine.create(function() fact other(:fiber) end)
                ok, err = coroutine.resume(fiber)
                assert(not ok and string.find(err, "notifying world", 1, true))
                narrative.enqueue(function() later = later + 1 end)
            end
        })
        fact other(nil)
        assert(entered == 1 and later == 0 and (query {other(:forbidden)})() == nil)
        narrative.flush(logic.global)
        assert(later == 1)
        narrative.observe(logic.global, "other", {on_enter = function(tuple) error("observer error") end})
        local ok, err = pcall(function() fact other(:committed) end)
        assert(not ok and string.find(err, "observer error", 1, true))
        assert((query {other(:committed)})() ~= nil and entered == 2)
        narrative.flush(logic.global)
        assert(later == 2)
        notifications = {}
        fact other(:committed)
        assert(entered == 2)
        local counts = 0
        relation derived(1)
        narrative.observe(logic.global, "derived", {on_enter = function(tuple) counts = counts + 1 end})
        rule derived(?x) :- seed(?x)
        assert(counts == 3)
        local s = narrative.new(logic.global)
        local saved = s:save()
        local restored = narrative.load(saved, function()
            local w = logic.emptyworld()
            logic (w) do
                relation seed(1)
                relation blocked(1)
                relation visible(1)
                relation other(1)
                relation derived(1)
                rule visible(?x) :- seed(?x), not blocked(?x)
                rule derived(?x) :- seed(?x)
            end
            return w
        end)
        local restored_world = restored:world()
        fact restored_world.other(:restored)
        assert(entered == 2, "saved subscriptions leaked into restored world")
    }");
    auto queued = new LuaState();
    openLibs(queued);
    queued.doString(q"{
        relation steps(id, value) key(id)
        narrative.observe(logic.global, "steps", {
            on_enter = function(tuple)
                narrative.enqueue(function() set steps(:p, tuple[2] + 1) end)
            end
        })
        set steps(:p, 0)
        local ok, err = pcall(function() narrative.flush(logic.global, 3) end)
        assert(not ok and string.find(err, "OBSERVER_QUEUE_LIMIT", 1, true))
        assert((query {steps(:p, ?n)})().n == 3)
    }");
    writeln("  [PASS] committed base/derived observer deltas, canonical order, rollback, cancellation, callback isolation and queued budgets");
}

@("testExplanations") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation person(1)
        relation value(id, amount) key(id)
        relation blocked(1)
        relation seen(1)
        fact person(:a)
        fact person(:b)
        fact person(nil)
        fact value(:a, 11)
        fact value(:b, 3)
        fact value(nil, 12)
        deck :default {draw = 2, replacement = false}
        deck :other {draw = 1, replacement = true}
        storylet gated(?p)
            when {person(?p), value(?p, ?n), ?n >= 10, not blocked(?p), where (true)}
            priority 100
            cooldown 2
            repeatable false
            title "Gated {p}"
            choice go when {value(?p, ?n), ?n > 10} effect do set value(p, 20) end end
        end
        storylet elsewhere()
            when {person(:a)}
            deck :other
            title "Elsewhere"
            choice go effect do end end
        end
        storylet zero()
            when {person(:a)}
            weight 0
            title "Zero"
            choice go effect do end end
        end
        function evil() fact person(:forbidden) return true end
        storylet unsafe()
            when {person(:a), where (evil())}
            deck :other
            title "Unsafe"
            choice go effect do end end
        end
        action marker(?p)
            when {person(?p)}
            phase :pre
            once_per :game
            effect do fact seen(p) end
        end
        local session = narrative.new(logic.global)
        session:seed(77)
        local before = session:save()
        local explanation = narrative.explain(session, :gated, {p = :a})
        assert(explanation.eligible and explanation.availability.success)
        assert(#explanation.availability.goals == 5 and #explanation.instances == 1)
        for i = 1, 5 do assert(explanation.availability.goals[i].outcome == "success") end
        assert(explanation.instances[1].choices[1].availability.success)
        explanation = narrative.explain(session, :gated, {p = :b})
        assert(not explanation.eligible and explanation.availability.goals[3].outcome == "failure")
        assert(explanation.availability.goals[4].outcome == "not_reached")
        assert(explanation.availability.goals[5].outcome == "not_reached")
        explanation = narrative.explain(session, :elsewhere)
        assert(explanation.instances[1].exclusions[1] == :deck)
        explanation = narrative.explain(session, :zero)
        assert(explanation.instances[1].exclusions[1] == :zero_weight)
        explanation = narrative.explain(session, :unsafe)
        assert(not explanation.eligible and explanation.availability.goals[2].outcome == "error")
        assert(string.find(explanation.availability.goals[2].error, "read-only", 1, true))
        assert((query {person(:forbidden)})() == nil)
        assert(before == session:save(), "explanation mutated world, session or RNG")
        local p = session:present()
        local token, nil_bindings
        for i = 1, #p.storylets do
            local story = p.storylets[i]
            if story.bindings.p == :a then token = story.choices[1].token else nil_bindings = story.bindings end
        end
        assert(token ~= nil and nil_bindings ~= nil)
        explanation = narrative.explain(session, :gated, nil_bindings)
        assert(#explanation.instances == 1 and explanation.instances[1].bindings.p == nil)
        assert(explanation.instances[1].exclusions[1] == :already_drawn)
        explanation = narrative.explain(session, :marker, {p = :a})
        assert(explanation.instances[1].exclusions[1] == :once_per)
        session:choose(token)
        explanation = narrative.explain(session, :gated, {p = :a})
        assert(not explanation.eligible)
        assert(explanation.instances[1].exclusions[1] == :completed and explanation.instances[1].exclusions[2] == :cooldown)
        local ok, err = pcall(function() narrative.explain(session, :gated, {unknown = 1}) end)
        assert(not ok and string.find(err, "unknown explanation parameter", 1, true))
    }");
    writeln(
            "  [PASS] structured goal explanations, policy exclusions, explicit nil bindings and logical/session/RNG purity");
}

@("testAnalysis") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        relation location(entity, place) key(entity)
        fact location(:player, :start)
        local box = {count = 0}
        box.self = box
        globalbox, globalalias = box, box
        globalcounter = 0
        local function mutate()
            assert(box == globalbox and globalbox == globalalias and box.self == box)
            box.count = box.count + 1
            globalcounter = globalcounter + 1
        end
        storylet start()
            when {location(:player, :start)}
            title "Start"
            choice left effect do
                mutate()
                narrative.defer(function() mutate() end)
                set location(:player, :left)
            end end
            choice right effect do mutate() set location(:player, :right) end end
        end
        storylet never()
            when {location(:player, :never)}
            title "Never"
            choice go effect do end end
        end
        narrative.seal("analysis-fixture-v1")
        live_session = narrative.new(logic.global)
        live_session:seed(45)
        local before = live_session:save()
        local report = narrative.analyze(live_session, {depth = 3})
        assert(report.complete, #report.errors > 0 and report.errors[1].reason or "incomplete analysis")
        assert(report.nodes == 3 and report.transitions == 2 and #report.dead_ends == 2)
        assert(#report.reached_content == 1 and report.reached_content[1] == :start)
        assert(#report.unreachable_content == 1 and report.unreachable_content[1].id == :never)
        assert(report.depth_reached == 1 and report.depth_limit == 3)
        assert(globalbox == box and box.count == 0 and globalcounter == 0)
        assert(before == live_session:save(), "analysis changed live world, Lua captures, history or RNG")
        report = narrative.analyze(live_session, {depth = 0})
        assert(not report.complete and #report.frontier == 1 and report.transitions == 0)
        report = narrative.analyze(live_session, {max_nodes = 1})
        assert(not report.complete and report.nodes == 1 and report.transitions == 0)
        report = narrative.analyze(live_session, {max_objects = 1})
        assert(not report.complete and #report.errors == 1 and string.find(report.errors[1].reason, "OBJECT_LIMIT", 1, true))
        assert(before == live_session:save())
    }");
    auto cycle = new LuaState();
    openLibs(cycle);
    cycle.doString(q"{
        relation ready(0)
        fact ready()
        globalcounter = 0
        action spin()
            when {ready()}
            phase :pre
            once_per :always
            effect do globalcounter = globalcounter + 1 end
        end
        local s = narrative.new(logic.global)
        s:limits(3, 3)
        local before = s:save()
        local report = narrative.analyze(s, {depth = 2})
        assert(not report.complete and #report.action_cycles == 1)
        assert(string.find(report.action_cycles[1].reason, "ACTION_LIMIT", 1, true))
        assert(globalcounter == 0 and before == s:save())
    }");
    auto infinite = new LuaState();
    openLibs(infinite);
    infinite.doString(q"{
        relation ready(0)
        fact ready()
        storylet loop()
            when {ready()}
            title "Loop"
            choice go effect do while true do end end end
        end
        local s = narrative.new(logic.global)
        s:seed(1)
        local before = s:save()
        local report = narrative.analyze(s, {max_steps = 2000})
        assert(not report.complete and report.instructions == 2000 and #report.errors > 0)
        assert(string.find(report.errors[1].reason, "STEP_LIMIT", 1, true))
        assert(before == s:save())
    }");
    auto external = new LuaState();
    openLibs(external);
    size_t writes;
    external.registerGlobal("host_write", (void* p, LuaValue[] a) {
        writes++;
        return cast(LuaValue[])[];
    });
    external.doString(q"{
        relation ready(0)
        fact ready()
        storylet external()
            when {ready()}
            title "External"
            choice go effect do host_write() end end
            choice random effect do math.random() end end
            choice file effect do io.write("analysis-must-not-print") end end
        end
        local s = narrative.new(logic.global)
        s:seed(1)
        math.randomseed(123)
        local expected = math.random()
        math.randomseed(123)
        local before = s:save()
        local report = narrative.analyze(s, {depth = 1})
        assert(not report.complete and #report.blocked_external_effects == 3 and #report.errors == 3, "blocked=" .. #report.blocked_external_effects .. ", errors=" .. #report.errors .. ":" .. (#report.errors > 0 and report.errors[1].reason or "none") .. ":" .. (#report.errors > 1 and report.errors[2].reason or "none") .. ":" .. (#report.errors > 2 and report.errors[3].reason or "none"))
        assert(math.random() == expected and before == s:save())
    }");
    assert(writes == 0, "analysis invoked host external callback");
    writeln("  [PASS] bounded choice analysis, deep Lua alias/capture isolation, dead ends, cycle candidates, budgets and blocked external effects");
}

@("testFormattersAndVariants") unittest {
    auto state = new LuaState();
    openLibs(state);
    state.doString(q"{
        -- 1. Formatters
        narrative.name(:library, "the Grand Library")
        narrative.formatter("nil", function(v) return "<absent>" end)
        narrative.formatter(:coins, function(v) return "Gold Coins" end)
        narrative.formatter("number", function(v) return "#" .. tostring(v) end)
        
        assert(narrative.display(nil) == "<absent>")
        assert(narrative.display(symbol("library")) == "the Grand Library")
        assert(narrative.display(symbol("coins")) == "Gold Coins")
        assert(narrative.display(42) == "#42")
        assert(narrative.display("hello") == "hello")
        
        -- In templates with explicit nil record:
        relation has_nil(1)
        fact has_nil(nil)
        local rec
        for r in query has_nil(?tag) do rec = r break end
        local renderedNil = narrative.template("Tag: {tag}", rec)
        assert(renderedNil == "Tag: <absent>")
        local rendered = narrative.template("Item: {item}, Count: {count}", {item = symbol("coins"), count = 5})
        assert(rendered == "Item: Gold Coins, Count: #5")

        -- 2. Variants in template
        local tpl = "Greeting: {#variant 3} Hello {#variant 1} Welcome {/variant}!"
        local r1 = narrative.template(tpl, {}, nil, 0)
        local r2 = narrative.template(tpl, {}, nil, 1)
        assert(r1 == "Greeting:  Hello !")
        assert(r2 == "Greeting:  Welcome !")
        -- Default picks highest weight (option 0)
        local rDef = narrative.template(tpl, {})
        assert(rDef == "Greeting:  Hello !")

        -- Variants with {#else}
        local tplElse = "Weather: {#variant 2} Sunny {#else} Rainy {/variant}."
        assert(narrative.template(tplElse, {}, nil, 0) == "Weather:  Sunny .")
        assert(narrative.template(tplElse, {}, nil, 1) == "Weather:  Rainy .")

        -- Nested variants and {#variants} block
        local tplBlock = "Choices: {#variants} {#variant 10} Option A {/variant} {#variant 1} Option B {/variant} {/variants}"
        assert(narrative.template(tplBlock, {}, nil, 0) == "Choices:  Option A ")
        assert(narrative.template(tplBlock, {}, nil, 1) == "Choices:  Option B ")

        -- In storylet presentation with deterministic session draws
        relation ready(0)
        fact ready()
        storylet story_variants()
            when {ready()}
            title "Encounter"
            text "Encounter: {#variant 100} Dragon {#variant 1} Goblin {/variant}"
            choice fight effect do end end
        end

        local s = narrative.new(logic.global)
        s:seed(42)
        local p = s:present()
        local story = p.storylets[1]
        assert(string.find(story.text, "Dragon", 1, true))
    }");

    auto badState = new LuaState();
    openLibs(badState);
    rejects({ badState.doString(`narrative.formatter(123)`); }, "narrative formatter must be a function");
    rejects({ badState.doString(`narrative.template("Weather: {#variant 0} sunny {/variant}", {})`); }, "variant weight must be positive and finite");
    rejects({
        badState.doString(`narrative.template("Weather: {#variant abc} sunny {/variant}", {})`);
    }, "variant weight must be numeric");
    rejects({ badState.doString(`narrative.template("Weather: {#variant 2} sunny", {})`); }, "template variant requires {/variant}");
    rejects({ badState.doString(`
        narrative.formatter("nil", function() return "x" end)
        narrative.formatter("nil", function() return "y" end)
    `); }, "duplicate narrative formatter");
    rejects({ badState.doString(`
        narrative.seal("v1")
        narrative.formatter("nil", function() return "x" end)
    `); }, "narrative registry is sealed");

    writeln("  [PASS] custom display formatters, template weighted variants and deterministic presentation");
}

mixin UnitMain;

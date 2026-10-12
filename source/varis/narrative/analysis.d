/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.narrative.analysis;

import varis.types;
import varis.state;
import varis.table;
import varis.vm;
import varis.lib : openLibs;
import varis.exception : LuaException;
import varis.logic.world;
import varis.logic.model;
import varis.logic.query;
import varis.narrative.registry;
import varis.narrative.session;
import varis.narrative.codec;
import std.algorithm : sort;
import std.conv : to;
import std.string : startsWith, indexOf;

/// Each branch copies the reachable Lua graph, preserving cycles and aliases.
/// All retained native functions are newly installed built-ins or explicitly
/// marked context-free engine methods; arbitrary host delegates are blocked.
private class AnalysisClone {
    LuaState source;
    LuaState state;
    AnalysisBudget budget;
    size_t cloneDepth;
    LuaValue[LuaValue] values;
    World[World] worlds;
    Session[Session] sessions;
    UpValue[UpValue] upvalues;
    ContentDefinition[ContentDefinition] definitions;
    ContentInstance[ContentInstance] instances;
    ChoiceToken[ChoiceToken] tokens;

    this(LuaState source, AnalysisBudget budget) {
        this.source = source;
        this.budget = budget;
        state = new LuaState();
        openLibs(state);
        state.analysisBudget = budget;
        {
            import varis.state : vmAttention, vmSlowMode;

            vmSlowMode = true;
            vmAttention = true;
        }
        values[LuaValue(source.globals)] = LuaValue(state.globals);
        source.narrativeRegistry.copyForAnalysis(state.narrativeRegistry, &cloneValue, &cloneDefinition);
        copyTable(source.globals, state.globals);
        state.globalWorld = cloneWorld(source.globalWorld);
        state.registry = cloneValue(LuaValue(source.registry)).match!((LuaTable t) => t, _ => null);
        if (source.stringMetatable !is null)
            state.stringMetatable = cloneValue(LuaValue(source.stringMetatable)).match!((LuaTable t) => t, _ => null);
        if (source.numberMetatable !is null)
            state.numberMetatable = cloneValue(LuaValue(source.numberMetatable)).match!((LuaTable t) => t, _ => null);
    }

    void allocation() {
        if (!budget.remainingObjects)
            throw new LuaException("ANALYSIS_OBJECT_LIMIT: graph-copy budget exhausted");
        budget.remainingObjects--;
    }

    private LuaValue blocked(string name) {
        auto function_ = new LuaNativeFunction((void* pointer, LuaValue[] args) {
            auto state = cast(LuaState) pointer;
            if (state.analysisBudget !is null)
                state.analysisBudget.blockedEffects ~= name;
            throw new LuaException("ANALYSIS_EXTERNAL_EFFECT: unsupported native call '" ~ name ~ "'");
            return cast(LuaValue[])[];
        }, "analysis-blocked:" ~ name);
        function_.analysisSafeToCopy = true;
        return LuaValue(function_);
    }

    private bool allowedNative(string path) {
        return !path.startsWith("os.") && !path.startsWith("io.") && !path.startsWith("debug.") && !path.startsWith(
                "coroutine.") &&
            !path.startsWith("package.") && path != "print" && path != "load" && path != "loadfile" && path != "dofile" &&
            path != "collectgarbage" && path != "math.random" && path != "math.randomseed" && path != "narrative.analyze";
    }

    private void copyTable(LuaTable original, LuaTable copy) {
        copy.arrayPart.length = original.arrayPart.length;
        foreach (i, value; original.arrayPart)
            copy.arrayPart[i] = cloneValue(value);
        copy.clearHash();
        foreach (entry; original.hashEntries)
            copy.rawset(cloneValue(entry.key), cloneValue(entry.value));
        copy.metatable = original.metatable is null ? null : cloneValue(LuaValue(original.metatable))
            .match!((LuaTable t) => t, _ => null);
    }

    LuaValue cloneValue(LuaValue value) {
        if (cloneDepth >= 256)
            throw new LuaException("ANALYSIS_GRAPH_DEPTH_LIMIT: nested Lua graph exceeds 256 levels");
        cloneDepth++;
        scope (exit)
            cloneDepth--;
        if (isNil(value) || isNumber(value) || isBoolean(value) || isString(value) || isSymbol(value) || value.typeOf() == LuaType
                .LightUserData)
            return value;
        if (auto existing = value in values)
            return *existing;
        allocation();
        auto table = value.match!((LuaTable t) => t, _ => null);
        if (table !is null) {
            auto copy = new LuaTable();
            values[value] = LuaValue(copy);
            copyTable(table, copy);
            return LuaValue(copy);
        }
        auto function_ = value.match!((LuaFunction f) => f, _ => null);
        if (function_ !is null) {
            if (auto closure = cast(LuaClosure) function_) {
                auto copy = new LuaClosure(closure.proto);
                values[value] = LuaValue(copy);
                foreach (captured; closure.upvalues) {
                    auto upvalue = upvalues.get(captured, null);
                    if (upvalue is null) {
                        upvalue = new UpValue(null, -1);
                        upvalue.isClosed = true;
                        upvalues[captured] = upvalue;
                        upvalue.closedVal = cloneValue(captured.get());
                    }
                    copy.upvalues ~= upvalue;
                }
                return LuaValue(copy);
            }
            if (auto path = function_ in source.standardNativePaths) {
                if (*path == "require") {
                    auto replacement = new LuaNativeFunction((void* pointer, LuaValue[] args) {
                        auto state = cast(LuaState) pointer;
                        if (args.length != 1 || !isString(args[0]))
                            throw new LuaException("analysis require needs one module name");
                        auto package_ = state.getGlobal("package").match!((LuaTable t) => t, _ => null);
                        auto loaded = package_.rawget(LuaValue("loaded")).match!((LuaTable t) => t, _ => null);
                        auto module_ = loaded.rawget(args[0]);
                        if (!isNil(module_))
                            return [module_];
                        if (state.analysisBudget !is null)
                            state.analysisBudget.blockedEffects ~= "require";
                        throw new LuaException("ANALYSIS_EXTERNAL_EFFECT: analysis cannot load external modules");
                    }, "analysis-require");
                    replacement.analysisSafeToCopy = true;
                    values[value] = LuaValue(replacement);
                } else if (allowedNative(*path))
                    values[value] = LuaValue(state.standardNativeFunctions[*path]);
                else
                    values[value] = blocked(*path);
            } else if (auto native_ = cast(LuaNativeFunction) function_) {
                if (native_.analysisSafeToCopy) {
                    auto copy = new LuaNativeFunction(native_.fn, native_.name);
                    copy.analysisSafeToCopy = true;
                    values[value] = LuaValue(copy);
                } else
                    values[value] = blocked(function_.name);
            } else
                values[value] = blocked(function_.name);
            return values[value];
        }
        auto userdata = value.match!((LuaUserData u) => u, _ => null);
        if (userdata !is null) {
            if (auto world = cast(World) userdata.payload)
                values[value] = wrapWorld(cloneWorld(world));
            else if (auto session = cast(Session) userdata.payload)
                values[value] = wrapSession(cloneSession(session));
            else if (auto token = cast(ChoiceToken) userdata.payload)
                values[value] = LuaValue(new LuaUserData(cloneToken(token)));
            else if (cast(ContentRegistry) userdata.payload !is null)
                values[value] = LuaValue(new LuaUserData(state.narrativeRegistry));
            else if (auto sequence = cast(ImmutableSequence) userdata.payload) {
                auto copy = immutableSequence([]);
                values[value] = copy;
                auto payload = copy.match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
                foreach (element; sequence.values)
                    payload.values ~= cloneValue(element);
            } else if (auto record = cast(ImmutableRecord) userdata.payload) {
                auto copy = immutableRecord(null);
                values[value] = copy;
                auto payload = copy.match!((LuaUserData u) => cast(ImmutableRecord) u.payload, _ => null);
                foreach (name, element; record.fields)
                    payload.fields[name] = cloneValue(element);
            } else if (auto record = cast(BindingRecord) userdata.payload) {
                auto copy = new BindingRecord(null);
                values[value] = wrapBindingRecord(state, copy);
                foreach (name, element; record.fields)
                    copy.fields[name] = cloneValue(element);
            } else {
                // Opaque host payloads cannot be reached from pure Lua. Their
                // methods become blocked native calls, while raw identity stays distinct.
                auto copy = new LuaUserData(new Object());
                values[value] = LuaValue(copy);
                if (userdata.metatable !is null)
                    copy.metatable = cloneValue(LuaValue(userdata.metatable)).match!((LuaTable t) => t, _ => null);
            }
            return values[value];
        }
        auto thread = value.match!((LuaThread t) => t, _ => null);
        if (thread !is null) {
            auto copy = new LuaThread();
            values[value] = LuaValue(copy);
            copy.status = thread.status;
            if (thread.entryFunction !is null)
                copy.entryFunction = cloneValue(LuaValue(thread.entryFunction)).match!((LuaFunction f) => f, _ => null);
            return values[value]; // Existing continuations are never resumed by analysis.
        }
        throw new LuaException("analysis cannot copy value of type " ~ typeName(value));
    }

    ContentDefinition cloneDefinition(ContentDefinition original) {
        if (auto existing = original in definitions)
            return *existing;
        allocation();
        auto copy = new ContentDefinition();
        definitions[original] = copy;
        copy.kind = original.kind;
        copy.id = original.id;
        copy.parameters = original.parameters.dup;
        copy.incomingParameters = original.incomingParameters.dup;
        copy.groundedParameters = original.groundedParameters.dup;
        copy.titleTemplate = original.titleTemplate;
        copy.textTemplate = original.textTemplate;
        copy.fingerprint = original.fingerprint;
        copy.legacyFingerprint = original.legacyFingerprint;
        copy.availability = cloneValue(original.availability);
        copy.effect = cloneValue(original.effect);
        foreach (name, value; original.options)
            copy.options[name] = cloneValue(value);
        foreach (choice; original.choices)
            copy.choices ~= cloneDefinition(choice);
        return copy;
    }

    World cloneWorld(World original) {
        if (auto existing = original in worlds)
            return *existing;
        allocation();
        auto copy = original.cloneSnapshot();
        worlds[original] = copy;
        copy.version_ = original.version_;
        copy.persistentIdentity = original.persistentIdentity;
        foreach (name, relation; copy.relations) {
            auto sourceRelation = original.relations[name];
            relation.clearFacts();
            relation.keyIndex = null;
            relation.version_ = sourceRelation.version_;
            if (name == "quality")
                relation.validateTuple = &state.narrativeRegistry.validateQualityTuple;
            else if (sourceRelation.validateTuple !is null)
                throw new LuaException("analysis cannot reconstruct host tuple validator for '" ~ name ~ "'");
            foreach (tuple; sourceRelation.baseFacts.keys) {
                LuaValue[] fields;
                foreach (value; tuple.values)
                    fields ~= cloneValue(value);
                auto copied = RelTuple(fields);
                relation.baseFacts[copied] = true;
                if (relation.keyColumns.length)
                    relation.keyIndex[relation.tupleKey(copied)] = copied;
            }
        }
        Term term(Term input) {
            if (input.kind == TermKind.Constant)
                input.constantValue = cloneValue(input.constantValue);
            return input;
        }

        void goals(Goal[] input) {
            foreach (goal; input) {
                foreach (ref value; goal.terms)
                    value = term(value);
                goal.leftTerm = term(goal.leftTerm);
                goal.rightTerm = term(goal.rightTerm);
                if (isFunction(goal.guardFn))
                    goal.guardFn = cloneValue(goal.guardFn);
                if (isFunction(goal.aggregateExpression))
                    goal.aggregateExpression = cloneValue(goal.aggregateExpression);
                goals(goal.aggregateGoals);
            }
        }

        foreach (rule; copy.rules) {
            foreach (ref value; rule.headTerms)
                value = term(value);
            goals(rule.bodyGoals);
        }
        return copy;
    }

    Session cloneSession(Session original) {
        if (auto existing = original in sessions)
            return *existing;
        allocation();
        auto copy = Session.analysisShell(state, null);
        sessions[original] = copy;
        copy.bindAnalysisWorld(cloneWorld(original.world));
        copy.data = original.data.copy();
        foreach (name, value; original.data.periods)
            copy.data.periods[name] = cloneValue(value);
        foreach (ref event; copy.data.events)
            event.arguments = cloneValue(event.arguments);
        foreach (ref event; copy.data.scheduled)
            event.arguments = cloneValue(event.arguments);
        foreach (ref input; copy.data.replayInputs)
            input = cloneValue(input);
        copy.actionLimit = original.actionLimit;
        copy.eventLimit = original.eventLimit;
        return copy;
    }

    ContentInstance cloneInstance(ContentInstance original) {
        if (auto existing = original in instances)
            return *existing;
        auto copy = new ContentInstance();
        instances[original] = copy;
        copy.definition = cloneDefinition(original.definition);
        copy.key = original.key;
        copy.worldVersion = original.worldVersion;
        foreach (name, value; original.bindings)
            copy.bindings[name] = cloneValue(value);
        foreach (value; original.values)
            copy.values ~= cloneValue(value);
        return copy;
    }

    ChoiceToken cloneToken(ChoiceToken original) {
        if (auto existing = original in tokens)
            return *existing;
        auto copy = new ChoiceToken();
        tokens[original] = copy;
        copy.session = cloneSession(original.session);
        copy.storylet = cloneInstance(original.storylet);
        copy.choice = cloneInstance(original.choice);
        copy.deckEntry = original.deckEntry;
        copy.identity = original.identity;
        return copy;
    }
}

struct AnalysisOptions {
    size_t depth = 3;
    size_t maxNodes = 100;
    size_t maxSteps = 1_000_000;
    size_t maxObjects = 200_000;
}

private struct AnalysisNode {
    Session session;
    size_t depth;
    LuaValue[] path;
}

private LuaValue recordPath(size_t depth, LuaValue[] path, string reason) {
    return immutableRecord([
        "depth": LuaValue(cast(long) depth),
        "path": immutableSequence(path),
        "reason": LuaValue(reason)
    ]);
}

/// Explore the deterministic seeded presentation tree, not all possible random
/// outcomes or future host inputs. Budget/unsupported paths make completeness false.
LuaValue analyzeSession(Session original, AnalysisOptions options) {
    original.requireIdle();
    if (options.depth > 32 || !options.maxNodes || options.maxNodes > 10_000 || !options.maxSteps || !options
            .maxObjects)
        throw new LuaException(
                "analysis requires depth 0..32 and positive bounded node/step/object limits (nodes <= 10000)");
    auto budget = new AnalysisBudget(options.maxSteps);
    budget.remainingObjects = options.maxObjects;
    AnalysisNode[] pending;
    LuaValue[] errors, cycles, deadEnds, frontier;
    bool[string] reached;
    size_t explored, transitions, deepest;
    bool complete = true;
    try {
        auto graph = new AnalysisClone(original.state, budget);
        pending ~= AnalysisNode(graph.cloneSession(original), 0, null);
    } catch (LuaException error) {
        errors ~= recordPath(0, null, error.msg);
        complete = false;
    }
    while (pending.length) {
        if (explored >= options.maxNodes || !budget.remaining) {
            complete = false;
            foreach (node; pending)
                frontier ~= recordPath(node.depth, node.path, !budget.remaining ? "step_limit" : "node_limit");
            break;
        }
        auto node = pending[0];
        pending = pending[1 .. $];
        explored++;
        if (node.depth > deepest)
            deepest = node.depth;
        LuaValue presentation;
        try {
            presentation = node.session.present();
        } catch (LuaException error) {
            auto diagnostic = recordPath(node.depth, node.path, error.msg);
            errors ~= diagnostic;
            complete = false;
            if (error.msg.indexOf("ACTION_LIMIT") >= 0)
                cycles ~= diagnostic;
            continue;
        }
        auto stories = VM.getTable(node.session.state, presentation, LuaValue("storylets"))
            .match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
        ChoiceToken[] choices;
        foreach (story; stories.values) {
            auto id = VM.getTable(node.session.state, story, LuaValue("id")).match!((Symbol s) => s.name, _ => "");
            reached[id] = true;
            auto records = VM.getTable(node.session.state, story, LuaValue("choices"))
                .match!((LuaUserData u) => cast(ImmutableSequence) u.payload, _ => null);
            foreach (choice; records.values)
                choices ~= unwrapChoiceToken(VM.getTable(node.session.state, choice, LuaValue("token")));
        }
        if (!choices.length) {
            deadEnds ~= recordPath(node.depth, node.path, "no_presented_choices");
            continue;
        }
        if (node.depth == options.depth) {
            frontier ~= recordPath(node.depth, node.path, "depth_limit");
            complete = false;
            continue;
        }
        foreach (choice; choices) {
            if (explored + pending.length >= options.maxNodes) {
                frontier ~= recordPath(node.depth, node.path, "node_limit");
                complete = false;
                break;
            }
            auto path = node.path ~ immutableRecord([
                "storylet": LuaValue(choice.storylet.key),
                "choice": LuaValue(choice.choice.key)
            ]);
            try {
                auto graph = new AnalysisClone(node.session.state, budget);
                auto child = graph.cloneSession(node.session);
                child.choose(graph.cloneToken(choice));
                transitions++;
                pending ~= AnalysisNode(child, node.depth + 1, path);
            } catch (LuaException error) {
                auto diagnostic = recordPath(node.depth + 1, path, error.msg);
                errors ~= diagnostic;
                complete = false;
                if (error.msg.indexOf("ACTION_LIMIT") >= 0)
                    cycles ~= diagnostic;
            }
        }
    }
    LuaValue[] unreached, reachedValues, blocked;
    auto definitions = original.registry.storylets();
    definitions.sort!((a, b) => a.id < b.id);
    foreach (definition; definitions) {
        if (definition.id in reached)
            reachedValues ~= original.state.getSymbol(definition.id);
        else
            unreached ~= immutableRecord([
            "id": original.state.getSymbol(definition.id),
            "status": LuaValue("not_reached_within_scope")
        ]);
    }
    foreach (name; budget.blockedEffects)
        blocked ~= LuaValue(name);
    if (blocked.length)
        complete = false;
    return immutableRecord([
        "scope": LuaValue("seeded_presentation_tree_without_external_inputs"),
        "complete": LuaValue(complete),
        "depth_limit": LuaValue(cast(long) options.depth),
        "depth_reached": LuaValue(cast(long) deepest),
        "node_limit": LuaValue(cast(long) options.maxNodes),
        "nodes": LuaValue(cast(long) explored),
        "transitions": LuaValue(cast(long) transitions),
        "instructions": LuaValue(cast(long)(options.maxSteps - budget.remaining)),
        "reached_content": immutableSequence(reachedValues),
        "unreachable_content": immutableSequence(unreached),
        "dead_ends": immutableSequence(deadEnds),
        "action_cycles": immutableSequence(cycles),
        "cycle_classification": LuaValue("potential_cycle_or_action_budget_exhaustion"),
        "frontier": immutableSequence(frontier),
        "errors": immutableSequence(errors),
        "blocked_external_effects": immutableSequence(blocked),
        "subscriptions_copied": LuaValue(false)
    ]);
}

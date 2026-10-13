/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The world model's side of the seam with the Lua core (benchmarks/PERFORMANCE_PLAN.md, stage
/// S1): the implementation of the relational and narrative instructions, and the hooks through
/// which the executor in `varis.vm` reaches worlds and transactions without importing them.
module varis.narrative.vmops;

import std.format : format;
import std.conv : to;
import std.math : isNaN;

import varis.types;
import varis.table;
import varis.state;
import varis.opcode;
import varis.exception : LuaException;
import varis.vm;
import varis.logic.model;
import varis.logic.world;
import varis.logic.validate;
import varis.logic.query;
import varis.narrative.registry : ContentRegistry, ContentDefinition, DeckDefinition, narrativeRegistry,
    legacyFingerprintHook;

shared static this() {
    declarativeOpHook = &declarativeOp;
    worldOfValueHook = function Object(LuaValue value) { return unwrapWorld(value); };
    beginFrameScopeHook = function FrameScope(Object world) {
        return new Transaction(cast(World) cast(void*) world);
    };
}

private Goal[] instantiateGoalsStatic(LuaState state, Prototype proto, LuaClosure closure, LuaValue[] registers, scope UpValue delegate(
        int) findUp, GoalTemplate[] templates, RuleRegistration registration, ref Relation[size_t] closureRels) {
    Goal[] goals;
    foreach (gt; templates) {
        if (gt.kind == GoalKind.Aggregate) {
            auto goal = new Goal(GoalKind.Aggregate);
            goal.aggregateOp = gt.aggregateOp;
            goal.resultVariable = gt.resultVariable;
            goal.aggregateGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, gt
                    .aggregateGoals, registration, closureRels);
            goal.aggregateExpressionVariables = gt.aggregateExpressionVariables.dup;
            if (gt.aggregateExpressionProto >= 0)
                goal.aggregateExpression = VM.captureClosedValue(proto, closure, findUp, gt.aggregateExpressionProto);
            goals ~= goal;
        } else if (gt.kind == GoalKind.PositiveAtom || gt.kind == GoalKind.NegatedAtom) {
            Term[] terms;
            foreach (tt; gt.terms) {
                if (tt.kind == TermKind.Variable) {
                    terms ~= Term.makeVariable(tt.varName, tt.varId);
                } else if (tt.kind == TermKind.Constant) {
                    auto val = registers[tt.reg];
                    if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                        throw new LuaException("NaN is prohibited as a relational constant");
                    }
                    terms ~= Term.makeConstant(val);
                } else {
                    terms ~= Term.makeAnonymous();
                }
            }
            RelationRef gRef;
            if (gt.localRelReg >= 0) {
                auto lr = unwrapLocalRelation(registers[gt.localRelReg]);
                if (lr is null)
                    throw new LuaException("expected local relation");
                if (lr.arity != terms.length) {
                    throw new LuaException(format("relation '%s' expects arity %d, got %d", lr.name, lr.arity, terms
                            .length));
                }
                gRef = new RelationRef(lr.name, lr.arity, "", lr.id, true);
                closureRels[lr.id] = lr.relation;
                gRef.resolvedRelation = lr.relation;
            } else {
                World gw = (gt.worldReg == -1) ? state.globalWorld : unwrapWorld(registers[gt.worldReg]);
                auto rel = registration !is null ? registration.resolve(gw, gt.relName, gt.arity) : gw.getRelation(
                        gt.relName);
                if (rel is null) {
                    throw new LuaException(format("query references unknown relation '%s'", gt.relName));
                }
                if (rel.arity != terms.length) {
                    throw new LuaException(format("relation '%s' expects arity %d, got %d", rel.name, rel.arity, terms
                            .length));
                }
                gRef = new RelationRef(rel.name, rel.arity, gw.idText, rel.id, false);
                closureRels[rel.id] = rel;
                gRef.resolvedRelation = rel;
            }
            goals ~= (gt.kind == GoalKind.PositiveAtom)
                ? Goal.makePositiveAtom(gRef, terms) : Goal.makeNegatedAtom(gRef, terms);
        } else if (gt.kind == GoalKind.Comparison) {
            Term lTerm = (gt.leftTerm.kind == TermKind.Variable)
                ? Term.makeVariable(gt.leftTerm.varName, gt.leftTerm.varId) : Term.makeConstant(
                        registers[gt.leftTerm.reg]);
            Term rTerm = (gt.rightTerm.kind == TermKind.Variable)
                ? Term.makeVariable(gt.rightTerm.varName, gt.rightTerm.varId) : Term.makeConstant(
                        registers[gt.rightTerm.reg]);
            goals ~= Goal.makeComparison(lTerm, gt.compOp, rTerm);
        } else if (gt.kind == GoalKind.Guard) {
            auto guardValue = VM.captureClosedValue(proto, closure, findUp, gt.guardSubProtoIdx);
            goals ~= Goal.makeGuard(guardValue, gt.guardVarNames.dup, gt.guardVarIds.dup);
        }
    }

    return goals;
}

/// Declarative and narrative instructions, kept out of the main loop so that
/// frames of ordinary Lua calls stay small.
private void declarativeOp(LuaState state, LuaClosure closure, Prototype proto, LuaValue[] registers,
        scope UpValue delegate(int) findUp, Instruction instr) {
    auto op = instr.op;
    int a = instr.a;
    int b = instr.b;
    int c = instr.c;
    int sBx = instr.sBx;
    switch (op) {
    case OpCode.DefineContent:
        if (state.narrativeRegistry is null)
            state.narrativeRegistry = new ContentRegistry(state);
        ContentDefinition instantiateContent(ContentTemplate template_) {
            auto content = new ContentDefinition();
            content.kind = template_.kind;
            content.id = template_.id;
            content.parameters = template_.parameters.dup;
            content.incomingParameters = template_.incomingParameters.dup;
            content.groundedParameters = template_.groundedParameters.dup;
            content.exposed = template_.exposed.dup;
            foreach (index, name; template_.optionNames) {
                auto value = registers[template_.optionRegisters[index]];
                if ((name == "title" || name == "text" || name == "because") && value.isString)
                    value = LuaValue(state.narrativeRegistry.expandFragments(value.asString));
                content.options[name] = value;
            }
            if (template_.availabilityRegister >= 0)
                content.availability = registers[template_.availabilityRegister];
            if (template_.effectRegister >= 0)
                content.effect = registers[template_.effectRegister];
            if (template_.requirementRegister >= 0)
                content.requirement = registers[template_.requirementRegister];
            foreach (choice; template_.choices) {
                content.choices ~= instantiateContent(choice);
                content.choices[$ - 1].incomingExposed = content.exposed.dup;
            }
            import varis.narrative.fingerprint : contentFingerprint, legacyContentFingerprint;

            content.fingerprint = contentFingerprint(content);
            legacyFingerprintHook = &legacyContentFingerprint;
            return content;
        }

        state.narrativeRegistry.registerContent(instantiateContent(proto.contentTemplates[b]));
        break;
    case OpCode.DefineDeck:
        if (state.narrativeRegistry is null)
            state.narrativeRegistry = new ContentRegistry(state);
        auto configuration = registers[a].match!((LuaTable table) => table, _ => null);
        if (configuration is null)
            throw new LuaException("deck configuration must be a table");
        LuaValue previousOption, optionKey, optionValue;
        while (configuration.next(previousOption, optionKey, optionValue)) {
            previousOption = optionKey;
            if (!luaRawEqual(optionKey, LuaValue("draw")) && !luaRawEqual(optionKey, LuaValue("replacement")))
                throw new LuaException("unknown deck option");
        }
        auto draw = configuration.rawget(LuaValue("draw"));
        if (isNil(draw))
            draw = LuaValue(1L);
        if (!isInteger(draw))
            throw new LuaException("deck draw must be a positive integer");
        auto replacement = configuration.rawget(LuaValue("replacement"));
        if (isNil(replacement))
            replacement = LuaValue(true);
        if (!isBoolean(replacement))
            throw new LuaException("deck replacement must be Boolean");
        string deckName = proto.constants[b].match!((string name) => name, _ => "");
        state.narrativeRegistry.registerDeck(deckName, DeckDefinition(draw.match!((long n) => n, _ => 1L), replacement
                .match!((bool yes) => yes, _ => true)));
        break;

    case OpCode.LoadSymbol:
        string symName = proto.constants[b].match!((string s) => s, _ => "");
        registers[a] = state.getSymbol(symName);
        break;

    case OpCode.NewLocalRel:
        string lrName = proto.constants[b].match!((string s) => s, _ => "");
        World fallbackWorld = (sBx == -1) ? state.globalWorld : unwrapWorld(registers[sBx]);
        auto lr = new LocalRelation(lrName, c, fallbackWorld);
        registers[a] = wrapLocalRelation(lr);
        break;

    case OpCode.DeclRel:
        World declWorld = (a == -1) ? state.globalWorld : unwrapWorld(registers[a]);
        string relName = proto.constants[b].match!((string s) => s, _ => "");
        if (sBx > 0) {
            auto schema = proto.relationSchemas[sBx - 1];
            declWorld.declareNamedRelation(relName, schema.columns, schema.keys);
        } else
            declWorld.declareRelation(relName, c);
        break;

    case OpCode.SetFact:
    case OpCode.DeleteKey:
    case OpCode.AdjustKey:
    case OpCode.AdjustClamp:
    case OpCode.AddFact:
    case OpCode.RetractFact:
        bool isAdd = (op == OpCode.AddFact);
        LuaValue[] tupleVals;
        for (int i = 0; i < sBx; ++i) {
            auto val = registers[c + i];
            if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                throw new LuaException("NaN is prohibited in relational tuples");
            }
            tupleVals ~= val;
        }
        LuaValue delta;
        if (op == OpCode.AdjustKey || op == OpCode.AdjustClamp) {
            delta = tupleVals[$ - 1];
            tupleVals = tupleVals[0 .. $ - 1];
        }
        auto tuple = RelTuple(tupleVals);

        if (a == -2) {
            auto localRel = unwrapLocalRelation(registers[b]);
            if (localRel is null)
                throw new LuaException("expected local relation");
            if (op == OpCode.SetFact || op == OpCode.DeleteKey || op == OpCode.AdjustKey || op == OpCode.AdjustClamp)
                throw new LuaException("keyed updates require a named world relation");
            if (isAdd) {
                localRel.addFact(tuple);
            } else {
                localRel.retractFact(tuple);
            }
        } else {
            World factWorld = (a == -1) ? state.globalWorld : unwrapWorld(registers[a]);
            string factRelName = proto.constants[b].match!((string s) => s, _ => "");
            if (op == OpCode.SetFact || op == OpCode.DeleteKey || op == OpCode.AdjustKey || op == OpCode.AdjustClamp) {
                factWorld.updateFact(factRelName, tuple, op == OpCode.SetFact ? "set" : op == OpCode.DeleteKey ? "delete" : "adjust", delta,
                        op == OpCode.AdjustClamp);
            } else if (isAdd) {
                factWorld.addFact(factRelName, tuple);
            } else {
                factWorld.retractFact(factRelName, tuple);
            }
        }
        break;

    case OpCode.RegRule:
        auto rTemp = proto.ruleTemplates[b];
        auto registration = new RuleRegistration();
        // Build head terms
        Term[] headTerms;
        foreach (tt; rTemp.headTerms) {
            if (tt.kind == TermKind.Variable) {
                headTerms ~= Term.makeVariable(tt.varName, tt.varId);
            } else if (tt.kind == TermKind.Constant) {
                auto val = registers[tt.reg];
                if (isFloat(val) && isNaN(val.match!((double d) => d, _ => 0.0))) {
                    throw new LuaException("NaN is prohibited as a relational constant");
                }
                headTerms ~= Term.makeConstant(val);
            } else {
                headTerms ~= Term.makeAnonymous();
            }
        }

        Relation[size_t] bodyRelations;
        Goal[] bodyGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, rTemp.bodyGoals, registration, bodyRelations);

        // Resolve head relation
        RelationRef headRef;
        World targetWorld;
        LocalRelation targetLocalRel = null;
        bool isLocalContext = false;
        if (rTemp.headLocalRelReg >= 0) {
            targetLocalRel = unwrapLocalRelation(registers[rTemp.headLocalRelReg]);
            if (targetLocalRel is null)
                throw new LuaException("expected local relation");
            if (targetLocalRel.arity != rTemp.headArity) {
                throw new LuaException(format("relation '%s' expects arity %d, got %d", targetLocalRel.name, targetLocalRel
                        .arity, rTemp.headArity));
            }
            headRef = new RelationRef(targetLocalRel.name, targetLocalRel.arity, "", targetLocalRel.id, true);
            headRef.resolvedRelation = targetLocalRel.relation;
            targetWorld = targetLocalRel.fallbackWorld ? targetLocalRel.fallbackWorld : state.globalWorld;
            isLocalContext = true;
        } else {
            targetWorld = (rTemp.headWorldReg == -1) ? state.globalWorld : unwrapWorld(registers[rTemp.headWorldReg]);
            auto hRel = registration.resolve(targetWorld, rTemp.headRelName, rTemp.headArity);
            headRef = new RelationRef(hRel.name, hRel.arity, targetWorld.id.to!string, hRel.id, false);
            headRef.resolvedRelation = hRel;
            isLocalContext = false;
        }

        auto concreteRule = new Rule(headRef, headTerms, bodyGoals, getNextRuleId());
        concreteRule.numVariables = rTemp.numVariables;
        concreteRule.variableNames = rTemp.variableNames.dup;

        // Validation
        validateRuleSafety(concreteRule);
        validateRuleOwnership(concreteRule, targetWorld, isLocalContext);

        // Stratification check
        Relation[size_t] relMap;
        Rule[] allRules = targetWorld.rules ~ concreteRule;
        foreach (name, rel; targetWorld.relations) {
            relMap[rel.id] = rel;
        }
        if (isLocalContext) {
            collectRuleDependencies(targetLocalRel.relation, relMap, allRules);
            foreach (goal; flattenGoals(bodyGoals)) {
                if (goal.relRef !is null) {
                    collectRuleDependencies(goal.relRef.resolvedRelation, relMap, allRules);
                }
            }
        }
        foreach (world, declarations; registration.pending) {
            foreach (name, relation; declarations)
                relMap[relation.id] = relation;
        }
        computeStratification(relMap, allRules);

        // Publish
        registration.commit();
        if (isLocalContext) {
            targetLocalRel.registerRule(concreteRule);
        } else {
            targetWorld.registerRule(concreteRule);
        }
        break;

    case OpCode.MakeQuery:
        auto qTemp = proto.queryTemplates[b];
        Goal[] concreteGoals;
        Relation[size_t] closureRels;
        Rule[] closureRules;

        concreteGoals = instantiateGoalsStatic(state, proto, closure, registers, findUp, qTemp.goals, null, closureRels);

        // Safety depends only on the template's shape, so a template is checked once.
        if (!qTemp.safetyChecked) {
            validateQuerySafety(concreteGoals);
            qTemp.safetyChecked = true;
        }
        auto qIter = new QueryIterator(state, concreteGoals, qTemp.returnedVarNames, closureRels, closureRules);
        if (qTemp.planHolder is null)
            qTemp.planHolder = new PlanHolder;
        qIter.planHolder = qTemp.planHolder;
        registers[a] = createCallableQueryIterator(state, qIter);
        break;

    default:
        throw new LuaException(format("unknown opcode: %s", op));
    }
}

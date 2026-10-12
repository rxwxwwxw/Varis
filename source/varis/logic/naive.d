/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// The original evaluator: naive fixed point, nested-loop joins, bindings keyed by variable name.
/// It is the correctness reference for `varis.logic.evaluate` and runs beside it when the
/// oracle is enabled (see `logicOracleEnabled`). Do not optimize it.
module varis.logic.naive;

import varis.types;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.world;
import varis.logic.validate;
import varis.logic.evaluate : evalComparison;
import std.format : format;
import std.algorithm : canFind, sort;

/// Reference evaluation engine
struct NaiveEvaluator {
    LuaState state;

    this(LuaState state) {
        this.state = state;
    }

    /// Evaluates query goals against a dependency closure of relations and rules
    LuaValue[string][] evaluateQuery(
            Goal[] queryGoals,
            Relation[size_t] closureRels,
            Rule[] closureRules,
            string[] returnedVarNames,
            LuaValue[string] initialBindings = null
    ) {
        import varis.fiber : VarisFiber, currentLuaFiber;
        import core.thread : Fiber;

        beginNoYieldScope();
        scope (exit)
            endNoYieldScope();
        auto curFib = currentLuaFiber();
        bool prevYield = true;
        if (curFib !is null) {
            prevYield = curFib.isYieldAllowed;
            curFib.isYieldAllowed = false;
        }
        scope (exit) {
            if (curFib !is null)
                curFib.isYieldAllowed = prevYield;
        }

        // 1. Stratify relations
        auto nodeStratum = computeStratification(closureRels, closureRules);

        // 2. Group relations into strata
        int maxStratum = 0;
        foreach (_, s; nodeStratum) {
            if (s > maxStratum)
                maxStratum = s;
        }

        // 3. Initialize visible and derived facts
        bool[RelTuple][size_t] visibleFacts;

        foreach (id, rel; closureRels) {
            foreach (t; rel.factTable().rows) {
                visibleFacts[id][t] = true;
            }
        }

        // 4. Evaluate stratum by stratum
        for (int stratum = 0; stratum <= maxStratum; ++stratum) {
            Rule[] stratumRules;
            foreach (r; closureRules) {
                if (nodeStratum.get(r.headRel.relId, 0) == stratum) {
                    stratumRules ~= r;
                }
            }

            // Fixed point evaluation for this stratum
            bool changed = true;
            while (changed) {
                changed = false;
                foreach (rule; stratumRules) {
                    auto assignments = matchGoals(rule.bodyGoals, visibleFacts, closureRels);
                    size_t headId = rule.headRel.relId;

                    foreach (env; assignments) {
                        LuaValue[] headVals;
                        foreach (t; rule.headTerms) {
                            if (t.kind == TermKind.Constant) {
                                headVals ~= t.constantValue;
                            } else if (t.kind == TermKind.Variable) {
                                auto val = env.get(t.varName, luaNil());
                                headVals ~= val;
                            }
                        }
                        auto tuple = RelTuple(headVals);
                        bool inFacts = (tuple in visibleFacts.get(headId, (bool[RelTuple]).init)) !is null;
                        if (!inFacts) {
                            visibleFacts[headId][tuple] = true;
                            changed = true;
                        }
                    }
                }
            }
        }

        // 5. Evaluate the query goals with fully materialized relations
        auto queryAssignments = matchGoals(queryGoals, visibleFacts, closureRels, initialBindings);

        // 6. Project and deduplicate results
        LuaValue[string][] results;
        bool[RelTuple] seenTuples;

        // If ground query (no named returned variables)
        if (returnedVarNames.length == 0) {
            if (queryAssignments.length > 0) {
                // Exactly one empty record on success (§12.8)
                LuaValue[string] emptyRec;
                results ~= emptyRec;
            }
            return results;
        }

        foreach (env; queryAssignments) {
            LuaValue[] projVals;
            LuaValue[string] rec;
            foreach (vname; returnedVarNames) {
                auto val = env.get(vname, luaNil());
                projVals ~= val;
                rec[vname] = val;
            }
            auto tuple = RelTuple(projVals);
            if (tuple !in seenTuples) {
                seenTuples[tuple] = true;
                results ~= rec;
            }
        }

        return results;
    }

    /// Match a conjunction of goals against currently visible facts
    LuaValue[string][] matchGoals(
            Goal[] goals,
            ref bool[RelTuple][size_t] visibleFacts,
            ref Relation[size_t] closureRels,
            LuaValue[string] initialBindings = null
    ) {
        Goal[] posGoals;
        Goal[] compGoals;
        Goal[] guardGoals;
        Goal[] negGoals;
        Goal[] aggregateGoals;

        foreach (g; goals) {
            if (g.kind == GoalKind.PositiveAtom)
                posGoals ~= g;
            else if (g.kind == GoalKind.Comparison)
                compGoals ~= g;
            else if (g.kind == GoalKind.Guard)
                guardGoals ~= g;
            else if (g.kind == GoalKind.NegatedAtom)
                negGoals ~= g;
            else if (g.kind == GoalKind.Aggregate)
                aggregateGoals ~= g;
        }

        // Start with one empty candidate assignment
        LuaValue[string][] candidates = [initialBindings.dup];

        // 1. Join positive atoms
        foreach (g; posGoals) {
            LuaValue[string][] nextCandidates;
            size_t relId = g.relRef.relId;
            auto relFacts = visibleFacts.get(relId, (bool[RelTuple]).init);

            foreach (tuple, _; relFacts) {
                foreach (env; candidates) {
                    // Reject incompatible tuples before allocating a binding map.
                    bool matches = true;
                    for (size_t i = 0; i < g.terms.length; ++i) {
                        auto term = g.terms[i];
                        auto tupleVal = tuple.values[i];

                        if (term.kind == TermKind.Constant) {
                            if (!luaRawEqual(term.constantValue, tupleVal)) {
                                matches = false;
                                break;
                            }
                        } else if (term.kind == TermKind.Variable) {
                            if (auto bound = term.varName in env) {
                                if (!luaRawEqual(*bound, tupleVal)) {
                                    matches = false;
                                    break;
                                }
                            } else {
                                // Repeated variables in this atom must also agree.
                                foreach (j; 0 .. i) {
                                    if (g.terms[j].kind == TermKind.Variable &&
                                            g.terms[j].varName == term.varName &&
                                            !luaRawEqual(tuple.values[j], tupleVal)) {
                                        matches = false;
                                        break;
                                    }
                                }
                                if (!matches)
                                    break;
                            }
                        } else if (term.kind == TermKind.Anonymous) {
                            // Matches any value
                        }
                    }

                    if (matches) {
                        auto newEnv = env.dup;
                        foreach (i, term; g.terms) {
                            if (term.kind == TermKind.Variable && term.varName !in newEnv) {
                                newEnv[term.varName] = tuple.values[i];
                            }
                        }
                        nextCandidates ~= newEnv;
                    }
                }
            }
            candidates = nextCandidates;
            if (candidates.length == 0)
                return [];
        }

        // Aggregate results ground variables before ordinary filters.
        foreach (aggregate; aggregateGoals) {
            LuaValue[string][] nextCandidates;
            foreach (environment; candidates) {
                LuaValue[string] inputs;
                foreach (name; aggregate.aggregateInputs)
                    inputs[name] = environment[name];
                auto assignments = matchGoals(aggregate.aggregateGoals, visibleFacts, closureRels, inputs);
                bool[RelTuple] distinct;
                LuaValue result = LuaValue(0L);
                size_t count;
                foreach (assignment; assignments) {
                    LuaValue[] values;
                    foreach (name; aggregate.aggregateLocals)
                        values ~= assignment.get(name, luaNil());
                    auto identity = RelTuple(values);
                    if (identity in distinct)
                        continue;
                    distinct[identity] = true;
                    LuaValue value;
                    if (aggregate.aggregateOp != "count") {
                        LuaValue[] arguments;
                        foreach (name; aggregate.aggregateExpressionVariables)
                            arguments ~= assignment[name];
                        auto returned = VM.callValue(state, aggregate.aggregateExpression, arguments);
                        value = returned.length ? returned[0] : luaNil();
                    }
                    if (aggregate.aggregateOp == "sum") {
                        if (!isNumber(value))
                            throw new LuaException("sum aggregate requires numeric values");
                        result = VM.opAdd(state, result, value);
                        // Reject NaN before it reaches a result binding.
                        RelTuple([result]);
                    } else if (aggregate.aggregateOp == "min" || aggregate.aggregateOp == "max") {
                        if (!isNumber(value) && !isString(value))
                            throw new LuaException("min/max aggregate requires numbers or strings");
                        if (count == 0 || evalComparison(value, aggregate.aggregateOp == "min" ? CompareOp.Lt
                                : CompareOp.Gt, result))
                            result = value;
                    }
                    count++;
                }
                if (aggregate.aggregateOp == "count")
                    result = LuaValue(cast(long) count);
                if (count == 0 && (aggregate.aggregateOp == "min" || aggregate.aggregateOp == "max"))
                    continue;
                auto output = environment.dup;
                output[aggregate.resultVariable] = result;
                nextCandidates ~= output;
            }
            candidates = nextCandidates;
            if (!candidates.length)
                return [];
        }

        // 2. Filter with comparisons
        if (compGoals.length > 0) {
            LuaValue[string][] nextCandidates;
            foreach (env; candidates) {
                bool pass = true;
                foreach (g; compGoals) {
                    LuaValue lval = (g.leftTerm.kind == TermKind.Constant) ? g.leftTerm.constantValue
                        : env.get(g.leftTerm.varName, luaNil());
                    LuaValue rval = (g.rightTerm.kind == TermKind.Constant) ? g.rightTerm.constantValue
                        : env.get(g.rightTerm.varName, luaNil());
                    if (!evalComparison(lval, g.compOp, rval)) {
                        pass = false;
                        break;
                    }
                }
                if (pass)
                    nextCandidates ~= env;
            }
            candidates = nextCandidates;
            if (candidates.length == 0)
                return [];
        }

        // 3. Filter with procedural guards
        if (guardGoals.length > 0) {
            LuaValue[string][] nextCandidates;
            foreach (env; candidates) {
                bool pass = true;
                foreach (g; guardGoals) {
                    LuaValue[] args;
                    foreach (vname; g.guardVarNames) {
                        args ~= env.get(vname, luaNil());
                    }
                    auto res = VM.callValue(state, g.guardFn, args);
                    if (res.length == 0 || !res[0].isTruthy()) {
                        pass = false;
                        break;
                    }
                }
                if (pass)
                    nextCandidates ~= env;
            }
            candidates = nextCandidates;
            if (candidates.length == 0)
                return [];
        }

        // 4. Filter with negated atoms
        if (negGoals.length > 0) {
            LuaValue[string][] nextCandidates;
            foreach (env; candidates) {
                bool pass = true;
                foreach (g; negGoals) {
                    size_t relId = g.relRef.relId;
                    auto relFacts = visibleFacts.get(relId, (bool[RelTuple]).init);

                    LuaValue[] evalVals;
                    foreach (term; g.terms) {
                        if (term.kind == TermKind.Constant) {
                            evalVals ~= term.constantValue;
                        } else if (term.kind == TermKind.Variable) {
                            evalVals ~= env.get(term.varName, luaNil());
                        }
                    }
                    auto checkTuple = RelTuple(evalVals);
                    if (checkTuple in relFacts) {
                        pass = false; // negated goal fails because tuple exists
                        break;
                    }
                }
                if (pass)
                    nextCandidates ~= env;
            }
            candidates = nextCandidates;
        }

        return candidates;
    }
}

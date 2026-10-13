/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.logic.validate;

import varis.types;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.world;
import std.format : format;
import std.algorithm : max;
import std.conv : to;

private size_t nextAnonymousVariable;

/// Check a conjunction with explicitly grounded correlated aggregate inputs.
private bool[string] validateGoals(Goal[] goals, bool[string] seed = null) {
    auto bound = seed.dup;
    bool[string] outerNames;
    foreach (name, _; seed)
        outerNames[name] = true;
    foreach (goal; goals) {
        foreach (name; goalVariables(goal))
            outerNames[name] = true;
        if (goal.kind == GoalKind.PositiveAtom)
            foreach (term; goal.terms)
                if (term.kind == TermKind.Variable)
                    bound[term.varName] = true;
    }

    foreach (goal; goals)
        if (goal.kind == GoalKind.Aggregate) {
            if (goal.resultVariable in bound)
                throw new LuaException(format("aggregate result '?%s' must be newly bound", goal.resultVariable));
            bool[string] innerNames;
            // Anonymous occurrences still contribute distinct local assignments.
            foreach (inner; goal.aggregateGoals) {
                if (inner.kind == GoalKind.PositiveAtom)
                    foreach (ref term; inner.terms) {
                        if (term.kind == TermKind.Anonymous)
                            term = Term.makeVariable(format("@anonymous%d", nextAnonymousVariable++));
                    }
                foreach (name; goalVariables(inner))
                    innerNames[name] = true;
            }
            foreach (name; goal.aggregateExpressionVariables)
                innerNames[name] = true;
            bool[string] inputs;
            goal.aggregateInputs = [];
            goal.aggregateLocals = [];
            foreach (name, _; innerNames) {
                if (name in outerNames) {
                    if (name !in bound)
                        throw new LuaException(format(
                                "aggregate correlated input '?%s' is not grounded outside aggregate", name));
                    inputs[name] = true;
                    goal.aggregateInputs ~= name;
                } else
                    goal.aggregateLocals ~= name;
            }
            auto innerBound = validateGoals(goal.aggregateGoals, inputs);
            foreach (name; goal.aggregateExpressionVariables)
                if (name !in innerBound)
                    throw new LuaException(format("aggregate expression variable '?%s' is not grounded", name));
            bound[goal.resultVariable] = true;
        }

    foreach (goal; goals) {
        void requireBound(string name, string context) {
            if (name !in bound)
                throw new LuaException(format(
                        "variable '?%s' in %s is not bound by a positive relation atom or aggregate", name, context));
        }

        if (goal.kind == GoalKind.NegatedAtom)
            foreach (term; goal.terms) {
                if (term.kind == TermKind.Anonymous)
                    throw new LuaException("anonymous variable '?_' not permitted in negated atom");
                if (term.kind == TermKind.Variable)
                    requireBound(term.varName, "negated atom");
            }
        if (goal.kind == GoalKind.Comparison) {
            if (goal.leftTerm.kind == TermKind.Anonymous || goal.rightTerm.kind == TermKind.Anonymous)
                throw new LuaException("anonymous variable '?_' not permitted in comparison");
            if (goal.leftTerm.kind == TermKind.Variable)
                requireBound(goal.leftTerm.varName, "comparison");
            if (goal.rightTerm.kind == TermKind.Variable)
                requireBound(goal.rightTerm.varName, "comparison");
        }
        if (goal.kind == GoalKind.Guard)
            foreach (name; goal.guardVarNames)
                requireBound(name, "guard");
    }
    return bound;
}

/// Validate safety and range-restriction of a rule, including aggregate results.
void validateRuleSafety(Rule rule) {
    if (rule.headRel.resolvedRelation !is null && rule.headRel.resolvedRelation.protectedRelation)
        throw new LuaException("read-only relation cannot be a rule head: " ~ rule.headRel.name);
    if (rule.headRel.resolvedRelation !is null && rule.headRel.resolvedRelation.keyColumns.length)
        throw new LuaException(format("keyed relation '%s' cannot be a rule head", rule.headRel.name));
    bool[string] bound;
    foreach (goal; rule.bodyGoals) {
        if (goal.kind == GoalKind.PositiveAtom)
            foreach (term; goal.terms)
                if (term.kind == TermKind.Variable)
                    bound[term.varName] = true;
        if (goal.kind == GoalKind.Aggregate)
            bound[goal.resultVariable] = true;
    }
    foreach (term; rule.headTerms) {
        if (term.kind == TermKind.Anonymous)
            throw new LuaException("anonymous variable '?_' not permitted in rule head");
        if (term.kind == TermKind.Variable && term.varName !in bound)
            throw new LuaException(format(
                    "variable '?%s' in rule head is not bound by any positive relation atom or aggregate", term.varName));
    }
    validateGoals(rule.bodyGoals);
}

void validateQuerySafety(Goal[] goals) {
    validateGoals(goals);
}

/// Enforce relation ownership on a rule
void validateRuleOwnership(Rule rule, World currentWorld, bool isLocalContext) {
    if (!isLocalContext) {
        // World-owned rule: head is in currentWorld
        foreach (g; flattenGoals(rule.bodyGoals)) {
            if (g.relRef !is null) {
                if (g.relRef.isLocal) {
                    throw new LuaException("world-owned rule cannot depend on local relation");
                }
                if (g.relRef.qualifiedWorld.length > 0 && g.relRef.qualifiedWorld != currentWorld.id.to!string) {
                    throw new LuaException("cross-world rule dependencies are not permitted");
                }
            }
        }
    }
}

/// A dependency edge between relation IDs
struct DepEdge {
    size_t fromId;
    size_t toId;
    bool isNegative;
    bool computed; // strict because the rule has a computed binding (`?x := ...`)
    string fromName;
    string toName;
}

/// Compute stratification for a set of relations and rules
int[size_t] computeStratification(Relation[size_t] relMap, Rule[] allRules) {
    DepEdge[] edges;

    foreach (rule; allRules) {
        size_t headId = rule.headRel.relId;
        string headName = rule.headRel.name;
        void dependencies(Goal[] goals, bool throughAggregate = false) {
            // A computed binding can build a new value from every match, so a rule that has one
            // must not feed itself: its body relations are strictly lower than its head.
            bool computed;
            foreach (goal; goals)
                if (goal.kind == GoalKind.Aggregate && goal.aggregateOp == "value")
                    computed = true;
            foreach (goal; goals) {
                if (goal.kind == GoalKind.Aggregate)
                    dependencies(goal.aggregateGoals, true);
                if (goal.relRef !is null) {
                    bool strict = throughAggregate || goal.kind == GoalKind.NegatedAtom || computed;
                    edges ~= DepEdge(headId, goal.relRef.relId, strict, computed && !throughAggregate
                            && goal.kind != GoalKind.NegatedAtom, headName, goal.relRef.name);
                }
            }
        }

        dependencies(rule.bodyGoals);
    }

    // Tarjan's strongly connected components algorithm
    size_t[] allNodes;
    foreach (id, _; relMap) {
        allNodes ~= id;
    }

    size_t[size_t] indexMap;
    size_t[size_t] lowlinkMap;
    bool[size_t] onStack;
    size_t[] stack;
    size_t currentIndex = 1;
    size_t[][] sccs;

    // Adjacency list: fromId -> [toId]
    size_t[][size_t] adj;
    foreach (edge; edges) {
        adj[edge.fromId] ~= edge.toId;
    }

    void strongConnect(size_t v) {
        indexMap[v] = currentIndex;
        lowlinkMap[v] = currentIndex;
        currentIndex++;
        stack ~= v;
        onStack[v] = true;

        if (v in adj) {
            foreach (w; adj[v]) {
                if (w !in indexMap) {
                    strongConnect(w);
                    import std.algorithm : min;

                    lowlinkMap[v] = min(lowlinkMap[v], lowlinkMap[w]);
                } else if (w in onStack && onStack[w]) {
                    import std.algorithm : min;

                    lowlinkMap[v] = min(lowlinkMap[v], indexMap[w]);
                }
            }
        }

        if (lowlinkMap[v] == indexMap[v]) {
            size_t[] scc;
            while (true) {
                size_t w = stack[$ - 1];
                stack = stack[0 .. $ - 1];
                onStack[w] = false;
                scc ~= w;
                if (w == v)
                    break;
            }
            sccs ~= scc;
        }
    }

    foreach (node; allNodes) {
        if (node !in indexMap) {
            strongConnect(node);
        }
    }

    // Node to SCC index mapping
    size_t[size_t] nodeToScc;
    foreach (sccIdx, scc; sccs) {
        foreach (node; scc) {
            nodeToScc[node] = sccIdx;
        }
    }

    // Check for negative edges within the same SCC (negation cycle)
    foreach (edge; edges) {
        if (edge.isNegative) {
            auto fromScc = nodeToScc.get(edge.fromId, size_t.max);
            auto toScc = nodeToScc.get(edge.toId, size_t.max);
            if (fromScc == toScc) {
                if (edge.computed)
                    throw new LuaException(format(
                            "computed binding (':=') in a recursive rule cycle involving relation '%s' and '%s'",
                            edge.fromName, edge.toName));
                throw new LuaException(format(
                        "negation cycle or aggregate cycle detected involving relation '%s' and '%s'", edge.fromName, edge
                        .toName));
            }
        }
    }

    // Assign strata to SCCs (bottom-up / topological)
    int[] sccStratum = new int[sccs.length];
    foreach (ref s; sccStratum)
        s = 0;

    // Relax strata until convergence (at most |SCCs| passes)
    bool updated = true;
    size_t passes = 0;
    while (updated && passes <= sccs.length + 1) {
        updated = false;
        passes++;
        foreach (edge; edges) {
            auto uScc = nodeToScc.get(edge.fromId, size_t.max);
            auto vScc = nodeToScc.get(edge.toId, size_t.max);
            if (uScc == size_t.max || vScc == size_t.max)
                continue;

            int required = edge.isNegative ? (sccStratum[vScc] + 1) : sccStratum[vScc];
            if (sccStratum[uScc] < required) {
                sccStratum[uScc] = required;
                updated = true;
            }
        }
    }

    if (passes > sccs.length) {
        throw new LuaException("negation cycle detected");
    }

    int[size_t] nodeStratum;
    foreach (node; allNodes) {
        auto sccIdx = nodeToScc[node];
        nodeStratum[node] = sccStratum[sccIdx];
    }

    return nodeStratum;
}

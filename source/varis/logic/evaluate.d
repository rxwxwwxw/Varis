/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

/// Query and rule evaluation (benchmarks/PERFORMANCE_PLAN.md, track W).
///
/// A conjunction of goals is compiled once into a `Plan`: variables become numbered slots, the
/// positive atoms are ordered so that each one probes a hash index on the columns already bound,
/// and recursive strata are evaluated semi-naively (each round joins against the tuples the
/// previous round added). Facts are read from shared immutable `FactTable`s; nothing is copied
/// per query.
///
/// Observable behaviour follows the original evaluator in `varis.logic.naive`, which is kept as a
/// test oracle: within one conjunction the positive atoms are joined first, then aggregates,
/// comparisons, guards and negated atoms are applied, in that order, each over all surviving
/// candidates. Only the order of results, and how often a guard is called, may differ.
module varis.logic.evaluate;

import varis.types;
import varis.state;
import varis.vm;
import varis.exception : LuaException;
import varis.logic.model;
import varis.logic.world;
import varis.logic.validate;
import varis.logic.store;
import std.format : format;
import std.math : isNaN;

bool numLt(LuaValue a, LuaValue b) {
    return luaNumberLess(a, b);
}

bool numLe(LuaValue a, LuaValue b) {
    return luaNumberLessEqual(a, b);
}

/// Evaluates comparisons according to §8.4
bool evalComparison(LuaValue left, CompareOp op, LuaValue right) {
    final switch (op) {
    case CompareOp.Eq:
        return luaRawEqual(left, right);
    case CompareOp.Neq:
        return !luaRawEqual(left, right);
    case CompareOp.Lt:
        if (isNumber(left) && isNumber(right)) {
            return numLt(left, right);
        }
        if (isString(left) && isString(right)) {
            return left.match!((string a) => a, _ => "") < right.match!((string b) => b, _ => "");
        }
        throw new LuaException(format("attempt to compare %s with %s", typeName(left), typeName(right)));
    case CompareOp.Le:
        if (isNumber(left) && isNumber(right)) {
            return numLe(left, right);
        }
        if (isString(left) && isString(right)) {
            return left.match!((string a) => a, _ => "") <= right.match!((string b) => b, _ => "");
        }
        throw new LuaException(format("attempt to compare %s with %s", typeName(left), typeName(right)));
    case CompareOp.Gt:
        return evalComparison(right, CompareOp.Lt, left);
    case CompareOp.Ge:
        return evalComparison(right, CompareOp.Le, left);
    }
}

/// When set, every query is also answered by the naive evaluator and the two result sets must be
/// equal. Enabled by the environment variable `VARIS_LOGIC_ORACLE=1` (read once) or by tests.
/// Guards and aggregate expressions then run twice, so it is a test facility only.
__gshared bool logicOracleEnabled;
private __gshared bool oracleChecked;

private bool oracleActive() {
    if (!oracleChecked) {
        import core.stdc.stdlib : getenv;

        auto setting = getenv("VARIS_LOGIC_ORACLE");
        if (setting !is null && setting[0] == '1')
            logicOracleEnabled = true;
        oracleChecked = true;
    }
    return logicOracleEnabled;
}

private void rejectNaN(LuaValue value) {
    if (value.isFloat() && isNaN(value.asFloat))
        throw new LuaException("NaN is prohibited in relational tuples");
}

// ---------------------------------------------------------------------------------------------
// Plans

private enum TermOp : ubyte {
    constant, // compare the column with a constant
    bound, // compare the column with a slot bound earlier
    bind, // first occurrence of a variable: store the column in its slot
    repeat, // later occurrence in the same atom of a variable this atom binds
    anonymous
}

private struct TermStep {
    TermOp op;
    int slot = -1; // bound, bind; for a negated atom: the slot to read (-1 reads nil)
    int firstColumn; // repeat: the column that bound the variable
    LuaValue value; // constant
}

private struct AtomStep {
    int goalIndex; // position of the atom's goal in the compiled conjunction
    size_t relId;
    bool delta; // scan only the rows added by the previous round
    TermStep[] terms;
    ColumnMask mask; // columns compared with a constant or a bound slot
}

private struct Operand {
    int slot = -1; // -1 with isConstant false reads nil
    bool isConstant;
    LuaValue value;
}

private struct ComparisonStep {
    int goalIndex;
    Operand left, right;
    CompareOp op;
}

private struct GuardStep {
    int goalIndex;
    LuaValue fn;
    int[] slots;
}

private struct NegationStep {
    int goalIndex;
    size_t relId;
    TermStep[] terms; // constant, bound (slot may be -1) or anonymous
    bool hasAnonymous;
}

private struct AggregateStep {
    int goalIndex;
    Goal goal;
    Plan plan; // the aggregate's own conjunction; its inputs are bound on entry
    int[] outerInputs; // slots in the enclosing plan
    int[] innerInputs; // matching slots in `plan`
    int[] innerLocals;
    int[] innerExpression;
    int resultSlot;
}

private final class Plan {
    string[] names; // slot -> variable name
    AtomStep[] atoms;
    AggregateStep[] aggregates;
    ComparisonStep[] comparisons;
    GuardStep[] guards;
    NegationStep[] negations;
    LuaValue[] keyScratch;
    size_t goalCount;
    bool busy; // in use by an evaluation in progress: a nested query must not rebind it

    int slotOf(string name) const {
        foreach (i, existing; names)
            if (existing == name)
                return cast(int) i;
        return -1;
    }

    int addName(string name) {
        int existing = slotOf(name);
        if (existing >= 0)
            return existing;
        names ~= name;
        return cast(int) names.length - 1;
    }

    bool filtersAfterJoin() const {
        return aggregates.length || comparisons.length || guards.length || negations.length;
    }
}

/// Compiles a conjunction. `boundNames` are bound before the join starts; `extraNames` get slots
/// even when no goal mentions them; `deltaAtom` is the index, among the positive atoms in source
/// order, of the atom that reads only the previous round's tuples (-1: none).
private Plan compilePlan(Goal[] goals, const(string)[] boundNames, const(string)[] extraNames, int deltaAtom) {
    auto plan = new Plan;
    foreach (name; boundNames)
        plan.addName(name);
    plan.goalCount = goals.length;
    Goal[] positives;
    int[] positiveIndexes;
    foreach (goalIndex, goal; goals) {
        final switch (goal.kind) {
        case GoalKind.PositiveAtom:
            positives ~= goal;
            positiveIndexes ~= cast(int) goalIndex;
            break;
        case GoalKind.Aggregate:
            break;
        case GoalKind.Comparison, GoalKind.Guard, GoalKind.NegatedAtom:
            break;
        }
    }

    auto isBound = new bool[](0);
    void markBound(int slot) {
        if (isBound.length <= cast(size_t) slot)
            isBound.length = slot + 1;
        isBound[slot] = true;
    }

    bool slotBound(int slot) {
        return cast(size_t) slot < isBound.length && isBound[slot];
    }

    foreach (i; 0 .. boundNames.length)
        markBound(cast(int) i);

    // Join order: the delta atom first, then repeatedly the atom with the most columns already
    // fixed (ties keep source order). The set of matches does not depend on the order.
    auto used = new bool[positives.length];
    foreach (step; 0 .. positives.length) {
        int chosen = -1;
        if (step == 0 && deltaAtom >= 0)
            chosen = deltaAtom;
        else {
            int bestScore = -1;
            foreach (i, goal; positives) {
                if (used[i])
                    continue;
                int score;
                foreach (term; goal.terms) {
                    if (term.kind == TermKind.Constant)
                        score++;
                    else if (term.kind == TermKind.Variable) {
                        int slot = plan.slotOf(term.varName);
                        if (slot >= 0 && slotBound(slot))
                            score++;
                    }
                }
                if (score > bestScore) {
                    bestScore = score;
                    chosen = cast(int) i;
                }
            }
        }
        used[chosen] = true;
        auto goal = positives[chosen];
        AtomStep atom;
        atom.goalIndex = positiveIndexes[chosen];
        atom.relId = goal.relRef.relId;
        atom.delta = chosen == deltaAtom;
        atom.terms.length = goal.terms.length;
        int[] boundHere;
        foreach (column, term; goal.terms) {
            TermStep termStep;
            final switch (term.kind) {
            case TermKind.Constant:
                termStep.op = TermOp.constant;
                termStep.value = term.constantValue;
                if (column < 32)
                    atom.mask |= 1u << column;
                break;
            case TermKind.Anonymous:
                termStep.op = TermOp.anonymous;
                break;
            case TermKind.Variable:
                int slot = plan.addName(term.varName);
                termStep.slot = slot;
                if (slotBound(slot)) {
                    termStep.op = TermOp.bound;
                    if (column < 32)
                        atom.mask |= 1u << column;
                } else {
                    termStep.op = TermOp.bind;
                    foreach (earlier; 0 .. column)
                        if (atom.terms[earlier].op == TermOp.bind && atom.terms[earlier].slot == slot) {
                            termStep.op = TermOp.repeat;
                            termStep.firstColumn = cast(int) earlier;
                            break;
                        }
                    if (termStep.op == TermOp.bind)
                        boundHere ~= slot;
                }
                break;
            }
            atom.terms[column] = termStep;
        }
        foreach (slot; boundHere)
            markBound(slot);
        plan.atoms ~= atom;
    }

    Operand operand(Term term) {
        Operand result;
        if (term.kind == TermKind.Constant) {
            result.isConstant = true;
            result.value = term.constantValue;
        } else
            result.slot = plan.addName(term.varName);
        return result;
    }

    foreach (goalIndex, goal; goals) {
        if (goal.kind != GoalKind.Aggregate)
            continue;
        AggregateStep step;
        step.goalIndex = cast(int) goalIndex;
        step.goal = goal;
        step.plan = compilePlan(goal.aggregateGoals, goal.aggregateInputs,
                goal.aggregateLocals ~ goal.aggregateExpressionVariables, -1);
        foreach (name; goal.aggregateInputs) {
            step.outerInputs ~= plan.addName(name);
            step.innerInputs ~= step.plan.slotOf(name);
        }
        foreach (name; goal.aggregateLocals)
            step.innerLocals ~= step.plan.slotOf(name);
        foreach (name; goal.aggregateExpressionVariables)
            step.innerExpression ~= step.plan.slotOf(name);
        step.resultSlot = plan.addName(goal.resultVariable);
        plan.aggregates ~= step;
    }
    foreach (goalIndex, goal; goals) {
        if (goal.kind == GoalKind.Comparison) {
            ComparisonStep step;
            step.goalIndex = cast(int) goalIndex;
            step.left = operand(goal.leftTerm);
            step.right = operand(goal.rightTerm);
            step.op = goal.compOp;
            plan.comparisons ~= step;
        } else if (goal.kind == GoalKind.Guard) {
            GuardStep step;
            step.goalIndex = cast(int) goalIndex;
            step.fn = goal.guardFn;
            foreach (name; goal.guardVarNames)
                step.slots ~= plan.addName(name);
            plan.guards ~= step;
        } else if (goal.kind == GoalKind.NegatedAtom) {
            NegationStep step;
            step.goalIndex = cast(int) goalIndex;
            step.relId = goal.relRef.relId;
            foreach (term; goal.terms) {
                TermStep termStep;
                if (term.kind == TermKind.Constant) {
                    termStep.op = TermOp.constant;
                    termStep.value = term.constantValue;
                } else if (term.kind == TermKind.Variable) {
                    termStep.op = TermOp.bound;
                    termStep.slot = plan.addName(term.varName);
                } else {
                    termStep.op = TermOp.anonymous;
                    step.hasAnonymous = true;
                }
                step.terms ~= termStep;
            }
            plan.negations ~= step;
        }
    }
    foreach (name; extraNames)
        plan.addName(name);
    size_t widest;
    foreach (ref atom; plan.atoms)
        if (atom.terms.length > widest)
            widest = atom.terms.length;
    foreach (ref negation; plan.negations)
        if (negation.terms.length > widest)
            widest = negation.terms.length;
    plan.keyScratch = new LuaValue[widest];
    return plan;
}

/// Points a plan compiled for one instance of a query template at another instance of the same
/// template: same shape, possibly different relations (a cloned world) and constants. Returns
/// false, leaving the plan unusable, when the shapes differ.
private bool rebindPlan(Plan plan, Goal[] goals) {
    if (plan.goalCount != goals.length)
        return false;
    static bool rebindTerms(TermStep[] steps, Term[] terms) {
        if (steps.length != terms.length)
            return false;
        foreach (i, ref step; steps) {
            bool constant = terms[i].kind == TermKind.Constant;
            if (constant != (step.op == TermOp.constant))
                return false;
            if (constant)
                step.value = terms[i].constantValue;
        }
        return true;
    }

    static bool rebindOperand(ref Operand operand, Term term) {
        if ((term.kind == TermKind.Constant) != operand.isConstant)
            return false;
        if (operand.isConstant)
            operand.value = term.constantValue;
        return true;
    }

    foreach (ref atom; plan.atoms) {
        auto goal = goals[atom.goalIndex];
        if (goal.kind != GoalKind.PositiveAtom || !rebindTerms(atom.terms, goal.terms))
            return false;
        atom.relId = goal.relRef.relId;
    }
    foreach (ref step; plan.negations) {
        auto goal = goals[step.goalIndex];
        if (goal.kind != GoalKind.NegatedAtom || !rebindTerms(step.terms, goal.terms))
            return false;
        step.relId = goal.relRef.relId;
    }
    foreach (ref step; plan.comparisons) {
        auto goal = goals[step.goalIndex];
        if (goal.kind != GoalKind.Comparison || goal.compOp != step.op
                || !rebindOperand(step.left, goal.leftTerm) || !rebindOperand(step.right, goal.rightTerm))
            return false;
    }
    foreach (ref step; plan.guards) {
        auto goal = goals[step.goalIndex];
        if (goal.kind != GoalKind.Guard || goal.guardVarNames.length != step.slots.length)
            return false;
        step.fn = goal.guardFn;
    }
    foreach (ref step; plan.aggregates) {
        auto goal = goals[step.goalIndex];
        if (goal.kind != GoalKind.Aggregate || !rebindPlan(step.plan, goal.aggregateGoals))
            return false;
        step.goal = goal;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Execution

/// Row range of one table that a delta atom scans.
private struct DeltaRange {
    size_t from, to;
}

/// Candidate bindings of one conjunction, stored flat: `width` values per candidate.
private struct Candidates {
    LuaValue[] values;
    size_t count;
    size_t width;

    void add(const(LuaValue)[] slots) {
        size_t start = count * width;
        if (start + width > values.length) {
            size_t capacity = values.length < 64 ? 64 : values.length * 2;
            if (capacity < start + width)
                capacity = start + width;
            auto grown = new LuaValue[capacity];
            grown[0 .. start] = values[0 .. start];
            values = grown;
        }
        values[start .. start + width] = cast(LuaValue[]) slots[];
        ++count;
    }

    LuaValue[] at(size_t index) {
        return values[index * width .. (index + 1) * width];
    }
}

private struct Executor {
    LuaState state;
    FactTable[size_t] tables;
    DeltaRange[size_t] deltas;

    /// Calls `leaf` once for every way of matching the plan's positive atoms. `slots` holds the
    /// current bindings and is reused between calls.
    void join(Plan plan, LuaValue[] slots, scope void delegate() leaf) {
        joinFrom(plan, 0, slots, leaf);
    }

    private void joinFrom(Plan plan, size_t depth, LuaValue[] slots, scope void delegate() leaf) {
        if (depth == plan.atoms.length) {
            leaf();
            return;
        }
        auto atom = &plan.atoms[depth];
        auto tablePointer = atom.relId in tables;
        if (tablePointer is null)
            return;
        auto table = *tablePointer;
        auto rows = table.rows;
        auto terms = atom.terms;

        void tryRow(ref const RelTuple row) {
            auto values = row.values;
            if (values.length != terms.length)
                return;
            foreach (column, ref term; terms) {
                final switch (term.op) {
                case TermOp.constant:
                    if (!luaRawEqual(term.value, values[column]))
                        return;
                    break;
                case TermOp.bound:
                    if (!luaRawEqual(slots[term.slot], values[column]))
                        return;
                    break;
                case TermOp.repeat:
                    if (!luaRawEqual(values[term.firstColumn], values[column]))
                        return;
                    break;
                case TermOp.bind, TermOp.anonymous:
                    break;
                }
            }
            foreach (column, ref term; terms)
                if (term.op == TermOp.bind)
                    slots[term.slot] = values[column];
            joinFrom(plan, depth + 1, slots, leaf);
        }

        if (atom.delta) {
            auto range = atom.relId in deltas;
            if (range is null)
                return;
            foreach (i; range.from .. range.to)
                tryRow(rows[i]);
            return;
        }
        if (atom.mask == 0 || rows.length < 8) {
            foreach (ref row; rows)
                tryRow(row);
            return;
        }
        auto index = table.index(atom.mask);
        size_t hash = 0x9e3779b97f4a7c15UL;
        size_t limit = terms.length < 32 ? terms.length : 32;
        foreach (column; 0 .. limit) {
            if (!(atom.mask & (1u << column)))
                continue;
            auto term = &terms[column];
            hash = (hash * 31) ^ (term.op == TermOp.constant ? term.value.toHash() : slots[term.slot].toHash());
        }
        hash ^= hash >> 33;
        hash *= 0xff51afd7ed558ccdUL;
        hash ^= hash >> 33;
        for (int at = index.first(hash); at != 0; at = index.next[at - 1])
            tryRow(rows[at - 1]);
    }

    /// All bindings satisfying the plan, starting from `initial` (one value per slot).
    Candidates match(Plan plan, LuaValue[] initial) {
        Candidates candidates;
        candidates.width = plan.names.length;
        auto slots = new LuaValue[plan.names.length];
        slots[0 .. initial.length] = initial[];
        join(plan, slots, { candidates.add(slots); });
        if (candidates.count == 0 || !plan.filtersAfterJoin())
            return candidates;
        return filter(plan, candidates);
    }

    /// Aggregates, comparisons, guards and negated atoms, each applied to every candidate before
    /// the next kind starts (the order of the naive evaluator).
    Candidates filter(Plan plan, Candidates candidates) {
        foreach (ref aggregate; plan.aggregates) {
            Candidates next;
            next.width = candidates.width;
            foreach (c; 0 .. candidates.count) {
                auto slots = candidates.at(c);
                auto initial = new LuaValue[aggregate.plan.names.length];
                foreach (i, outer; aggregate.outerInputs)
                    initial[aggregate.innerInputs[i]] = slots[outer];
                auto assignments = match(aggregate.plan, initial);
                auto op = aggregate.goal.aggregateOp;
                auto distinct = new FactTable(cast(int) aggregate.innerLocals.length);
                LuaValue result = LuaValue(0L);
                size_t count;
                foreach (a; 0 .. assignments.count) {
                    auto assignment = assignments.at(a);
                    auto identity = new LuaValue[aggregate.innerLocals.length];
                    foreach (i, slot; aggregate.innerLocals) {
                        identity[i] = slot >= 0 ? assignment[slot] : luaNil();
                        rejectNaN(identity[i]);
                    }
                    RelTuple identityTuple;
                    identityTuple.values = identity;
                    if (!distinct.insert(identityTuple))
                        continue;
                    LuaValue value;
                    if (op != "count") {
                        LuaValue[] arguments;
                        foreach (slot; aggregate.innerExpression)
                            arguments ~= assignment[slot];
                        auto returned = VM.callValue(state, aggregate.goal.aggregateExpression, arguments);
                        value = returned.length ? returned[0] : luaNil();
                    }
                    if (op == "value") {
                        // A computed binding (`?x := expression`): one assignment, no goals.
                        result = value;
                        rejectNaN(result);
                    } else if (op == "sum") {
                        if (!isNumber(value))
                            throw new LuaException("sum aggregate requires numeric values");
                        result = VM.opAdd(state, result, value);
                        // Reject NaN before it reaches a result binding.
                        rejectNaN(result);
                    } else if (op == "min" || op == "max") {
                        if (!isNumber(value) && !isString(value))
                            throw new LuaException("min/max aggregate requires numbers or strings");
                        if (count == 0 || evalComparison(value, op == "min" ? CompareOp.Lt : CompareOp.Gt, result))
                            result = value;
                    }
                    count++;
                }
                if (op == "count")
                    result = LuaValue(cast(long) count);
                if (count == 0 && (op == "min" || op == "max"))
                    continue;
                next.add(slots);
                next.at(next.count - 1)[aggregate.resultSlot] = result;
            }
            candidates = next;
            if (!candidates.count)
                return candidates;
        }

        if (plan.comparisons.length) {
            Candidates next;
            next.width = candidates.width;
            foreach (c; 0 .. candidates.count) {
                auto slots = candidates.at(c);
                bool pass = true;
                foreach (ref step; plan.comparisons) {
                    LuaValue left = step.left.isConstant ? step.left.value : step.left.slot >= 0 ? slots[step.left.slot] : luaNil();
                    LuaValue right = step.right.isConstant ? step.right.value : step.right.slot >= 0 ? slots[step
                            .right.slot] : luaNil();
                    if (!evalComparison(left, step.op, right)) {
                        pass = false;
                        break;
                    }
                }
                if (pass)
                    next.add(slots);
            }
            candidates = next;
            if (!candidates.count)
                return candidates;
        }

        if (plan.guards.length) {
            Candidates next;
            next.width = candidates.width;
            foreach (c; 0 .. candidates.count) {
                auto slots = candidates.at(c);
                bool pass = true;
                foreach (ref step; plan.guards) {
                    LuaValue[] arguments;
                    foreach (slot; step.slots)
                        arguments ~= slots[slot];
                    auto returned = VM.callValue(state, step.fn, arguments);
                    if (returned.length == 0 || !returned[0].isTruthy()) {
                        pass = false;
                        break;
                    }
                }
                if (pass)
                    next.add(slots);
            }
            candidates = next;
            if (!candidates.count)
                return candidates;
        }

        if (plan.negations.length) {
            Candidates next;
            next.width = candidates.width;
            foreach (c; 0 .. candidates.count) {
                auto slots = candidates.at(c);
                bool pass = true;
                foreach (ref step; plan.negations) {
                    auto key = plan.keyScratch[0 .. step.terms.length];
                    foreach (i, ref term; step.terms) {
                        if (term.op == TermOp.constant)
                            key[i] = term.value;
                        else if (term.op == TermOp.bound)
                            key[i] = slots[term.slot];
                        else
                            continue;
                        rejectNaN(key[i]);
                    }
                    // The naive evaluator drops anonymous terms from the tuple it looks up, so a
                    // negated atom containing one never finds a match.
                    if (step.hasAnonymous)
                        continue;
                    auto table = step.relId in tables;
                    if (table !is null && table.contains(key)) {
                        pass = false;
                        break;
                    }
                }
                if (pass)
                    next.add(slots);
            }
            candidates = next;
        }
        return candidates;
    }
}

private struct HeadStep {
    bool isConstant;
    LuaValue value;
    int slot;
}

/// A rule prepared for evaluation: its head projection and one plan per delta position.
private final class RulePlan {
    HeadStep[] head;
    Plan full;
    Plan[] byDelta; // indexed by positive atom, compiled on first use
    size_t[] positiveRelIds; // relation of each positive atom, in source order
    Goal[] body_;
    string[] headNames;

    this(Rule rule) {
        body_ = rule.bodyGoals;
        foreach (term; rule.headTerms)
            if (term.kind == TermKind.Variable)
                headNames ~= term.varName;
        foreach (goal; rule.bodyGoals)
            if (goal.kind == GoalKind.PositiveAtom)
                positiveRelIds ~= goal.relRef.relId;
        byDelta.length = positiveRelIds.length;
        full = compilePlan(body_, null, headNames, -1);
        head = headFor(rule, full);
    }

    static HeadStep[] headFor(Rule rule, Plan plan) {
        HeadStep[] steps;
        foreach (term; rule.headTerms) {
            HeadStep step;
            if (term.kind == TermKind.Constant) {
                step.isConstant = true;
                step.value = term.constantValue;
            } else if (term.kind == TermKind.Variable)
                step.slot = plan.slotOf(term.varName);
            else
                continue; // the naive evaluator skips anonymous head terms
            steps ~= step;
        }
        return steps;
    }

    Plan deltaPlan(Rule rule, size_t atom) {
        if (byDelta[atom] is null)
            byDelta[atom] = compilePlan(body_, null, headNames, cast(int) atom);
        return byDelta[atom];
    }
}

/// Derived relations of recently evaluated closures (stage W4). An entry is keyed by the identity
/// of the rules and of the immutable base tables they read, so it is valid exactly as long as
/// a query presents the same rules over the same facts: a write replaces a relation's table and
/// the key no longer matches. Closures that call Lua (guards, aggregate expressions) are not
/// cached, so caching never changes how often author code runs.
private final class DerivedCache {
    static struct Entry {
        void*[] signature;
        FactTable[] heads; // one per distinct head relation, in order of first appearance
    }

    Entry[32] entries;
    size_t nextVictim;

    FactTable[] find(void*[] signature) {
        foreach (ref entry; entries)
            if (entry.signature.length == signature.length && entry.signature == signature)
                return entry.heads;
        return null;
    }

    void store(void*[] signature, FactTable[] heads) {
        entries[nextVictim] = Entry(signature, heads);
        nextVictim = (nextVictim + 1) % entries.length;
    }
}

private bool callsLua(Goal[] goals) {
    foreach (goal; goals) {
        if (goal.kind == GoalKind.Guard)
            return true;
        if (goal.kind == GoalKind.Aggregate && (!isNil(goal.aggregateExpression) || callsLua(goal.aggregateGoals)))
            return true;
    }
    return false;
}

/// Logical deduction and query evaluation engine
struct Evaluator {
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
            LuaValue[string] initialBindings = null,
            PlanHolder planHolder = null
    ) {
        auto results = evaluate(queryGoals, closureRels, closureRules, returnedVarNames, initialBindings, planHolder);
        if (oracleActive()) {
            import varis.logic.naive : NaiveEvaluator;

            auto expected = NaiveEvaluator(state).evaluateQuery(queryGoals, closureRels, closureRules,
                    returnedVarNames, initialBindings);
            compareWithOracle(results, expected, returnedVarNames);
        }
        return results;
    }

    private static void compareWithOracle(LuaValue[string][] actual, LuaValue[string][] expected, string[] names) {
        if (actual.length != expected.length)
            throw new LuaException(format("logic oracle mismatch: %d results, the naive evaluator has %d",
                    actual.length, expected.length));
        auto seen = new FactTable(cast(int) names.length);
        foreach (record; expected) {
            RelTuple tuple;
            foreach (name; names)
                tuple.values ~= record.get(name, luaNil());
            seen.insert(tuple);
        }
        foreach (record; actual) {
            LuaValue[] values;
            foreach (name; names)
                values ~= record.get(name, luaNil());
            if (!seen.contains(values))
                throw new LuaException("logic oracle mismatch: a result is missing from the naive evaluator's set");
        }
    }

    private LuaValue[string][] evaluate(
            Goal[] queryGoals,
            Relation[size_t] closureRels,
            Rule[] closureRules,
            string[] returnedVarNames,
            LuaValue[string] initialBindings,
            PlanHolder planHolder
    ) {
        import varis.fiber : VarisFiber, currentLuaFiber;

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

        Executor executor;
        executor.state = state;
        engineCounters.queries++;

        // Base facts are shared tables. A relation that some rule derives into gets an open table
        // that starts with its base facts.
        bool[size_t] isHead;
        foreach (rule; closureRules)
            isHead[rule.headRel.relId] = true;
        foreach (id, relation; closureRels) {
            auto base = relation.factTable();
            if (id in isHead) {
                auto open = new FactTable(relation.arity);
                open.rows = base.rows.dup;
                engineCounters.factsCopied += base.rows.length;
                executor.tables[id] = open;
            } else
                executor.tables[id] = base;
        }
        foreach (rule; closureRules)
            if (rule.headRel.relId !in executor.tables)
                executor.tables[rule.headRel.relId] = new FactTable(rule.headRel.arity);

        // Derived relations: reuse a cached materialization when the same rules read the same
        // tables, otherwise evaluate and (if no author code is involved) publish the result.
        size_t[] headIds;
        foreach (rule; closureRules) {
            bool known;
            foreach (id; headIds)
                if (id == rule.headRel.relId) {
                    known = true;
                    break;
                }
            if (!known)
                headIds ~= rule.headRel.relId;
        }
        DerivedCache cache;
        void*[] signature;
        bool cacheable = closureRules.length != 0 && state !is null;
        if (cacheable) {
            foreach (rule; closureRules) {
                if (callsLua(rule.bodyGoals)) {
                    cacheable = false;
                    break;
                }
                signature ~= cast(void*)(rule.origin is null ? rule : rule.origin);
                void table(size_t relId) {
                    auto relation = relId in closureRels;
                    signature ~= relation is null ? null : cast(void*) relation.factTable();
                }

                table(rule.headRel.relId);
                foreach (goal; flattenGoals(rule.bodyGoals))
                    if (goal.relRef !is null)
                        table(goal.relRef.relId);
            }
        }
        bool derivedReady;
        if (cacheable) {
            cache = cast(DerivedCache) state.logicCache;
            if (cache is null) {
                cache = new DerivedCache;
                state.logicCache = cache;
            }
            auto cached = cache.find(signature);
            if (cached !is null) {
                foreach (i, id; headIds)
                    executor.tables[id] = cached[i];
                derivedReady = true;
                engineCounters.derivedCacheHits++;
            }
        }

        if (closureRules.length && !derivedReady) {
            auto nodeStratum = computeStratification(closureRels, closureRules);
            int maxStratum = 0;
            foreach (_, s; nodeStratum)
                if (s > maxStratum)
                    maxStratum = s;
            for (int stratum = 0; stratum <= maxStratum; ++stratum) {
                Rule[] stratumRules;
                foreach (rule; closureRules)
                    if (nodeStratum.get(rule.headRel.relId, 0) == stratum)
                        stratumRules ~= rule;
                if (stratumRules.length)
                    evaluateStratum(executor, stratumRules);
            }
            if (cacheable) {
                FactTable[] heads;
                foreach (id; headIds) {
                    executor.tables[id].frozen = true;
                    heads ~= executor.tables[id];
                }
                cache.store(signature, heads);
            }
        }

        // The query itself, over fully materialized relations.
        // A query made from a template reuses the template's plan, re-pointed at this instance's
        // relations and constants. A nested query from the same template (a guard that queries)
        // finds the plan busy and compiles its own.
        Plan plan;
        if (planHolder !is null && initialBindings.length == 0) {
            plan = cast(Plan) planHolder.plan;
            if (plan !is null && (plan.busy || !rebindPlan(plan, queryGoals))) {
                if (!plan.busy)
                    planHolder.plan = null;
                plan = null;
            }
            if (plan is null) {
                plan = compilePlan(queryGoals, null, returnedVarNames, -1);
                if (planHolder.plan is null)
                    planHolder.plan = plan;
            }
        } else
            plan = compilePlan(queryGoals, initialBindings.keys, returnedVarNames, -1);
        bool wasBusy = plan.busy;
        plan.busy = true;
        scope (exit)
            plan.busy = wasBusy;
        auto initial = new LuaValue[plan.names.length];
        foreach (name, value; initialBindings)
            initial[plan.slotOf(name)] = value;
        auto candidates = executor.match(plan, initial);

        LuaValue[string][] results;
        if (returnedVarNames.length == 0) {
            if (candidates.count > 0) {
                // Exactly one empty record on success (§12.8)
                LuaValue[string] emptyRec;
                results ~= emptyRec;
            }
            return results;
        }
        auto slots = new int[returnedVarNames.length];
        foreach (i, name; returnedVarNames)
            slots[i] = plan.slotOf(name);
        auto seen = new FactTable(cast(int) returnedVarNames.length);
        foreach (c; 0 .. candidates.count) {
            auto row = candidates.at(c);
            auto projected = new LuaValue[returnedVarNames.length];
            foreach (i, slot; slots) {
                projected[i] = slot >= 0 ? row[slot] : luaNil();
                rejectNaN(projected[i]);
            }
            RelTuple tuple;
            tuple.values = projected;
            if (!seen.insert(tuple))
                continue;
            LuaValue[string] record;
            foreach (i, name; returnedVarNames)
                record[name] = projected[i];
            results ~= record;
        }
        return results;
    }

    /// Semi-naive fixed point of the rules whose heads lie in one stratum.
    private void evaluateStratum(ref Executor executor, Rule[] rules) {
        auto plans = new RulePlan[rules.length];
        bool[size_t] growing; // relations derived in this stratum
        foreach (i, rule; rules) {
            plans[i] = new RulePlan(rule);
            growing[rule.headRel.relId] = true;
        }

        RelTuple[] pending;
        LuaValue[] headScratch;

        void run(Rule rule, RulePlan rulePlan, Plan plan) {
            auto table = executor.tables[rule.headRel.relId];
            auto head = plan is rulePlan.full ? rulePlan.head : RulePlan.headFor(rule, plan);
            if (headScratch.length < head.length)
                headScratch.length = head.length;
            auto scratch = headScratch[0 .. head.length];
            pending.length = 0;
            pending.assumeSafeAppend();

            void emit(const(LuaValue)[] slots) {
                foreach (i, ref step; head) {
                    scratch[i] = step.isConstant ? step.value : step.slot >= 0 ? cast(LuaValue) slots[step.slot]
                        : luaNil();
                    rejectNaN(scratch[i]);
                }
                if (table.contains(scratch))
                    return;
                RelTuple tuple;
                tuple.values = scratch.dup;
                pending ~= tuple;
            }

            auto slots = new LuaValue[plan.names.length];
            if (!plan.filtersAfterJoin())
                executor.join(plan, slots, { emit(slots); });
            else {
                auto candidates = executor.match(plan, null);
                foreach (c; 0 .. candidates.count)
                    emit(candidates.at(c));
            }
            // Inserted only now: the join above must not see a table change under it.
            engineCounters.ruleFirings++;
            foreach (tuple; pending)
                if (table.insert(tuple))
                    engineCounters.tuplesDerived++;
        }

        size_t[size_t] roundStart;
        foreach (id, _; growing)
            roundStart[id] = executor.tables[id].rows.length;
        foreach (i, rule; rules)
            run(rule, plans[i], plans[i].full);

        while (true) {
            // The rows each relation gained in the previous round are this round's deltas.
            bool any;
            executor.deltas = null;
            foreach (id, _; growing) {
                size_t end = executor.tables[id].rows.length;
                if (end > roundStart[id]) {
                    executor.deltas[id] = DeltaRange(roundStart[id], end);
                    any = true;
                }
                roundStart[id] = end;
            }
            if (!any)
                break;
            foreach (i, rule; rules) {
                foreach (atom, relId; plans[i].positiveRelIds)
                    if (relId in executor.deltas)
                        run(rule, plans[i], plans[i].deltaPlan(rule, atom));
            }
        }
        executor.deltas = null;
    }
}

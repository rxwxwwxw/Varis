/*
** Lua - A Scripting Language
** Lua.org, PUC-Rio, Brazil (http://www.lua.org)
**
** Varis - a Lua 5.4 derivative, written in D
** Copyright (C) 1994-2026 Lua.org, PUC-Rio.
** Copyright (C) 2026 Varis contributors.
** See LICENSE for license details.
*/

module varis.logic.model;

import varis.types;
import varis.exception : LuaException;
import varis.logic.world : Relation;
import std.format : format;
import std.math : isNaN;

/// A relational tuple of fixed arity with value semantics and NaN rejection.
struct RelTuple {
    LuaValue[] values;

    this(LuaValue[] vals) {
        foreach (size_t idx, v; vals) {
            if (v.isFloat()) {
                double d = v.match!((double x) => x, _ => 0.0);
                if (isNaN(d)) {
                    throw new LuaException("NaN is prohibited in relational tuples");
                }
            }
        }
        this.values = vals.dup;
    }

    size_t length() const @safe pure nothrow {
        return values.length;
    }

    bool opEquals(ref const RelTuple rhs) const {
        if (values.length != rhs.values.length)
            return false;
        foreach (size_t i; 0 .. values.length) {
            if (!luaRawEqual(values[i], rhs.values[i]))
                return false;
        }
        return true;
    }

    bool opEquals(const RelTuple rhs) const {
        return opEquals(rhs);
    }

    size_t toHash() const nothrow @trusted {
        size_t h = values.length;
        foreach (ref v; values) {
            h = (h * 31) ^ v.toHash();
        }
        return h;
    }

    string toString() const {
        import std.array : appender;

        auto app = appender!string();
        app.put("(");
        foreach (i, v; values) {
            if (i > 0)
                app.put(", ");
            app.put(toLuaString(v));
        }
        app.put(")");
        return app.data;
    }
}

/// Term kind for relational patterns
enum TermKind {
    Constant,
    Variable,
    Anonymous
}

/// A term appearing in a relational goal or head
struct Term {
    TermKind kind;
    LuaValue constantValue;
    string varName;
    int varId = -1; // Allocated ID per rule/query

    static Term makeConstant(LuaValue val) {
        if (val.isFloat()) {
            double d = val.match!((double x) => x, _ => 0.0);
            if (isNaN(d)) {
                throw new LuaException("NaN is prohibited as a relational constant");
            }
        }
        Term t;
        t.kind = TermKind.Constant;
        t.constantValue = val;
        return t;
    }

    static Term makeVariable(string name, int id = -1) {
        Term t;
        t.kind = TermKind.Variable;
        t.varName = name;
        t.varId = id;
        return t;
    }

    static Term makeAnonymous() {
        Term t;
        t.kind = TermKind.Anonymous;
        return t;
    }
}

/// Comparison operator
enum CompareOp {
    Eq,
    Neq,
    Lt,
    Le,
    Gt,
    Ge
}

/// Kind of goal in rule or query body
enum GoalKind {
    PositiveAtom,
    NegatedAtom,
    Comparison,
    Guard,
    Aggregate
}

/// Unique reference to a relation
class RelationRef {
    string name;
    string qualifiedWorld; // optional world qualifier expression or name
    int arity;
    size_t relId; // bound relation ID if resolved
    bool isLocal;
    // Retain lexical dependencies by reachability, including escaped local rules.
    Relation resolvedRelation;

    this(string name, int arity, string qualifiedWorld = "", size_t relId = 0, bool isLocal = false) {
        this.name = name;
        this.arity = arity;
        this.qualifiedWorld = qualifiedWorld;
        this.relId = relId;
        this.isLocal = isLocal;
    }
}

/// Goal in a rule or query
class Goal {
    GoalKind kind;
    RelationRef relRef;
    Term[] terms;

    // Comparison goal
    Term leftTerm;
    CompareOp compOp;
    Term rightTerm;

    // Aggregate subqueries retain their own local variables.
    string aggregateOp;
    string resultVariable;
    Goal[] aggregateGoals;
    string[] aggregateInputs;
    string[] aggregateLocals;
    LuaValue aggregateExpression;
    string[] aggregateExpressionVariables;

    // Guard goal
    LuaValue guardFn; // callable Lua function (closure)
    string[] guardVarNames; // logic variable names passed to guard
    int[] guardVarIds;

    this(GoalKind kind) {
        this.kind = kind;
    }

    static Goal makePositiveAtom(RelationRef relRef, Term[] terms) {
        auto g = new Goal(GoalKind.PositiveAtom);
        g.relRef = relRef;
        g.terms = terms;
        return g;
    }

    static Goal makeNegatedAtom(RelationRef relRef, Term[] terms) {
        auto g = new Goal(GoalKind.NegatedAtom);
        g.relRef = relRef;
        g.terms = terms;
        return g;
    }

    static Goal makeComparison(Term left, CompareOp op, Term right) {
        auto g = new Goal(GoalKind.Comparison);
        g.leftTerm = left;
        g.compOp = op;
        g.rightTerm = right;
        return g;
    }

    static Goal makeGuard(LuaValue guardFn, string[] varNames, int[] varIds) {
        auto g = new Goal(GoalKind.Guard);
        g.guardFn = guardFn;
        g.guardVarNames = varNames;
        g.guardVarIds = varIds;
        return g;
    }
}

/// Where a query template keeps its compiled plan between queries (owned by logic.evaluate).
final class PlanHolder {
    Object plan;
}

/// Rule definition
class Rule {
    RelationRef headRel;
    Term[] headTerms;
    Goal[] bodyGoals;
    size_t id;
    int numVariables = 0;
    string[] variableNames;
    /// The rule this one was rebound from when a world was cloned (null for an authored rule).
    /// Clones of one rule derive the same tuples from the same facts, so caches key on the origin.
    Rule origin;

    this(RelationRef headRel, Term[] headTerms, Goal[] bodyGoals, size_t id = 0) {
        this.headRel = headRel;
        this.headTerms = headTerms;
        this.bodyGoals = bodyGoals;
        this.id = id;
    }
}

/// Visit nested goals as well as the enclosing conjunction.
Goal[] flattenGoals(Goal[] goals) {
    Goal[] result;
    foreach (goal; goals) {
        result ~= goal;
        if (goal.kind == GoalKind.Aggregate)
            result ~= flattenGoals(goal.aggregateGoals);
    }
    return result;
}

/// Named variable references in one goal (aggregate internals stay scoped).
string[] goalVariables(Goal goal) {
    string[] result;
    void add(Term term) {
        if (term.kind == TermKind.Variable)
            result ~= term.varName;
    }

    foreach (term; goal.terms)
        add(term);
    if (goal.kind == GoalKind.Comparison) {
        add(goal.leftTerm);
        add(goal.rightTerm);
    }
    if (goal.kind == GoalKind.Guard)
        result ~= goal.guardVarNames;
    if (goal.kind == GoalKind.Aggregate)
        result ~= goal.resultVariable;
    return result;
}
